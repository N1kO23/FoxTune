import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/autotune/autotune_controller.dart';
import 'package:foxtune_app/src/autotune/autotune_screen.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Supplies a ready-made tune instead of reading one from an ECU.
///
/// What is sent to the ECU lands in [ecu], its pages, rather than on a wire.
class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune, this.ecu, {this.failure});

  final TuneState _tune;
  final List<Uint8List> ecu;

  /// Thrown by every send, where given.
  final Object? failure;

  /// Ranges sent, in order.
  final sent = <({int page, int offset, int length})>[];

  @override
  Future<TuneState?> build() async => _tune;

  @override
  Future<void> sendToEcu(
    int page, {
    required int offset,
    required int length,
  }) async {
    if (failure case final failure?) throw failure;
    sent.add((page: page, offset: offset, length: length));
    ecu[page - 1].setRange(
      offset,
      offset + length,
      _tune.page(page).sublist(offset, offset + length),
    );
  }
}

/// A connection that can be dropped.
class _Connection extends ConnectionController {
  _Connection(this._connected);

  final EcuConnected _connected;

  @override
  EcuConnectionState build() => _connected;

  void drop() => state = const EcuDisconnected();
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

  /// The ECU's own pages: what it runs, and what it reports running.
  late List<Uint8List> ecu;

  /// Whether the ECU runs whatever the tune holds, as if every correction
  /// reached it at once.
  late bool ecuRunsTune;

  late String source;

  setUpAll(() async {
    source = await rootBundle.loadString('assets/speeduino.ini');
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
    ecu = [
      for (var page = 1; page <= tune.pageCount; page++)
        Uint8List.fromList(tune.page(page)),
    ];
    ecuRunsTune = false;
  });

  tearDown(() => feed.close());

  TableView veOf(TuneState state) =>
      TableView.of(state, doc.tableNamed('veTable1Tbl')!)!;

