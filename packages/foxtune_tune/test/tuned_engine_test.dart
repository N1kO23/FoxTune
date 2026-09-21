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

/// The simulated engine, against the real shipped definition.
///
/// The property that matters is that fuelling is *caused* by the tune rather
/// than made up: edit the VE table and the exhaust changes. Everything the
/// autotuner does rests on that being true.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  /// The ECU's page memory, as the simulator holds it.
  List<Uint8List> freshPages() =>
      [for (final size in doc.constants.pageSizes) Uint8List(size)];

  /// Switches the ECU's own closed-loop correction on or off.
  ///
  /// Several properties of the fuelling model are only visible open-loop,
  /// because a working closed loop is supposed to hide exactly the error being
  /// measured.
  void setClosedLoop(List<Uint8List> pages, bool on) {
    final tune = TuneState.fromPages(doc, pages);
    final setting = SettingView.of(tune, 'egoAlgorithm')!;
    final options = setting.options;
    setting.setOptionIndex(
      on
          ? options.indexWhere((o) => o.toLowerCase() == 'simple')
          : options.indexWhere((o) => o.toLowerCase().contains('no correct')),
    );
    for (var page = 1; page <= pages.length; page++) {
      pages[page - 1].setAll(0, tune.page(page));
    }
  }

  TunedEngineSimulation engineOn(
    List<Uint8List> pages, {
    double veError = 0,
    bool closedLoop = true,
  }) {
    final engine = TunedEngineSimulation(definition: doc, pages: pages)
      ..seedTune(errorPercent: veError);
    if (!closedLoop) setClosedLoop(pages, false);
    return engine;
  }

  EngineConditions at({
    double seconds = 100,
    double rpm = 3000,
    double map = 60,
    double tps = 30,
    double coolant = 85,
    double throttleRate = 0,
    bool cranking = false,
    bool overrun = false,
  }) =>
      EngineConditions(
        seconds: seconds,
        phase: 0.5,
        throttle: tps,
        throttleRate: throttleRate,
        rpm: rpm,
        map: map,
        coolant: coolant,
        iat: 30,
        battery: 13.8,
        cranking: cranking,
        overrun: overrun,
      );

  /// Runs the engine forward, returning the last sample.
  Map<String, double> run(
    TunedEngineSimulation engine, {
    required EngineConditions Function(double seconds) at,
    double seconds = 5,
    double step = 0.04,
  }) {
    var sample = <String, double>{};
    for (var t = 0.0; t < seconds; t += step) {
      sample = engine.sampleAt(at(t));
    }
    return sample;
  }

  group('seeding', () {
    test('lays down a coherent tune where there were filler bytes', () {
      final pages = freshPages();
      engineOn(pages);

      final tune = TuneState.fromPages(doc, pages);
      final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

      // Axes ascend, which filler bytes do not.
      expect(ve.isXAxisAscending, isTrue);
      expect(ve.isYAxisAscending, isTrue);
      expect(ve.xAt(0), lessThan(ve.xAt(ve.columns - 1)!));

      // And the settings the simulation itself reads are sane.
      expect(SettingView.of(tune, 'stoich')!.value, closeTo(14.7, 0.05));
      expect(SettingView.of(tune, 'egoType')!.optionLabel, contains('Wide'));
      // "MAP" is speed density, and must not be confused with "IMAP/EMAP".
      expect(SettingView.of(tune, 'algorithm')!.optionLabel, 'MAP');
    });

    test('offsets the VE table by the error asked for', () {
      final pages = freshPages();
      final engine = engineOn(pages, veError: -10);

      final tune = TuneState.fromPages(doc, pages);
      final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

      final rpm = ve.xAt(8)!;
      final load = ve.yAt(8)!;
      expect(
        ve.valueAt(8, 8),
        closeTo(TunedEngineSimulation.defaultAirflow(rpm, load) * 0.9, 1.5),
      );
      expect(engine.resolve('stoich'), closeTo(14.7, 0.05));
    });
  });

  group('fuelling follows the VE table', () {
    test('a correct table runs on target', () {
      final engine = engineOn(freshPages(), closedLoop: false);
      // Long enough for the sensor lag to settle.
      final sample = run(engine, at: (t) => at(seconds: 100 + t));

      expect(sample['afr'], closeTo(14.7, 0.3));
    });

    test('a table that is low runs lean, by about the same proportion', () {
      final engine = engineOn(freshPages(), veError: -20, closedLoop: false);
      final sample = run(engine, at: (t) => at(seconds: 100 + t));

      // 20% short of fuel is about 25% lean in AFR terms.
      expect(sample['afr'], closeTo(14.7 / 0.8, 0.5));
    });

    test('a table that is high runs rich', () {
      final engine = engineOn(freshPages(), veError: 15, closedLoop: false);
      final sample = run(engine, at: (t) => at(seconds: 100 + t));

      expect(sample['afr'], lessThan(14.0));
    });

    test('editing the table in the ECU changes what the engine runs', (() {
      final pages = freshPages();
      final engine = engineOn(pages, closedLoop: false);
      final before = run(engine, at: (t) => at(seconds: 100 + t))['afr']!;
      expect(before, closeTo(14.7, 0.3));

      // Write a leaner VE table straight into the ECU's pages, as a client
      // burn would.
      final tune = TuneState.fromPages(doc, pages);
      final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
      for (var r = 0; r < ve.rows; r++) {
        for (var c = 0; c < ve.columns; c++) {
          ve.setValueAt(r, c, ve.valueAt(r, c)! * 0.75);
        }
      }
      for (var page = 1; page <= pages.length; page++) {
        pages[page - 1].setAll(0, tune.page(page));
      }

      final after = run(engine, at: (t) => at(seconds: 200 + t))['afr']!;
      expect(after, greaterThan(before + 2));
    }));

    test('the reported mixture lags a step change, as a sensor does', () {
      final pages = freshPages();
      final engine = engineOn(pages, veError: -25, closedLoop: false);

      // One sample only: the wideband cannot have caught up yet.
      engine.sampleAt(at(seconds: 100));
      final first = engine.sampleAt(at(seconds: 100.04))['afr']!;
      final settled = run(engine, at: (t) => at(seconds: 100 + t))['afr']!;

      expect(first, lessThan(settled));
    });
  });

  group('closed loop', () {
    test('trims fuelling back towards the target', () {
      final engine = engineOn(freshPages(), veError: -10);
      final sample = run(
        engine,
        at: (t) => at(seconds: 100 + t),
        seconds: 60,
      );

      // The loop has added fuel...
      expect(sample['egoCorrection'], greaterThan(103));
      // ...and dragged the mixture most of the way back to target.
      expect(sample['afr'], closeTo(14.7, 0.6));
    });

    test('stays out of it when the engine is cold', () {
      final engine = engineOn(freshPages(), veError: -10);
      final sample = run(
        engine,
        at: (t) => at(seconds: 100 + t, coolant: 30),
        seconds: 30,
      );

      expect(sample['egoCorrection'], 100);
    });

    test('holds within the limit the tune declares', () {
      final engine = engineOn(freshPages(), veError: -40);
      final sample = run(
        engine,
        at: (t) => at(seconds: 100 + t),
        seconds: 120,
      );

      final limit = engine.resolve('egoLimit')!;
      expect(sample['egoCorrection'], lessThanOrEqualTo(100 + limit));
      // And a correction that large cannot fix a table that wrong.
      expect(sample['afr'], greaterThan(15.5));
    });
  });

  group('autotuning against the simulated engine', () {
    /// The `engine` status byte, packed the way the ECU packs it.
    ///
    /// Building it from the definition's own bit positions is what lets the
    /// accel and afterstart filters actually fire, rather than being skipped
    /// because the channel was missing.
    double statusByte(Map<String, bool> flags) {
      final status = doc.outputChannels.channelNamed('engine')!;
      var value = 0;
      flags.forEach((name, on) {
        final field = doc.outputChannels.channelNamed(name);
        if (field is! IniBitsField || field.offset != status.offset) return;
        if (on) value |= 1 << field.lowBit;
      });
      return value.toDouble();
    }

    /// Drives the engine at one operating point, autotuning as it goes.
    ///
    /// The tune the autotuner writes is pushed back into the ECU's pages each
    /// step, exactly as burning would, so the engine's next sample is fuelled
    /// by what autotuning just decided. That feedback is the point: without
    /// it this would only be testing arithmetic.
    ({double tuned, double truth}) converge(
      List<Uint8List> pages,
      TunedEngineSimulation engine, {
      required double rpm,
      required double map,
      double seconds = 40,
    }) {
      final tune = TuneState.fromPages(doc, pages);
      final result = VeAutotuner.create(
        tune: tune,
        permission: const WritePermission.granted(),
        settings: const AutotuneSettings(minWeight: 3),
      );
      expect(result.readiness.reason, isNull);
      final tuner = result.tuner!;

      final start = DateTime(2026, 1, 1);
      for (var t = 0.0; t < seconds; t += 0.04) {
        final conditions = at(seconds: 100 + t, rpm: rpm, map: map);
        final sample = engine.sampleAt(conditions);
        final status = statusByte(engine.flagsAt(conditions));

        tuner.offer(
          (name) => switch (name) {
            'coolant' => sample['coolantRaw']! - 40,
            'iat' => sample['iatRaw']! - 40,
            'engine' => status,
            _ => sample[name],
          },
          start.add(Duration(milliseconds: (t * 1000).round())),
        );

        for (var page = 1; page <= pages.length; page++) {
          pages[page - 1].setAll(0, tune.page(page));
        }
      }

      final cell = tuner.table.cellFor(rpm, map)!;
      return (
        tuned: tuner.table.valueAt(cell.row, cell.column)!,
        truth: TunedEngineSimulation.defaultAirflow(rpm, map),
      );
    }

    test('brings a VE table that is low up to the engine', () {
      final pages = freshPages();
      final engine = engineOn(pages, veError: -12, closedLoop: false);
      final ve = TableView.of(
          TuneState.fromPages(doc, pages), doc.tableNamed('veTable1Tbl')!)!;

      final outcome = converge(
        pages,
        engine,
        rpm: ve.xAt(6)!,
        map: ve.yAt(9)!,
      );

      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.03));
    });

    test('brings a VE table that is high down to the engine', () {
      final pages = freshPages();
      final engine = engineOn(pages, veError: 12, closedLoop: false);
      final ve = TableView.of(
          TuneState.fromPages(doc, pages), doc.tableNamed('veTable1Tbl')!)!;

      final outcome = converge(
        pages,
        engine,
        rpm: ve.xAt(6)!,
        map: ve.yAt(9)!,
      );

      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.03));
    });

    test('sees through the closed loop rather than tuning against it', () {
      // With correction running, the mixture reads near target even though
      // the table is wrong. Folding the trim into the correction is what lets
      // autotuning find the real error instead of concluding all is well.
      final pages = freshPages();
      final engine = engineOn(pages, veError: -12);
      final ve = TableView.of(
          TuneState.fromPages(doc, pages), doc.tableNamed('veTable1Tbl')!)!;

      final outcome = converge(
        pages,
        engine,
        rpm: ve.xAt(6)!,
        map: ve.yAt(9)!,
        seconds: 60,
      );

      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.05));
    });
  });

  group('over the wire', () {
    test('a client reads a coherent engine from the simulator', () async {
      // What `fake_ecu` actually serves: the same simulation, reached through
      // the real envelope, CRC and realtime command.
      // Constants resolve from the ECU's live pages, so a setting written
      // over the wire takes effect instead of leaving the realtime block
      // scaled by a stale copy.
      late final TunedEngineSimulation engine;
      final ecu = FakeSpeeduino(
        signature: doc.identity.signature!,
        pageSizes: doc.constants.pageSizes,
        realtimeBlockSize: doc.outputChannels.blockSize!,
        blockingFactor: doc.constants.blockingFactor!,
        channels: doc.outputChannels,
        constantResolver: (name) => engine.resolve(name),
      );
      engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
        ..seedTune(errorPercent: -10);

      final port = await ecu.start();
      final link = await SocketEcuLink.connect('127.0.0.1', port);
      final client = EcuClient(link, timeout: const Duration(seconds: 2));
      addTearDown(() async {
        await client.close();
        await link.close();
        await ecu.stop();
      });

      ecu.simulateEngine(simulation: engine);
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final decoder = RealtimeDecoder(
        doc.outputChannels,
        constantResolver: engine.resolve,
      );
      final snapshot = decoder.decode(
        await client.readRealtime(count: doc.outputChannels.blockSize!),
      );

      expect(ecu.unresolvedChannels, isEmpty,
          reason: 'every channel must scale from the seeded tune');
      expect(snapshot['rpm'], inInclusiveRange(0, 8000));
      expect(snapshot['afr'], inInclusiveRange(9, 22.5));
      expect(snapshot['VE1'], inInclusiveRange(10, 130));
      expect(snapshot['egoCorrection'], inInclusiveRange(80, 120));
      expect(snapshot['coolant'], inInclusiveRange(-10, 130));
      // A value the definition only produces by expression, which needs the
      // tune the simulator is holding.
      expect(snapshot['fuelLoad'], isNotNull);
      // A 16-bit channel once read two bytes of the test pattern here and
      // showed 13875%.
      expect(snapshot['gammaEnrich'], inInclusiveRange(0, 250));
      expect(snapshot['loopsPerSecond'], greaterThan(900));
      // Hardware the simulated engine does not have reads zero, as it would
      // on a real ECU - not leftover filler.
      expect(snapshot['auxin_gauge0'], 0);
      expect(snapshot['vss'], 0);
    });
  });

  group('the rest of the engine', () {
    test('cuts fuel on the overrun', () {
      final engine = engineOn(freshPages());
      final conditions = at(seconds: 100, tps: 0, map: 30, overrun: true);
      engine.sampleAt(at(seconds: 99));
      final sample = engine.sampleAt(conditions);

      expect(sample['pulseWidth'], 0);
      expect(sample['afr'], greaterThan(19));
      expect(engine.flagsAt(conditions)['DFCOOn'], isTrue);
    });

    test('enriches when cold, and says so', () {
      final engine = engineOn(freshPages());
      final cold = at(seconds: 100, coolant: 10);
      final warm = at(seconds: 100, coolant: 90);

      engine.sampleAt(at(seconds: 99));
      final coldSample = engine.sampleAt(cold);
      expect(coldSample['warmupEnrich'], greaterThan(110));
      expect(engine.flagsAt(cold)['warmup'], isTrue);

      engine.sampleAt(at(seconds: 199));
      final warmSample = engine.sampleAt(warm);
      expect(warmSample['warmupEnrich'], closeTo(100, 1));
      expect(engine.flagsAt(warm)['warmup'], isFalse);
    });

    test('reports gamma enrichment as the product of its corrections', () {
      final engine = engineOn(freshPages());
      final cold = at(seconds: 2, coolant: 20);
      engine.sampleAt(at(seconds: 1, coolant: 20));
      final sample = engine.sampleAt(cold);

      expect(sample['warmupEnrich'], greaterThan(110));
      expect(sample['ASECurr'], greaterThan(100));
      expect(
        sample['gammaEnrich'],
        closeTo(
          sample['warmupEnrich']! *
              sample['ASECurr']! *
              sample['accelEnrich']! *
              sample['egoCorrection']! /
              1e6,
          0.01,
        ),
      );

      // And the firmware zeroes it when it cuts fuel.
      engine.sampleAt(at(seconds: 199, tps: 0, map: 30));
      final cut = engine.sampleAt(
        at(seconds: 200, tps: 0, map: 30, overrun: true),
      );
      expect(cut['gammaEnrich'], 0);
    });

    test('runs afterstart enrichment just after a start', () {
      final engine = engineOn(freshPages());
      final justStarted = at(seconds: 2, coolant: 20);

      engine.sampleAt(at(seconds: 1, coolant: 20));
      expect(engine.flagsAt(justStarted)['ase'], isTrue);

      engine.sampleAt(at(seconds: 199, coolant: 20));
      expect(engine.flagsAt(at(seconds: 200, coolant: 20))['ase'], isFalse);
    });

    test('flags a throttle stab as acceleration enrichment', () {
      final engine = engineOn(freshPages());
      engine.sampleAt(at(seconds: 100));

      final stab = at(seconds: 100.04, throttleRate: 200);
      engine.sampleAt(stab);
      expect(engine.flagsAt(stab)['tpsaccaen'], isTrue);

      // And it decays once the throttle stops moving.
      var conditions = stab;
      for (var t = 0.0; t < 3; t += 0.04) {
        conditions = at(seconds: 100.1 + t);
        engine.sampleAt(conditions);
      }
      expect(engine.flagsAt(conditions)['tpsaccaen'], isFalse);
    });

    test('takes ignition advance from the spark table', () {
      final engine = engineOn(freshPages());
      engine.sampleAt(at(seconds: 99));

      final low = engine.sampleAt(at(seconds: 100, rpm: 1000))['advance']!;
      engine.sampleAt(at(seconds: 199));
      final high = engine.sampleAt(at(seconds: 200, rpm: 6000))['advance']!;

      expect(high, greaterThan(low));
    });

    test('pulse width and duty cycle follow the fuelling', () {
      final engine = engineOn(freshPages());
      engine.sampleAt(at(seconds: 99));
      final light = engine.sampleAt(at(seconds: 100, map: 30, rpm: 1500));
      engine.sampleAt(at(seconds: 199));
      final heavy = engine.sampleAt(at(seconds: 200, map: 95, rpm: 5000));

      expect(heavy['pulseWidth'], greaterThan(light['pulseWidth']!));
      expect(heavy['dutyCycle'], greaterThan(light['dutyCycle']!));
      expect(heavy['dutyCycle'], lessThanOrEqualTo(100));
    });
  });
}
