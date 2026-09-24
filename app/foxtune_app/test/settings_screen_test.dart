import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/settings/curve_editor.dart';
import 'package:foxtune_app/src/settings/setting_field.dart';
import 'package:foxtune_app/src/settings/settings_screen.dart';
import 'package:foxtune_app/src/tune/surface_view.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Supplies a ready-made tune instead of reading one from an ECU.
class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);

  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

/// The generated settings screens, driven by the real shipped definition.
///
/// The point of testing against the real file rather than a stand-in is that
/// these screens are entirely generated: a dialog that renders from a
/// two-field fixture proves nothing about the 240 in the definition.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;

  setUpAll(() async {
    final source = await rootBundle.loadString('assets/speeduino.ini');
    doc = IniParser(defined: {'CELSIUS'}).parse(source);
  });

  setUp(() {
    tune = TuneState.empty(doc);
    tune.markClean();
  });

  EcuConnected connectionFor() => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  Future<void> pumpSettings(
    WidgetTester tester, {
    WritePermission permission = const WritePermission.granted(),
    Size size = const Size(1400, 1000),
    String? open,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tuneProvider.overrideWith(() => _FakeTuneController(tune)),
          writePermissionProvider.overrideWithValue(permission),
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => const Stream<RealtimeSnapshot>.empty(),
          ),
          if (open != null)
            selectedSettingProvider.overrideWithBuild((ref, _) => open),
        ],
        child: MaterialApp(
          theme: brandTheme(Brightness.light),
          home: Scaffold(body: SettingsScreen(connection: connectionFor())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('menu navigation', () {
    /// Types into the search box, which is how the list is narrowed to
    /// something a test can see without scrolling a virtualised ListView.
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pumpAndSettle();
    }

    testWidgets('lists the definition\'s own menus', (tester) async {
      await pumpSettings(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('SETTINGS'), findsOneWidget);
      expect(find.text('Trigger Setup'), findsOneWidget);

      await search(tester, 'warmup');
      expect(find.text('STARTUP/IDLE'), findsOneWidget);
      expect(find.text('Warmup Enrichment'), findsOneWidget);
    });

    testWidgets('hides entries whose condition the tune makes false', (
      tester,
    ) async {
      // "Boost Targets/Duty" is gated on `{ boostEnabled }`, which is off in
      // an empty tune. Offering it would lead to a screen for hardware the
      // ECU is not configured for.
      await pumpSettings(tester);
      await search(tester, 'boost targets');
      expect(find.text('Boost Targets/Duty'), findsNothing);

      SettingView.of(tune, 'boostEnabled')!.setOptionIndex(1);
      await pumpSettings(tester);
      await search(tester, 'boost targets');
      expect(find.text('Boost Targets/Duty'), findsOneWidget);
    });

    testWidgets('search narrows the list', (tester) async {
      await pumpSettings(tester);
      await search(tester, 'trigger');

      expect(find.text('Trigger Setup'), findsOneWidget);
      expect(find.text('Warmup Enrichment'), findsNothing);
    });
  });

  group('generated dialogs', () {
    testWidgets('renders Trigger Setup from the definition', (tester) async {
      await pumpSettings(tester, open: 'triggerSettings');

      expect(tester.takeException(), isNull);
      expect(find.text('Trigger Pattern'), findsOneWidget);
      expect(find.text('Trigger Angle'), findsOneWidget);
      // The drop-down offers the pattern names the definition declares.
      expect(find.text('Missing Tooth'), findsWidgets);
    });

    testWidgets('a controlling setting greys out what depends on it', (
      tester,
    ) async {
      // "Missing teeth" applies only while `TrigPattern == 0`. This is what
      // makes Trigger Setup usable: the definition knows which of its forty
      // fields belong to the pattern in force, and FoxTune follows it.
      TextField fieldFor(String label) => tester.widget<TextField>(
        find.descendant(
          of: find.ancestor(
            of: find.text(label),
            matching: find.byType(SettingFieldTile),
          ),
          matching: find.byType(TextField),
        ),
      );

      await pumpSettings(tester, open: 'triggerSettings');
      expect(SettingView.of(tune, 'TrigPattern')!.optionIndex, 0);
      expect(fieldFor('Missing teeth').enabled, isTrue);

      // Dual wheel has no missing teeth, so that field stops applying.
      SettingView.of(tune, 'TrigPattern')!.setOptionIndex(1);
      await pumpSettings(tester, open: 'triggerSettings');

      expect(fieldFor('Missing teeth').enabled, isFalse);
    });

    testWidgets('editing a setting writes it to the tune', (tester) async {
      await pumpSettings(tester, open: 'triggerSettings');

      final field = find.descendant(
        of: find.ancestor(
          of: find.text('Trigger Angle'),
          matching: find.byType(SettingFieldTile),
        ),
        matching: find.byType(TextField),
      );

      await tester.enterText(field, '90');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(SettingView.of(tune, 'TrigAng')!.value, 90);
      expect(tune.isDirty, isTrue);
    });

    testWidgets('offers no editable control when writing is refused', (
      tester,
    ) async {
      await pumpSettings(
        tester,
        open: 'triggerSettings',
        permission: const WritePermission.refused('Read-only for the test.'),
      );

      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        // The search box is the one control that stays live.
        if (field.decoration?.hintText == 'Search settings') continue;
        expect(field.enabled, isFalse);
      }
      for (final menu in tester.widgetList<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>),
      )) {
        expect(menu.onChanged, isNull);
      }
    });

    testWidgets('a command button is shown but cannot be pressed', (
      tester,
    ) async {
      await pumpSettings(tester, open: 'vssSettings');

      final button = tester.widget<FilledButton>(
        find
            .ancestor(
              of: find.text('Set Gear 1'),
              matching: find.byType(FilledButton),
            )
            .first,
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('nested panels render rather than stopping at the first', (
      tester,
    ) async {
      // Engine Constants is a border dialog of dialogs; its fields only
      // appear if the renderer recurses through the panels.
      await pumpSettings(tester, open: 'engine_constants');

      expect(tester.takeException(), isNull);
      expect(find.text('Board Layout'), findsOneWidget);
      expect(find.text('Injector Layout'), findsOneWidget);
    });
  });

  group('curves', () {
    testWidgets('warmup enrichment opens as an editable curve', (tester) async {
      await pumpSettings(tester, open: 'warmup');

      expect(tester.takeException(), isNull);
      expect(find.byType(CurveEditor), findsOneWidget);
    });

    testWidgets('editing a curve point writes it to the tune', (tester) async {
      await pumpSettings(tester, open: 'warmup');

      final fields = find.descendant(
        of: find.byType(CurveEditor),
        matching: find.byType(TextField),
      );
      expect(fields, findsWidgets);

      // The first column holds point 0: its X bin above, its Y value below.
      await tester.enterText(fields.at(1), '140');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      final curve = CurveView.of(tune, doc.curveNamed('warmup_curve')!)!;
      expect(curve.yAt(0), 140);
      expect(tune.isDirty, isTrue);
    });
  });

  group('3D maps', () {
    testWidgets('a map entry opens the surface on its own', (tester) async {
      // "3D Tuning Maps" points at a table's map id, which is the definition
      // asking for the surface rather than the grid. Opening the grid editor
      // with a strip of 3D above it would be answering a different question.
      await pumpSettings(tester, open: 'veTable1Map');

      await tester.tap(find.textContaining('in 3D'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SurfaceView), findsOneWidget);
      expect(find.byType(TableGrid), findsNothing);
    });

    testWidgets('the grid is one tap away from the surface', (tester) async {
      await pumpSettings(tester, open: 'veTable1Map');
      await tester.tap(find.textContaining('in 3D'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit in grid'));
      await tester.pumpAndSettle();

      expect(find.byType(TableGrid), findsOneWidget);
    });
  });

  group('every screen the menu offers', () {
    testWidgets('renders without a layout fault', (tester) async {
      // A generated UI fails in bulk or not at all: one bad assumption about
      // a dialog's shape takes out every dialog that uses it. Rendering all
      // of them is the only check that actually covers the 240 in the file.
      final targets = <String>{};
      for (final menu in doc.menus) {
        for (final item in menu.leaves) {
          if (item.isBuiltIn) continue;
          targets.add(item.target);
        }
      }
      expect(targets.length, greaterThan(50));

      final broken = <String>[];
      for (final target in targets) {
        await pumpSettings(tester, open: target, size: const Size(1400, 2400));
        final failure = tester.takeException();
        if (failure != null) broken.add('$target: $failure');
      }

      expect(broken, isEmpty, reason: broken.join('\n'));
    });
  });

  group('at phone width', () {
    const phone = Size(400, 850);

    Future<void> openFromList(WidgetTester tester, String label) async {
      await tester.enterText(find.byType(TextField).first, label);
      await tester.pumpAndSettle();
      // The search box now holds the same text, so aim at the list entry.
      await tester.tap(find.widgetWithText(ListTile, label));
      await tester.pumpAndSettle();
    }

    testWidgets('the menu fills the screen and opens settings on top', (
      tester,
    ) async {
      await pumpSettings(tester, size: phone);
      expect(tester.takeException(), isNull);

      await openFromList(tester, 'Trigger Setup');

      expect(tester.takeException(), isNull);
      expect(find.text('Trigger Pattern'), findsOneWidget);
    });

    testWidgets('a curve fits', (tester) async {
      await pumpSettings(tester, size: phone);
      await openFromList(tester, 'Warmup Enrichment');

      expect(tester.takeException(), isNull);
      expect(find.byType(CurveEditor), findsOneWidget);
    });

    testWidgets('the busiest dialog fits', (tester) async {
      // Engine Constants nests dialogs inside a border layout, which is what
      // would be squeezed into unusable columns if it were laid out as wide.
      await pumpSettings(tester, size: phone);
      await openFromList(tester, 'Engine Constants');

      expect(tester.takeException(), isNull);
      expect(find.text('Board Layout'), findsOneWidget);
    });
  });

  group('plot geometry', () {
    test('places a point inside the declared window, y growing upwards', () {
      const window = CurveWindow(xMin: 0, xMax: 100, yMin: 0, yMax: 200);
      const size = Size(200, 100);

      expect(curvePlotPointFor(window, size, 0, 0), const Offset(0, 100));
      expect(curvePlotPointFor(window, size, 100, 200), const Offset(200, 0));
      expect(curvePlotPointFor(window, size, 50, 100), const Offset(100, 50));
    });
  });
}