  EcuConnected connectionFor({EcuFamily? family}) => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
      family: family,
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
    // What the ECU looked up, from what it holds - which is not what the tune
    // holds until a correction is sent or burned.
    final running = ecuRunsTune ? tune : TuneState.fromPages(doc, ecu);
    put(
      'VE1',
      veOf(running).interpolatedAt(rpm.toDouble(), load.toDouble())!.round(),
    );

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
    Size size = const Size(1400, 1200),
    EcuFamily? family,
    Object? sendFailure,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(
      overrides: [
        tuneProvider.overrideWith(
          () => _FakeTuneController(tune, ecu, failure: sendFailure),
        ),
        connectionProvider.overrideWith(
          () => _Connection(connectionFor(family: family)),
        ),
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
          theme: brandTheme(Brightness.light),
          home: Scaffold(
            body: AutotuneScreen(connection: connectionFor(family: family)),
          ),
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

  testWidgets('lays out at phone width, running or not', (tester) async {
    final container = await pumpAutotune(tester, size: const Size(400, 850));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();
    expect(container.read(autotuneProvider).armed, isTrue);

    // The status strip is at its widest once there is data and a reason.
    await drive(tester, afr: 15.5, count: 10);
    expect(tester.takeException(), isNull);
  });

  testWidgets('is not offered for a firmware it has not been checked on', (
    tester,
  ) async {
    await pumpAutotune(tester, family: EcuFamily.other);

    expect(find.textContaining('not yet available'), findsOneWidget);
    expect(find.text('Start autotune'), findsNothing);
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
    // Every sample moves a cell, so every notification marks the tune edited
    // - which is what drives the re-entry. For that the ECU has to be running
    // each correction as it is made.
    ecuRunsTune = true;
    final container = await pumpAutotune(tester, realtimeDependsOnTune: true);
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

  group('sending to the ECU', () {
    /// The VE cell the samples sit in, in [state].
    double veAtPoint(TuneState state) {
      final ve = veOf(state);
      final cell = ve.cellFor(2000, 60)!;
      return ve.valueAt(cell.row, cell.column)!;
    }

    _FakeTuneController tuneController(ProviderContainer container) =>
        container.read(tuneProvider.notifier) as _FakeTuneController;

    Finder sendSwitch() => find.descendant(
      of: find.ancestor(
        of: find.text('Send to ECU'),
        matching: find.byType(Row),
      ),
      matching: find.byType(Switch),
    );

    testWidgets('off, a corrected cell waits for a burn, and says so', (
      tester,
    ) async {
      final container = await pumpAutotune(tester);
      await tester.tap(find.text('Start autotune'));
      await tester.pumpAndSettle();

      // 20% lean: far more than two steps' worth.
      await drive(tester, afr: 17.6, count: 60);

      // Two 2% steps, and then the ECU is too far behind for a sample here
      // to say anything about the table.
      expect(veAtPoint(tune), 52);
      expect(veAtPoint(TuneState.fromPages(doc, ecu)), 50);
      expect(
        container.read(autotuneProvider).last?.rejectedBy?.id,
        'std_RunningVe',
      );
      expect(find.textContaining('still running'), findsOneWidget);
      expect(
        find.text('Burn, or switch on Send to ECU, to go on tuning here.'),
        findsOneWidget,
      );
    });

    testWidgets('on, each correction reaches the ECU and tuning goes on', (
      tester,
    ) async {
      final container = await pumpAutotune(tester);
      await tester.tap(sendSwitch());
      await tester.tap(find.text('Start autotune'));
      await tester.pumpAndSettle();
      expect(container.read(autotuneProvider).sendToEcu, isTrue);

      await drive(tester, afr: 17.6, count: 120);

      expect(tuneController(container).sent, isNotEmpty);
      expect(veAtPoint(tune), greaterThan(55));
      expect(veAtPoint(TuneState.fromPages(doc, ecu)), veAtPoint(tune));
      // Sent is not burned.
      expect(tune.isDirty, isTrue);
    });

    testWidgets('switched on part-way, sends what is waiting', (tester) async {
      final container = await pumpAutotune(tester);
      await tester.tap(find.text('Start autotune'));
      await tester.pumpAndSettle();
      await drive(tester, afr: 17.6, count: 60);
      expect(veAtPoint(TuneState.fromPages(doc, ecu)), 50);

      await tester.tap(sendSwitch());
      await tester.pumpAndSettle();

      expect(container.read(autotuneProvider).sendToEcu, isTrue);
      expect(veAtPoint(TuneState.fromPages(doc, ecu)), 52);
    });

    testWidgets('a send that fails turns sending off, and says why', (
      tester,
    ) async {
      final container = await pumpAutotune(
        tester,
        sendFailure: EcuProtocolException('no reply'),
      );
      await tester.tap(sendSwitch());
      await tester.tap(find.text('Start autotune'));
      await tester.pumpAndSettle();

      await drive(tester, afr: 17.6, count: 30);

      expect(container.read(autotuneProvider).sendToEcu, isFalse);
      expect(find.textContaining('Sending to the ECU stopped'), findsOneWidget);
      expect(find.textContaining('no reply'), findsOneWidget);
    });

    testWidgets('a read-only session cannot switch it on', (tester) async {
      await pumpAutotune(
        tester,
        permission: const WritePermission.refused('Write mode is off.'),
      );

      expect(tester.widget<Switch>(sendSwitch()).onChanged, isNull);
    });

    testWidgets('is not offered where the definition cannot write the page', (
      tester,
    ) async {
      final silent = IniParser(defined: {'CELSIUS'}).parse(
        source.replaceAll(
          RegExp(r'^[ \t]*page(Value|Chunk)Write[ \t]*=.*$', multiLine: true),
          '',
        ),
      );
      tune = TuneState.fromPages(silent, [
        for (var page = 1; page <= tune.pageCount; page++) tune.page(page),
      ]);
      await pumpAutotune(tester);

      expect(find.text('Send to ECU'), findsNothing);
    });

    testWidgets('turns off when the connection ends', (tester) async {
      final container = await pumpAutotune(tester);
      await tester.tap(sendSwitch());
      await tester.pumpAndSettle();
      expect(container.read(autotuneProvider).sendToEcu, isTrue);

      (container.read(connectionProvider.notifier) as _Connection).drop();
      await tester.pumpAndSettle();

      expect(container.read(autotuneProvider).sendToEcu, isFalse);
    });
  });
}
