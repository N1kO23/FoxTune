import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/settings/builtin_panels.dart';
import 'package:foxtune_app/src/settings/setting_field.dart';
import 'package:foxtune_app/src/settings/settings_screen.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);
  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

/// The one hand-built panel: TunerStudio's `std_injection`.
///
/// Speeduino's definition leaves this panel to TunerStudio, so it is the only
/// route to required fuel, the cylinder count and seven other core settings.
/// Until it existed, none of them could be edited in FoxTune.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;

  setUpAll(() async {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(await rootBundle.loadString('assets/speeduino.ini'));
  });

  setUp(() {
    tune = TuneState.empty(doc);
    SettingView.of(tune, 'nCylinders')!.setOptionIndex(4);
    SettingView.of(tune, 'divider')!.setValue(2);
    tune.markClean();
  });

  SettingView setting(String name) => SettingView.of(tune, name)!;

  Future<void> pumpEngineConstants(
    WidgetTester tester, {
    WritePermission permission = const WritePermission.granted(),
    String open = 'engine_constants',
    Size size = const Size(1400, 2000),
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
          selectedSettingProvider.overrideWith((ref) => open),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              connection: EcuConnected(
                port: const EcuPort(address: '/dev/ttyACM0'),
                identification: EcuIdentification(
                  signature: doc.identity.signature!,
                  version: 'Speeduino test',
                ),
                signatureStatus: SignatureStatus.matched,
                expectedSignature: doc.identity.signature,
                definition: doc,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The drop-down on the row labelled [label]: the nearest row, walking up
  /// from the label, that holds one.
  Finder dropdownFor(String label) {
    final rows = find.ancestor(
      of: find.text(label),
      matching: find.byType(Row),
    );
    for (final row in rows.evaluate()) {
      final inRow = find.descendant(
        of: find.byElementPredicate((element) => element == row),
        matching: find.byType(DropdownButtonFormField<int>),
      );
      if (inRow.evaluate().isNotEmpty) return inRow.first;
    }
    throw StateError('No drop-down beside "$label"');
  }

  test(
    'every built-in panel a dialog embeds is drawn or deliberately not',
    () async {
      // A built-in panel FoxTune cannot draw hides every setting inside it -
      // which is how nine core settings went missing. Each one therefore has to
      // be either drawn, or listed as left out with a reason. Checked across
      // build configurations, since `#if` can put a different panel in play.
      final source = await rootBundle.loadString('assets/speeduino.ini');
      final accounted = {
        ...BuiltInPanels.supported,
        ...BuiltInPanels.unsupported.keys,
      };

      for (final config in const <Set<String>>[
        {},
        {'CELSIUS'},
        {'LAMBDA'},
        {'mcu_teensy'},
        {'mcu_stm32'},
        {'enablehardware_test'},
      ]) {
        final parsed = IniParser(defined: config).parse(source);
        final embedded = {
          for (final dialog in parsed.dialogs)
            for (final item in dialog.items)
              if (item is IniDialogPanel &&
                  parsed.targetKind(item.target) == IniTargetKind.builtIn)
                item.target,
        };
        expect(embedded, isNotEmpty);
        expect(accounted, containsAll(embedded), reason: 'config $config');
      }
    },
  );

  test('a panel is never both drawn and left out', () {
    expect(
      BuiltInPanels.supported.intersection(
        BuiltInPanels.unsupported.keys.toSet(),
      ),
      isEmpty,
    );
  });

  group('squirts per engine cycle', () {
    test('offers only counts that divide the cylinders evenly', () {
      expect(squirtOptions(4), [1, 2, 4]);
      expect(squirtOptions(6), [1, 2, 3, 6]);
      expect(squirtOptions(8), [1, 2, 4, 8]);
      expect(squirtOptions(5), [1, 5]);
    });

    test('reads the stored divider the right way up', () {
      // The firmware stores cylinders per squirt: nSquirts = nCylinders /
      // divider.
      expect(squirtsFor(4, 1), 4);
      expect(squirtsFor(4, 2), 2);
      expect(squirtsFor(4, 4), 1);
      // Integer division in the firmware would make this one squirt; it is
      // reported as not a real choice rather than silently as one.
      expect(squirtsFor(4, 3), isNull);
      expect(squirtsFor(4, 0), isNull);
    });
  });

  group('on the Engine Constants screen', () {
    testWidgets('shows every setting the panel is responsible for', (
      tester,
    ) async {
      await pumpEngineConstants(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('not supported'), findsNothing);
      for (final (_, label) in InjectionPanel.fields) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('required fuel can be set', (tester) async {
      await pumpEngineConstants(tester);

      final field = find.descendant(
        of: find.ancestor(
          of: find.text('Required fuel'),
          matching: find.byType(SettingFieldTile),
        ),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '9.6');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(setting('reqFuel').value, closeTo(9.6, 0.05));
      expect(tune.isDirty, isTrue);
    });

    testWidgets('choosing squirts stores the matching divider', (tester) async {
      await pumpEngineConstants(tester);

      await tester.tap(dropdownFor('Squirts per engine cycle'));
      await tester.pumpAndSettle();
      // Four squirts on four cylinders is one cylinder per squirt.
      await tester.tap(find.text('4').last);
      await tester.pumpAndSettle();

      expect(setting('divider').value, 1);
    });

    testWidgets('says so when sequential injection overrides it', (
      tester,
    ) async {
      setting('injLayout').setOptionIndex(3); // Sequential
      await pumpEngineConstants(tester);

      expect(
        find.textContaining('Ignored while injection is sequential'),
        findsOneWidget,
      );
      final dropdown = tester.widget<DropdownButtonFormField<int>>(
        dropdownFor('Squirts per engine cycle'),
      );
      expect(dropdown.onChanged, isNull);
    });

    testWidgets('warns over a stored divider that does not divide evenly', (
      tester,
    ) async {
      setting('divider').setValue(3);
      await pumpEngineConstants(tester);

      expect(
        find.textContaining('does not divide evenly into 4 cylinders'),
        findsOneWidget,
      );
    });

    testWidgets('never offers an INVALID placeholder', (tester) async {
      // nCylinders has placeholders at 0 and 7, between real values.
      await pumpEngineConstants(tester);

      await tester.tap(dropdownFor('Number of cylinders'));
      await tester.pumpAndSettle();

      expect(find.text('INVALID'), findsNothing);
      expect(find.text('8'), findsWidgets);
    });

    testWidgets('an empty tune shows no cylinder count rather than INVALID', (
      tester,
    ) async {
      tune = TuneState.empty(doc)..markClean();
      await pumpEngineConstants(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('INVALID'), findsNothing);
      expect(find.text('Set the number of cylinders first.'), findsOneWidget);
    });

    testWidgets('the clock panel says why it is left out, and wraps', (
      tester,
    ) async {
      // Long enough to overflow a phone if it were laid out on one line.
      await pumpEngineConstants(
        tester,
        open: 'rtc_settings',
        size: const Size(1000, 1200),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Setting the ECU clock is not supported'),
        findsOneWidget,
      );
      expect(find.textContaining('std_ms3Rtc'), findsNothing);
    });

    testWidgets('offers nothing editable when writing is refused', (
      tester,
    ) async {
      await pumpEngineConstants(
        tester,
        permission: const WritePermission.refused('Read-only.'),
      );

      final squirts = tester.widget<DropdownButtonFormField<int>>(
        dropdownFor('Squirts per engine cycle'),
      );
      expect(squirts.onChanged, isNull);
      final cylinders = tester.widget<DropdownButtonFormField<int>>(
        dropdownFor('Number of cylinders'),
      );
      expect(cylinders.onChanged, isNull);
    });
  });
}
