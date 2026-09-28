@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:foxtune_tune/simulation.dart';
import 'package:test/test.dart';

/// Autotuning a simulated rusEFI, end to end.
///
/// The tune-driven engine runs on rusEFI's own definition, the simulated
/// rusEFI encodes each instant into its realtime block, and the real decoder
/// reads it back - so the autotuner sees what it would see from an ECU,
/// computed channels included. Autotuning's writes go back into the ECU's
/// pages each step, so the next sample is fuelled by what it just decided.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('../foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
    ];
    doc = IniParser().parse(
      candidates.firstWhere((f) => f.existsSync()).readAsStringSync(),
    );
  });

  /// Chooses [label] for the enumerated setting [name] in the ECU's pages.
  void setOption(List<Uint8List> pages, String name, String label) {
    final tune = TuneState.fromPages(doc, pages);
    final setting = SettingView.of(tune, name)!;
    final index = setting.options.indexOf(label);
    expect(index, isNonNegative, reason: '$name has no "$label"');
    setting.setOptionIndex(index);
    for (var page = 1; page <= pages.length; page++) {
      pages[page - 1].setAll(0, tune.page(page));
    }
  }

  /// A simulated rusEFI running a seeded tune, its VE table out by
  /// [veError] percent.
  ({FakeRusEfi ecu, TunedEngineSimulation engine}) rig({
    double veError = 0,
    bool lambda = false,
    bool closedLoop = false,
  }) {
    late final TunedEngineSimulation engine;
    final ecu = FakeRusEfi.fromDefinition(
      doc,
      constantResolver: (name) => engine.resolve(name),
    );
    for (final page in ecu.pages) {
      page.fillRange(0, page.length, 0);
    }
    // The display mode is the tuner's choice, made before seeding so the
    // target is laid down in the units the ECU will show it in.
    setOption(ecu.pages, 'useLambdaOnInterface', lambda ? 'Lambda' : 'AFR');
    engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
      ..seedTune(errorPercent: veError);
    if (!closedLoop) {
      setOption(ecu.pages, 'fuelClosedLoopCorrectionEnabled', 'disabled');
    }
    return (ecu: ecu, engine: engine);
  }

  EngineConditions at({
    required double seconds,
    double rpm = 3000,
    double map = 60,
    double tps = 30,
  }) =>
      EngineConditions(
        seconds: seconds,
        phase: 0.5,
        throttle: tps,
        throttleRate: 0,
        rpm: rpm,
        map: map,
        coolant: 85,
        iat: 30,
        battery: 13.8,
        cranking: false,
        overrun: false,
      );

  TableView veOf(List<Uint8List> pages) => TableView.of(
      TuneState.fromPages(doc, pages), doc.tableNamed('veTableTbl')!)!;

  /// Holds the engine at one operating point, autotuning as it goes.
  ///
  /// [corrupt] may rewrite each realtime block before it is decoded, as a
  /// failing sensor would.
  ({double tuned, double truth, VeAutotuner tuner}) converge(
    ({FakeRusEfi ecu, TunedEngineSimulation engine}) rig, {
    required double rpm,
    required double map,
    double tps = 30,
    double seconds = 40,
    void Function(Uint8List block)? corrupt,
  }) {
    final pages = rig.ecu.pages;
    final tune = TuneState.fromPages(doc, pages);
    final result = VeAutotuner.create(
      tune: tune,
      permission: const WritePermission.granted(),
      settings: const AutotuneSettings(minWeight: 3),
    );
    expect(result.readiness.reason, isNull);
    final tuner = result.tuner!;
    final decoder = RealtimeDecoder(
      doc.outputChannels,
      constantResolver: tuner.resolver.resolve,
    );

    final start = DateTime(2026, 1, 1);
    for (var t = 0.0; t < seconds; t += 0.04) {
      final conditions = at(seconds: 100 + t, rpm: rpm, map: map, tps: tps);
      rig.ecu.writeEngineSample(rig.engine, conditions);
      final block = Uint8List.fromList(rig.ecu.realtime);
      corrupt?.call(block);
      final snapshot = decoder.decode(block);

      tuner.offer(
        (name) => snapshot[name],
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
      tuner: tuner,
    );
  }

  group('seeding', () {
    test('lays down a tune autotuning will arm on', () {
      final r = rig();
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      String? option(String name) => SettingView.of(tune, name)!.optionLabel;

      expect(option('useMetricOnInterface'), 'Metric');
      expect(option('fuelAlgorithm'), 'Speed Density');
      expect(option('enableAemXSeries'), 'yes');
      expect(option('ltft_correctionEnabled'), 'no');

      final ve = veOf(r.ecu.pages);
      expect(ve.xAt(ve.columns - 1)!, greaterThan(ve.xAt(0)!));
      expect(ve.yAt(ve.rows - 1)!, greaterThan(ve.yAt(0)!));
    });

    test('lays the target down in the units the ECU shows', () {
      // The stored byte is lambda times 147 either way; only its reading
      // changes. 14.7 AFR and lambda 1.0 are the same target.
      for (final lambda in [false, true]) {
        final r = rig(lambda: lambda);
        final target = TableView.of(TuneState.fromPages(doc, r.ecu.pages),
            doc.tableNamed('veAnalyzeTargetTableTbl')!)!;
        expect(target.rawAt(0, 0), 147, reason: 'lambda: $lambda');
        expect(target.valueAt(0, 0), closeTo(lambda ? 1 : 14.7, 1e-9));
        expect(target.zUnits, lambda ? 'lambda' : 'afr');
      }
    });
  });

  group('over the wire', () {
    test('every channel autotuning reads is sent, and plausible', () {
      final r = rig(veError: -10);
      final conditions = at(seconds: 100, map: 68);
      r.ecu.writeEngineSample(r.engine, conditions);
      expect(r.ecu.unresolvedChannels, isEmpty);

      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final snapshot = RealtimeDecoder(doc.outputChannels,
              constantResolver: TuneValueResolver(tune).resolve)
          .decode(r.ecu.realtime);

      // Lean, with the VE table low - and reported the same way on every
      // channel that carries it.
      expect(snapshot['veAnalyzeAfrLambda1'], greaterThan(15));
      expect(snapshot['afrGasolineScale'],
          closeTo(snapshot['lambdaValue']! * 14.7, 0.01));
      expect(snapshot['egoCorrectionForVeAnalyze'], closeTo(100, 0.01));
      expect(snapshot['veTableYAxis'], closeTo(68, 0.01));
      expect(snapshot['afrTableYAxis'], closeTo(68, 0.01));
      expect(snapshot['VBatt'], closeTo(13.8, 0.01));
    });

    test('a correct table runs on target', () {
      final r = rig();
      final snapshot = () {
        for (var t = 0.0; t < 3; t += 0.04) {
          r.ecu.writeEngineSample(r.engine, at(seconds: 100 + t, map: 68));
        }
        final tune = TuneState.fromPages(doc, r.ecu.pages);
        return RealtimeDecoder(doc.outputChannels,
                constantResolver: TuneValueResolver(tune).resolve)
            .decode(r.ecu.realtime);
      }();
      expect(snapshot['veAnalyzeAfrLambda1'], closeTo(14.7, 0.15));
    });
  });

  group('autotuning', () {
    test('brings a low VE table up to the engine, in AFR', () {
      // The case that proves the units are read from the table rather than
      // the channel's name, which says "lambda" even in AFR mode. Read as
      // lambda, a 14.7 target is no mixture at all, and nothing is tuned.
      final r = rig(veError: -12);
      final ve = veOf(r.ecu.pages);
      final outcome = converge(r, rpm: ve.xAt(6)!, map: ve.yAt(9)!);
      expect(outcome.tuner.units, MixtureUnits.afr);
      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.03));
    });

    test('brings a high VE table down to the engine, in lambda', () {
      final r = rig(veError: 12, lambda: true);
      final ve = veOf(r.ecu.pages);
      final outcome = converge(r, rpm: ve.xAt(6)!, map: ve.yAt(9)!);
      expect(outcome.tuner.units, MixtureUnits.lambda);
      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.03));
    });

    test('sees through the closed loop rather than tuning against it', () {
      final r = rig(veError: -12, closedLoop: true);
      final ve = veOf(r.ecu.pages);
      final outcome =
          converge(r, rpm: ve.xAt(6)!, map: ve.yAt(9)!, seconds: 60);
      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.05));
    });

    test('reads the target where the target table says the engine is', () {
      // With the target table on throttle and the VE table on MAP, the two
      // loads differ. Reading the target at the VE table's load would chase
      // the wrong mixture - here, 1.5 AFR leaner than the engine is fuelled
      // for - and move the table off the engine instead of onto it.
      final r = rig(veError: -12);
      setOption(r.ecu.pages, 'afrOverrideMode', 'TPS');
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final target =
          TableView.of(tune, doc.tableNamed('veAnalyzeTargetTableTbl')!)!;
      for (var row = 0; row < target.rows; row++) {
        target.setYAt(row, 100 * row / (target.rows - 1));
      }
      for (var row = 0; row < target.rows; row++) {
        for (var column = 0; column < target.columns; column++) {
          target.setValueAt(row, column, 12.5 + target.yAt(row)! * 0.04);
        }
      }
      for (var page = 1; page <= r.ecu.pages.length; page++) {
        r.ecu.pages[page - 1].setAll(0, tune.page(page));
      }

      final ve = veOf(r.ecu.pages);
      final outcome = converge(r, rpm: ve.xAt(6)!, map: ve.yAt(9)!, tps: 30);
      expect(outcome.tuned, closeTo(outcome.truth, outcome.truth * 0.03));
    });

    test('a dead wideband leaves the table alone', () {
      // rusEFI's definition declares no dead-sensor filter. A reading of zero
      // would otherwise take every cell it passes down to the session limit.
      final r = rig(veError: -12);
      final before = [for (final p in r.ecu.pages) Uint8List.fromList(p)];
      final ve = veOf(r.ecu.pages);

      void zero(Uint8List block, String channel) {
        final offset = doc.outputChannels.channelNamed(channel)!.offset!;
        block[offset] = 0;
        block[offset + 1] = 0;
      }

      final outcome = converge(
        r,
        rpm: ve.xAt(6)!,
        map: ve.yAt(9)!,
        corrupt: (block) {
          zero(block, 'afrGasolineScale');
          zero(block, 'lambdaValue');
        },
      );

      expect(outcome.tuner.acceptedSamples, 0);
      expect(outcome.tuner.movedCells, 0);
      for (var i = 0; i < before.length; i++) {
        expect(r.ecu.pages[i], before[i], reason: 'page ${i + 1}');
      }
    });
  });
}
