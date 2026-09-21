import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/bar_gauge.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';
import 'package:foxtune_app/src/dashboard/layout/layout_controller.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
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

      // Just over four cells down: it snaps to four.
      await tester.drag(gaugeShowing('Air:Fuel Ratio'), const Offset(0, 250));
      await tester.pumpAndSettle();

      expect(item(tester, 'a').y, 4);
      final saved = jsonDecode(layoutFile().readAsStringSync()) as Map;
      final a = ((saved['pages'] as List).first['items'] as List).firstWhere(
        (i) => i['id'] == 'a',
      ) as Map;
      expect(a['y'], 4);
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
      // Two cells wider would reach the neighbour; one fits.
      await tester.drag(handle, const Offset(80, 80));
      await tester.pumpAndSettle();

      expect(item(tester, 'a').width, 4);
      expect(item(tester, 'a').height, 3);
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
        greaterThanOrEqualTo(GaugeStyle.graph.minWidth),
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
