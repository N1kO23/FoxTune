import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/tune/table_editor_screen.dart';
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

/// Exercises the whole editor screen.
///
/// The grid alone was already covered, which is exactly why a layout fault in
/// the surrounding chrome could blank the entire screen unnoticed: a broken
/// child of the screen's Column takes the grid down with it.
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
    // Give the VE table recognisable values so a rendered grid is obvious.
    final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    for (var r = 0; r < 16; r++) {
      for (var c = 0; c < 16; c++) {
        ve.setValueAt(r, c, (40 + r + c).toDouble());
      }
    }
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

  Future<void> pumpEditor(
    WidgetTester tester, {
    WritePermission permission = const WritePermission.granted(),
    Size size = const Size(1400, 1000),
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
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC75B12),
            ),
          ),
          home: Scaffold(body: TableEditorScreen(connection: connectionFor())),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the table grid without a layout fault', (tester) async {
    await pumpEditor(tester);

    // The regression this guards: a ParentDataWidget misuse in the edit bar
    // failed the whole Column's layout, leaving the grid blank in release
    // builds where the assertion is compiled out.
    expect(tester.takeException(), isNull);
    expect(find.byType(TableGrid), findsOneWidget);
  });

  testWidgets('shows real cell values from the tune', (tester) async {
    await pumpEditor(tester);

    // Row 0 column 0 was set to 40.
    expect(find.text('40'), findsWidgets);
    expect(find.text('70'), findsWidgets);
  });

  testWidgets('shows the table picker and edit actions', (tester) async {
    await pumpEditor(tester);

    expect(find.text('VE Table'), findsWidgets);
    expect(find.text('Write mode'), findsOneWidget);
    expect(find.text('Interpolate'), findsOneWidget);
    expect(find.text('Smooth'), findsOneWidget);
  });

  testWidgets('lays out at phone width without overflowing', (tester) async {
    await pumpEditor(tester, size: const Size(420, 900));
    // Guards the second fault found here: the table dropdown sized itself to
    // its widest title and overflowed the toolbar in portrait.
    expect(tester.takeException(), isNull);
    expect(find.byType(TableGrid), findsOneWidget);
  });

  testWidgets('edit actions are disabled when writing is refused', (
    tester,
  ) async {
    await pumpEditor(
      tester,
      permission: const WritePermission.refused('Write mode is off.'),
    );

    expect(tester.takeException(), isNull);
    final interpolate = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Interpolate'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(
      interpolate.onPressed,
      isNull,
      reason: 'read-only must not offer a working edit action',
    );
  });
}
