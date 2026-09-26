import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/bar_gauge.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
import 'package:foxtune_app/src/dashboard/gauge_appearance.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/gauge_view.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';
import 'package:foxtune_app/src/dashboard/layout/layout_controller.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/dashboard/stat_tile.dart';
import 'package:foxtune_app/src/dashboard/time_graph.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _Connected extends ConnectionController {
  _Connected(this._state);
  final EcuConnectionState _state;

  @override
  EcuConnectionState build() => _state;
}

/// Two readouts with room between and below them.
///
/// Saved in the version 1 format, twelve across, so every test here also
/// loads a layout from before grids could change size: it arrives doubled onto
/// the 24-across default, "a" at 0,0 6x4 and "b" at 12,0 6x4.
const _testLayout = {
  'version': 1,
  'pages': [
    {
      'id': 'p1',
      'name': 'Test',
      'items': [
        {
          'id': 'a',
          'style': 'digital',
          'x': 0,
          'y': 0,
          'w': 3,
          'h': 2,
          'gauges': ['afrGauge'],
        },
        {
          'id': 'b',
          'style': 'digital',
          'x': 6,
          'y': 0,
          'w': 3,
          'h': 2,
          'gauges': ['batteryVoltage'],
        },
      ],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late Directory storage;

  setUpAll(() async {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(await rootBundle.loadString('assets/speeduino.ini'));
  });

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_edit'));
  tearDown(() => storage.deleteSync(recursive: true));

  File layoutFile() => File('${storage.path}/dashboards/speeduino.json');

  void saveLayout(Map<String, Object?> json) {
    layoutFile()
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(json));
  }

  EcuConnected connection() => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  RealtimeSnapshot sample({int rpm = 0}) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    ByteData.sublistView(block)
        .setUint16(channels.channelNamed('rpm')!.offset!, rpm, Endian.little);
    return RealtimeDecoder(channels).decode(block);
  }

  Future<void> pump(
    WidgetTester tester, {
    TuneState? tune,
    RealtimeSnapshot? live,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final snapshot = live ?? sample();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _Connected(connection())),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => Stream<RealtimeSnapshot>.value(snapshot),
          ),
          if (tune != null)
            tuneResolverProvider.overrideWithValue(TuneValueResolver(tune)),
        ],
        child: MaterialApp(
          home: Scaffold(body: DashboardScreen(connection: connection())),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(DashboardScreen)));

  DashboardPage page(WidgetTester tester) =>
      container(tester).read(dashboardLayoutProvider).value!.pages.first;

  GaugePlacement item(WidgetTester tester, String id) =>
      page(tester).items.firstWhere((i) => i.id == id);

  /// The on-screen gauge showing [text].
  Finder gaugeShowing(String text) => find.ancestor(
    of: find.text(text),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == 'GaugeView',
    ),
  );

  Future<void> startEditing(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Edit layout'));
    await tester.pumpAndSettle();
  }

  group('Gauge Limits on the dashboard', () {
    testWidgets('the tachometer uses the limits the tuner set', (tester) async {
      // The whole point: RPM warnings follow Gauge Limits, not a number in
      // the code. The factory warning point is 3000 rpm.
      final tune = TuneState.empty(doc);
      SettingView.of(tune, 'rpmwarn')!.setValue(6500);
      SettingView.of(tune, 'rpmdang')!.setValue(7000);
      SettingView.of(tune, 'rpmhigh')!.setValue(9000);

      await pump(tester, tune: tune, live: sample(rpm: 6000));

      final tach = tester
          .widgetList<MeterGauge>(find.byType(MeterGauge))
          .firstWhere((m) => m.spec.channel == 'rpm');
      expect(tach.spec.warnAbove, 6500);
      expect(tach.spec.dangerAbove, 7000);
      expect(tach.spec.max, 9000);
      // 6000 rpm was a warning under the factory limits; it is not now.
      expect(tach.spec.statusFor(6000), GaugeStatus.normal);
    });
  });

  group('the default page', () {
    testWidgets('is made from the definition\'s front page', (tester) async {
      await pump(tester);

      final dials = tester
          .widgetList<MeterGauge>(find.byType(MeterGauge))
          .map((m) => m.spec.channel)
          .toList();
      for (final name in doc.frontPage.gauges) {
        expect(dials, contains(doc.gaugeNamed(name)!.channel), reason: name);
      }
    });
  });

  group('editing', () {
    testWidgets('moving a gauge saves where it lands', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      // A 720-wide page, 24 across: 30-pixel cells. Just over eight cells
      // down snaps to eight.
      await tester.drag(gaugeShowing('Air:Fuel Ratio'), const Offset(0, 250));
      await tester.pumpAndSettle();

      expect(item(tester, 'a').y, 8);
      final saved = jsonDecode(layoutFile().readAsStringSync()) as Map;
      final a = ((saved['pages'] as List).first['items'] as List).firstWhere(
        (i) => i['id'] == 'a',
      ) as Map;
      expect(a['y'], 8);
    });

    testWidgets('a gauge dropped on another springs back', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.drag(gaugeShowing('Air:Fuel Ratio'), const Offset(330, 0));
      await tester.pumpAndSettle();

      expect(item(tester, 'a').x, 0);
    });

    testWidgets('the corner handle resizes', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      // The handle sits beside the gauge's content, not inside it; gauge "a"
      // comes first on the page.
      final handle = find.byIcon(Icons.open_in_full).first;
      // Two cells each way; seven wider would reach the neighbour.
      await tester.drag(handle, const Offset(66, 66));
      await tester.pumpAndSettle();

      expect(item(tester, 'a').width, 8);
      expect(item(tester, 'a').height, 6);
    });

    testWidgets('a gauge can be restyled, graphed and removed', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(gaugeShowing('Air:Fuel Ratio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bar'));
      await tester.pumpAndSettle();
      expect(item(tester, 'a').style, GaugeStyle.bar);
      expect(find.byType(BarGauge), findsOneWidget);

      await tester.tap(find.text('Time graph'));
      await tester.pumpAndSettle();
      expect(item(tester, 'a').style, GaugeStyle.graph);
      // A graph needs more room than a readout, and gets it.
      expect(
        item(tester, 'a').width,
        greaterThanOrEqualTo(GaugeStyle.graph.minimumIn(24).width),
      );
      await tester.tap(find.text('60s'));
      await tester.pumpAndSettle();
      expect(item(tester, 'a').windowSeconds, 60);
      expect(find.byType(TimeGraph), findsOneWidget);

      await tester.tap(find.text('Remove from page'));
      await tester.pumpAndSettle();
      expect(page(tester).items.map((i) => i.id), ['b']);
    });

    testWidgets('a gauge is added from the definition', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Add a gauge'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Coolant');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coolant Temp'));
      await tester.pumpAndSettle();

      final added = page(tester).items.last;
      expect(added.gauges, ['cltGauge']);
      expect(added.style, GaugeStyle.dial);
    });

    testWidgets('an indicator is added as a lamp', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Add a gauge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Indicators'));
      await tester.pumpAndSettle();
      // Over fifty indicators, built as they scroll into view: search first.
      await tester.enterText(find.byType(TextField).last, 'sync');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Full Sync'));
      await tester.pumpAndSettle();

      final added = page(tester).items.last;
      expect(added.style, GaugeStyle.lamp);
      expect(added.indicator, 'sync');
    });

    testWidgets('a live channel with no gauge is added as a number', (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Add a gauge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'rpmDOT');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'rpmDOT'));
      await tester.pumpAndSettle();

      final added = page(tester).items.last;
      expect(added.gauges, [GaugeRef.channel('rpmDOT')]);
      expect(added.style, GaugeStyle.digital);
      expect(gaugeShowing('rpmDOT'), findsOneWidget);
    });

    testWidgets('a status bit with no indicator is added as a lamp', (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Add a gauge'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'knock');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'knockActive'));
      await tester.pumpAndSettle();

      final added = page(tester).items.last;
      expect(added.style, GaugeStyle.lamp);
      expect(added.indicator, 'knockActive');
      expect(gaugeShowing('knockActive'), findsOneWidget);
    });
  });

  group('range and alarms', () {
    Future<void> openLimits(WidgetTester tester) async {
      await tester.tap(gaugeShowing('Air:Fuel Ratio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Range and alarms'));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextField, label);

    testWidgets('can be set for a gauge, and handed back', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      await openLimits(tester);

      // Starts from what the definition says.
      expect(tester.widget<TextField>(field('From')).controller!.text, '7');
      await tester.enterText(field('Warn above'), '15.5');
      await tester.enterText(field('Danger above'), '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final layout = container(tester).read(dashboardLayoutProvider).value!;
      final limits = layout.limits['afrGauge']!;
      expect(limits.warnAbove, 15.5);
      // Emptied, so off - not quietly the definition's.
      expect(limits.dangerAbove, isNull);
      final tile = tester.widget<StatTile>(
        find.descendant(
          of: gaugeShowing('Air:Fuel Ratio'),
          matching: find.byType(StatTile),
        ),
      );
      expect(tile.spec.warnAbove, 15.5);
      expect(find.textContaining('set by you'), findsOneWidget);

      await tester.tap(find.text('Range and alarms'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Use the definition's"));
      await tester.pumpAndSettle();
      expect(
        container(tester).read(dashboardLayoutProvider).value!.limits,
        isEmpty,
      );
    });

    testWidgets('refuses alarms no reading could pass', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      await openLimits(tester);

      await tester.enterText(field('Warn below'), '16');
      await tester.enterText(field('Warn above'), '12');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('room between them'), findsOneWidget);
      expect(
        container(tester).read(dashboardLayoutProvider).value!.limits,
        isEmpty,
      );
    });
  });

  group('pages', () {
    testWidgets('a page can be added, renamed and deleted', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      Future<void> pageMenu(String item) async {
        await tester.tap(find.byTooltip('Page'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item));
        await tester.pumpAndSettle();
      }

      await pageMenu('New page');
      await tester.enterText(find.byType(TextField), 'Tuning');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Tuning'), findsOneWidget);

      await pageMenu('Rename page');
      await tester.enterText(find.byType(TextField), 'Logging');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Logging'), findsOneWidget);

      await pageMenu('Grid size (24 across)');
      await tester.tap(find.text('48 across'));
      await tester.pumpAndSettle();
      expect(
        container(tester)
            .read(dashboardLayoutProvider)
            .value!
            .pages
            .firstWhere((p) => p.name == 'Logging')
            .columns,
        48,
      );

      await pageMenu('Delete page');
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'Logging'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Test'), findsOneWidget);
    });

    testWidgets('the last page cannot be deleted', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Page'));
      await tester.pumpAndSettle();
      final delete = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Delete page'),
      );
      expect(delete.enabled, isFalse);
    });
  });

  group('the grid', () {
    testWidgets('a coarser grid keeps the gauges where they were', (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      await tester.tap(find.byTooltip('Page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grid size (24 across)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('12 across'));
      await tester.pumpAndSettle();

      expect(page(tester).columns, 12);
      final a = item(tester, 'a');
      final b = item(tester, 'b');
      expect((a.x, a.y, a.width, a.height), (0, 0, 3, 2));
      expect((b.x, b.y, b.width, b.height), (6, 0, 3, 2));
    });

    testWidgets('a wider page keeps its gauges and uses the screen', (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);

      Size pageSize() => tester.getSize(
        find
            .ancestor(
              of: find.byType(GaugeView).first,
              matching: find.byType(Stack),
            )
            .last,
      );
      // A phone-wide page stops growing at one and a half times its size.
      expect(pageSize().width, 720);

      await tester.tap(find.byTooltip('Page'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Page width (Phone)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(page(tester).width, PageWidth.laptop);
      expect(page(tester).columns, 72);
      final a = item(tester, 'a');
      expect((a.x, a.y, a.width, a.height), (0, 0, 6, 4));
      // Now as wide as the window allows: 1200 less the page's margins.
      expect(pageSize().width, 1184);
    });

    testWidgets('lamps fill their cells, whatever their labels', (
      tester,
    ) async {
      saveLayout({
        'version': 2,
        'pages': [
          {
            'id': 'p',
            'name': 'Lamps',
            'columns': 24,
            'items': [
              for (final (i, expression) in ['running', 'launchHard'].indexed)
                {
                  'id': 'l$i',
                  'style': 'lamp',
                  'x': 0,
                  'y': i * 2,
                  'w': 6,
                  'h': 2,
                  'indicator': expression,
                },
            ],
          },
        ],
      });
      await pump(tester);

      final lamps = find.byType(FlagLamp);
      expect(lamps, findsNWidgets(2));
      // Six by two cells of a 24-across design grid, less the gauge padding.
      expect(tester.getSize(lamps.at(0)), const Size(114, 34));
      expect(tester.getSize(lamps.at(1)), const Size(114, 34));
    });
  });

  group('at phone width', () {
    testWidgets('a page with a graph, being edited, fits', (tester) async {
      saveLayout({
        'version': 1,
        'pages': [
          {
            'id': 'p',
            'name': 'Phone',
            'items': [
              {
                'id': 'g',
                'style': 'graph',
                'x': 0,
                'y': 0,
                'w': 12,
                'h': 4,
                'gauges': ['tachometer', 'afrGauge'],
              },
              {
                'id': 'd',
                'style': 'dial',
                'x': 0,
                'y': 4,
                'w': 6,
                'h': 6,
                'gauges': ['cltGauge'],
              },
              {
                'id': 'l',
                'style': 'lamp',
                'x': 6,
                'y': 4,
                'w': 6,
                'h': 1,
                'indicator': 'running',
              },
            ],
          },
        ],
      });
      await pump(tester);
      await tester.binding.setSurfaceSize(const Size(400, 850));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await startEditing(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(TimeGraph), findsOneWidget);
    });
  });

  group('a gauge the definition does not have', () {
    testWidgets('keeps its place and says so', (tester) async {
      saveLayout({
        'version': 1,
        'pages': [
          {
            'id': 'p',
            'name': 'Old',
            'items': [
              {
                'id': 'x',
                'style': 'dial',
                'x': 0,
                'y': 0,
                'w': 4,
                'h': 4,
                'gauges': ['gaugeFromAnotherFirmware'],
              },
            ],
          },
        ],
      });
      await pump(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('not in this ECU definition'), findsOneWidget);
    });
  });

  group('appearance', () {
    /// The readout the gauge placed as [id] draws.
    StatTile tileOf(WidgetTester tester, String id) => tester.widget<StatTile>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is GaugeView && w.placement.id == id,
        ),
        matching: find.byType(StatTile),
      ),
    );

    /// The chip labelled [label] in the setting called [setting].
    Finder chip(String setting, String label) => find.descendant(
      of: find
          .ancestor(of: find.text(setting), matching: find.byType(Column))
          .first,
      matching: find.widgetWithText(ChoiceChip, label),
    );

    Future<void> tapShown(WidgetTester tester, Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> openAppearance(WidgetTester tester) async {
      await tester.tap(gaugeShowing('Air:Fuel Ratio'));
      await tester.pumpAndSettle();
      await tapShown(tester, find.text('Appearance'));
    }

    testWidgets("a gauge's own setting is kept with it, and handed back", (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      await openAppearance(tester);

      await tapShown(tester, chip('Card', 'Hidden'));
      expect(item(tester, 'a').appearance.readout.framed, isFalse);
      expect(tileOf(tester, 'a').look.readout.framed, isFalse);
      // Its neighbour follows the default still.
      expect(tileOf(tester, 'b').look.readout.framed, isTrue);
      final saved = DashboardLayout.fromJson(
        jsonDecode(layoutFile().readAsStringSync()),
      )!;
      expect(
        saved.pages.first.items.first.appearance,
        const GaugeAppearance(readout: ReadoutLook(framed: false)),
      );

      await tapShown(tester, chip('Card', 'Default (Shown)'));
      expect(item(tester, 'a').appearance.isEmpty, isTrue);
      expect(tileOf(tester, 'a').look.readout.framed, isTrue);
    });

    testWidgets('the default look reaches every gauge that follows it', (
      tester,
    ) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      await openAppearance(tester);
      // The same as the default, but its own: it stays when that changes.
      await tapShown(tester, chip('Range bar', 'Shown'));

      container(tester)
          .read(appSettingsProvider.notifier)
          .update(
            (s) => s.copyWith(
              gaugeAppearance: const GaugeAppearance(
                readout: ReadoutLook(magnitudeBar: false),
              ),
            ),
          );
      await tester.pumpAndSettle();

      expect(tileOf(tester, 'b').look.readout.magnitudeBar, isFalse);
      expect(tileOf(tester, 'a').look.readout.magnitudeBar, isTrue);
      // The sheet says what Default now means.
      expect(chip('Range bar', 'Default (Hidden)'), findsOneWidget);
    });

    testWidgets("a gauge's look can be made the default", (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      await openAppearance(tester);
      await tapShown(tester, chip('Number', 'Large'));
      expect(tileOf(tester, 'b').look.readout.valueSize, ValueSize.regular);

      await tapShown(tester, find.text('Make this the default'));
      await tester.tap(find.text('Make default'));
      await tester.pumpAndSettle();

      expect(
        container(tester).read(appSettingsProvider).gaugeAppearance,
        const GaugeAppearance(readout: ReadoutLook(valueSize: ValueSize.large)),
      );
      // Handed over, so it follows the default again - which now says the
      // same.
      expect(item(tester, 'a').appearance.isEmpty, isTrue);
      expect(tileOf(tester, 'a').look.readout.valueSize, ValueSize.large);
      expect(tileOf(tester, 'b').look.readout.valueSize, ValueSize.large);
    });

    testWidgets('a lamp has a look of its own too', (tester) async {
      saveLayout(_testLayout);
      await pump(tester);
      await startEditing(tester);
      final placed = container(tester)
          .read(dashboardLayoutProvider.notifier)
          .addGauge('p1', style: GaugeStyle.lamp, indicator: 'running');
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is GaugeView && w.placement.id == placed.id,
        ),
      );
      await tester.pumpAndSettle();
      await tapShown(tester, find.text('Appearance'));
      await tapShown(tester, chip('Shape', 'Square'));

      expect(item(tester, placed.id).appearance.lamp.shape, LampShape.square);
      // A lamp has no alarms to colour.
      expect(find.text('Warning'), findsNothing);
    });
  });

  group('time graph', () {
    test('plots the window, oldest left, and breaks at a gap', () {
      final history = SampleHistory();
      final channels = doc.outputChannels;
      final start = DateTime(2026, 1, 1);

      RealtimeSnapshot at(int ms, int rpm) {
        final block = Uint8List(channels.blockSize!);
        ByteData.sublistView(
          block,
        ).setUint16(channels.channelNamed('rpm')!.offset!, rpm, Endian.little);
        return RealtimeDecoder(channels)
            .decode(block, timestamp: start.add(Duration(milliseconds: ms)));
      }

      // Older than the window: must not be drawn.
      history
        ..add(at(0, 1000))
        ..add(at(25000, 2000))
        ..add(at(30000, 4000));

      final painter = LanePainter(
        spec: const GaugeSpec(
          channel: 'rpm',
          label: 'RPM',
          units: '',
          min: 0,
          max: 8000,
        ),
        history: history,
        window: const Duration(seconds: 10),
        line: Colors.blue,
        grid: Colors.grey,
        label: Colors.black,
      );
      final points = painter.points().whereType<Offset>().toList();

      expect(points, hasLength(2));
      expect(points.first.dx, closeTo(0.5, 1e-9));
      expect(points.last.dx, closeTo(1.0, 1e-9));
      // Higher on the lane is a higher reading.
      expect(points.last.dy, lessThan(points.first.dy));
      expect(points.last.dy, closeTo(0.5, 1e-9));
    });

    test('a repeated sample is not a new reading', () {
      final history = SampleHistory();
      final one = sample();
      history
        ..add(one)
        ..add(one);
      expect(history.length, 1);
    });
  });
}
