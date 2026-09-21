import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/autotune/autotune_controller.dart';
import 'package:foxtune_app/src/autotune/autotune_screen.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
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

/// VE autotuning, driven through the screen against the real definition.
///
/// This writes the fuel table, so the assertions that matter are the refusals:
/// a read-only session and a narrowband sensor must both stop it dead, and
/// nothing may reach the ECU without a burn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;
  late StreamController<RealtimeSnapshot> feed;
  late DateTime clock;

  setUpAll(() async {
    final source = await rootBundle.loadString('assets/speeduino.ini');
    doc = IniParser(defined: {'CELSIUS'}).parse(source);
  });

  setUp(() {
    tune = TuneState.empty(doc);
    feed = StreamController<RealtimeSnapshot>.broadcast();
    clock = DateTime(2026, 1, 1);

    // A wideband, a stoichiometric ratio, a flat VE table and a flat target.
    final ego = tune.locate('egoType')!;
    tune.writeBits(ego.page, ego.field as IniBitsField, 2);
    SettingView.of(tune, 'stoich')!.setValue(14.7);
    SettingView.of(tune, 'algorithm')!.setOptionIndex(0);

    final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    for (var i = 0; i < 16; i++) {
      ve.setXAt(i, 500 + i * 500);
      ve.setYAt(i, 20 + i * 10);
    }
    for (var r = 0; r < 16; r++) {
      for (var c = 0; c < 16; c++) {
        ve.setValueAt(r, c, 50);
      }
    }

    final afr = TableView.of(tune, doc.tableNamed('afrTable1Tbl')!)!;
    for (var r = 0; r < afr.rows; r++) {
      for (var c = 0; c < afr.columns; c++) {
        afr.setValueAt(r, c, 14.7);
      }
    }
    for (var i = 0; i < afr.columns; i++) {
      afr.setXAt(i, 500 + i * 1000);
    }
    for (var i = 0; i < afr.rows; i++) {
      afr.setYAt(i, 20 + i * 15);
    }

    tune.markClean();
  });

  tearDown(() => feed.close());

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

  /// A realtime sample with everything the `[VeAnalyze]` filters read.
  RealtimeSnapshot sample({
    int rpm = 2000,
    int load = 60,
    double afr = 14.7,
    int ego = 100,
    int coolant = 85,
    int engine = 0,
    int pulseWidthUs = 3000,
  }) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);

    void put(String name, int value) {
      final field = channels.channelNamed(name)!;
      switch (field.type) {
        case IniDataType.u08:
          view.setUint8(field.offset!, value);
        case IniDataType.s16:
          view.setInt16(field.offset!, value, Endian.little);
        case IniDataType.u16:
          view.setUint16(field.offset!, value, Endian.little);
        default:
          fail('Unexpected storage for $name');
      }
    }

    put('rpm', rpm);
    put('fuelLoad', load);
    put('afr', (afr * 10).round());
    put('egoCorrection', ego);
    // The definition offsets the reading by 40 before sending it.
    put('coolantRaw', coolant + 40);
    put('engine', engine);
    put('pulseWidth', pulseWidthUs);

    return RealtimeDecoder(
      channels,
      constantResolver: TuneValueResolver(tune).resolve,
    ).decode(block, timestamp: clock);
  }

  /// Builds the screen around a container the test can drive directly.
  Future<ProviderContainer> pumpAutotune(
    WidgetTester tester, {
    WritePermission permission = const WritePermission.granted(),
    bool realtimeDependsOnTune = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(
      overrides: [
        tuneProvider.overrideWith(() => _FakeTuneController(tune)),
        writePermissionProvider.overrideWithValue(permission),
        realtimeMonitorProvider.overrideWithValue(null),
        realtimeProvider.overrideWith((ref) {
          // The app's realtime feed reaches the tune: the decoder needs
          // constants from it, so `realtimeProvider` depends on
          // `realtimeMonitorProvider`, which watches `tuneProvider`. A
          // standalone stream here does not reproduce what happens when
          // autotuning marks the tune edited from inside that feed's own
          // notification.
          if (realtimeDependsOnTune) ref.watch(tuneProvider);
          return feed.stream;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC75B12),
            ),
          ),
          home: Scaffold(body: AutotuneScreen(connection: connectionFor())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// Pushes [count] samples through, letting the operating point settle.
  Future<void> drive(
    WidgetTester tester, {
    required double afr,
    int count = 20,
    int rpm = 2000,
    int load = 60,
    int ego = 100,
  }) async {
    feed.add(sample(rpm: rpm, load: load, afr: afr, ego: ego));
    await tester.pump();
    clock = clock.add(const Duration(milliseconds: 600));

    for (var i = 0; i < count; i++) {
      feed.add(sample(rpm: rpm, load: load, afr: afr, ego: ego));
      await tester.pump();
      clock = clock.add(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('renders idle against the real definition', (tester) async {
    await pumpAutotune(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('Start autotune'), findsOneWidget);
    expect(find.byType(TableGrid), findsOneWidget);
  });

  testWidgets('a read-only session cannot arm', (tester) async {
    final container = await pumpAutotune(
      tester,
      permission: const WritePermission.refused('Write mode is off.'),
    );

    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    expect(container.read(autotuneProvider).armed, isFalse);
    expect(find.text('Write mode is off.'), findsOneWidget);
  });

  testWidgets('a narrowband sensor cannot arm', (tester) async {
    final ego = tune.locate('egoType')!;
    tune.writeBits(ego.page, ego.field as IniBitsField, 1);
    tune.markClean();

    final container = await pumpAutotune(tester);
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    expect(container.read(autotuneProvider).armed, isFalse);
    expect(find.textContaining('wideband'), findsOneWidget);
    expect(find.textContaining('Narrow Band'), findsOneWidget);
  });

  testWidgets('arming starts a session', (tester) async {
    final container = await pumpAutotune(tester);

    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    expect(container.read(autotuneProvider).armed, isTrue);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('a lean run raises the cells it visited', (tester) async {
    final container = await pumpAutotune(tester);
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    await drive(tester, afr: 15.5, count: 30);

    final session = container.read(autotuneProvider);
    expect(session.accepted, greaterThan(0));
    expect(session.moved, greaterThan(0));

    final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    final cell = ve.cellFor(2000, 60)!;
    expect(ve.valueAt(cell.row, cell.column), greaterThan(50));
  });

  testWidgets('nothing reaches the ECU without a burn', (tester) async {
    final container = await pumpAutotune(tester);
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();
    await drive(tester, afr: 15.5, count: 30);

    // The tune is changed and waiting, which is exactly the state the Burn
    // button exists to resolve.
    expect(tune.isDirty, isTrue);
    expect(container.read(autotuneProvider).moved, greaterThan(0));
    expect(find.text('Burn to ECU'), findsOneWidget);
  });

  testWidgets('a cold engine is refused, by the definition\'s own label', (
    tester,
  ) async {
    await pumpAutotune(tester);
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    feed.add(sample(coolant: 30));
    await tester.pump();
    clock = clock.add(const Duration(milliseconds: 600));
    feed.add(sample(coolant: 30));
    await tester.pumpAndSettle();

    expect(find.textContaining('Minimum CLT'), findsOneWidget);
  });

  testWidgets('survives the realtime feed depending on the tune', (
    tester,
  ) async {
    // Applying a correction marks the tune edited, which dirties everything
    // downstream of it - including the realtime feed this is being notified
    // by. Reading the session back at that moment asks Riverpod to rebuild a
    // provider that is still mid-notification.
    final container = await pumpAutotune(tester, realtimeDependsOnTune: true);
    // Every sample moves a cell, so every notification marks the tune edited
    // - which is what drives the re-entry.
    container
        .read(autotuneProvider.notifier)
        .updateSettings(const AutotuneSettings(minWeight: 1));
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();

    await drive(tester, afr: 15.5, count: 30);

    expect(tester.takeException(), isNull);
    expect(container.read(autotuneProvider).moved, greaterThan(0));
    expect(tune.isDirty, isTrue);
  });

  testWidgets('stopping leaves what was already applied', (tester) async {
    final container = await pumpAutotune(tester);
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();
    await drive(tester, afr: 15.5, count: 30);

    final moved = container.read(autotuneProvider).moved;
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    expect(container.read(autotuneProvider).armed, isFalse);
    expect(container.read(autotuneProvider).moved, moved);
    expect(tune.isDirty, isTrue);
  });
}
