@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:foxtune_tune/simulation.dart';
import 'package:test/test.dart';

/// Sending cells to the ECU's RAM as they change, against the simulator over
/// a real socket - the path autotuning takes when its corrections go to the
/// engine straight away rather than waiting for a burn.
void main() {
  late IniDocument doc;
  late FakeSpeeduino ecu;
  late TunedEngineSimulation engine;
  late SocketEcuLink link;
  late EcuClient client;
  late TuneState tune;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    doc = IniParser(defined: {'CELSIUS'})
        .parse(candidates.firstWhere((f) => f.existsSync()).readAsStringSync());
  });

  setUp(() async {
    ecu = FakeSpeeduino(
      signature: doc.identity.signature!,
      pageSizes: doc.constants.pageSizes,
      realtimeBlockSize: doc.outputChannels.blockSize!,
      channels: doc.outputChannels,
      constantResolver: (name) => engine.resolve(name),
    );
    for (final page in ecu.pages) {
      page.fillRange(0, page.length, 0);
    }
    engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
      ..seedTune(errorPercent: -12);

    // Closed loop off, so the error shows in the mixture.
    final seeded = TuneState.fromPages(doc, ecu.pages);
    final ego = SettingView.of(seeded, 'egoAlgorithm')!;
    ego.setOptionIndex(
      ego.options.indexWhere((o) => o.toLowerCase().contains('no correct')),
    );
    for (var page = 1; page <= ecu.pages.length; page++) {
      ecu.pages[page - 1].setAll(0, seeded.page(page));
    }

    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2))
      ..useDefinition(doc);
    tune = TuneState.empty(doc);
    await TuneWriter.readAll(client, into: tune);
    tune.markClean();
  });

  tearDown(() async {
    await client.close();
    await link.close();
    await ecu.stop();
  });

  TableView veOf(TuneState state) =>
      TableView.of(state, doc.tableNamed('veTable1Tbl')!)!;

  TuneWriter writer({
    WritePermission permission = const WritePermission.granted(),
    Future<void> Function(TuneState)? onSnapshot,
  }) =>
      TuneWriter(
        client: client,
        tune: tune,
        permission: permission,
        onSnapshot: onSnapshot,
      );

  Future<void> send(TuneWriter to, ({int row, int column}) cell) {
    final ve = veOf(tune);
    final at = ve.storageOf(cell.row, cell.column);
    return to.sendRange(ve.page, offset: at.offset, length: at.length);
  }

  test('sends the cell, and only the cell, and burns nothing', () async {
    final ve = veOf(tune);
    ve.setValueAt(9, 6, ve.valueAt(9, 6)! + 5);
    // Another edit on the same page, not meant to go yet.
    ve.setValueAt(2, 2, ve.valueAt(2, 2)! + 7);

    await send(writer(), (row: 9, column: 6));

    final inEcu = veOf(TuneState.fromPages(doc, ecu.pages));
    expect(inEcu.valueAt(9, 6), ve.valueAt(9, 6));
    expect(inEcu.valueAt(2, 2), ve.valueAt(2, 2)! - 7);
    expect(ecu.burnedPages, isEmpty);
    expect(tune.isDirty, isTrue, reason: 'still to be burned');
  });

  test('a read-only session sends nothing', () async {
    final ve = veOf(tune);
    final before = ve.valueAt(9, 6)!;
    ve.setValueAt(9, 6, before + 5);

    await expectLater(
      send(
        writer(permission: const WritePermission.refused('Write mode is off.')),
        (row: 9, column: 6),
      ),
      throwsA(isA<WriteRefusedException>()),
    );
    expect(veOf(TuneState.fromPages(doc, ecu.pages)).valueAt(9, 6), before);
  });

  test('a cell that does not read back as sent is reported', () async {
    ecu.mutateAfterWrite = true;
    final ve = veOf(tune);
    ve.setValueAt(9, 6, ve.valueAt(9, 6)! + 5);

    await expectLater(
      send(writer(), (row: 9, column: 6)),
      throwsA(isA<EcuProtocolException>()),
    );
  });

  test('takes one restore point however many cells it sends', () async {
    var restorePoints = 0;
    final to = writer(onSnapshot: (_) async => restorePoints++);
    final ve = veOf(tune);
    for (final cell in [(row: 9, column: 6), (row: 4, column: 3)]) {
      ve.setValueAt(
          cell.row, cell.column, ve.valueAt(cell.row, cell.column)! + 3);
      await send(to, cell);
    }

    expect(restorePoints, 1);
  });

  test('live autotuning converges with no burn, its steps sent as it goes',
      () async {
    final ve = veOf(tune);
    final rpm = ve.xAt(6)!;
    final map = ve.yAt(9)!;
    final truth = TunedEngineSimulation.defaultAirflow(rpm, map);

    final tuner = VeAutotuner.create(
      tune: tune,
      permission: const WritePermission.granted(),
      settings: const AutotuneSettings(minWeight: 3),
    ).tuner!;
    final decoder =
        RealtimeDecoder(doc.outputChannels, constantResolver: engine.resolve);
    final to = writer();

    final start = DateTime(2026, 1, 1);
    for (var t = 0.0; t < 40; t += 0.04) {
      ecu.writeEngineSample(
        engine,
        EngineConditions(
          seconds: 100 + t,
          phase: 0.5,
          throttle: 30,
          throttleRate: 0,
          rpm: rpm,
          map: map,
          coolant: 85,
          iat: 30,
          battery: 13.8,
          cranking: false,
          overrun: false,
        ),
      );
      final snapshot = decoder.decode(Uint8List.fromList(ecu.realtime));
      final outcome = tuner.offer(
        (name) => snapshot[name],
        start.add(Duration(milliseconds: (t * 1000).round())),
      );
      for (final cell in outcome.moved) {
        await send(to, cell);
      }
    }

    expect(ve.valueAt(9, 6), closeTo(truth, truth * 0.03));
    expect(veOf(TuneState.fromPages(doc, ecu.pages)).valueAt(9, 6),
        ve.valueAt(9, 6));
    expect(ecu.burnedPages, isEmpty);
  });
}
