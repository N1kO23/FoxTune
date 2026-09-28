@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:foxtune_tune/simulation.dart';
import 'package:test/test.dart';

/// Autotuning against rusEFI's own `[VeAnalyze]`, sample by sample.
///
/// rusEFI's section differs from Speeduino's in ways that each broke an
/// assumption: one channel for lambda and AFR alike, a target table with its
/// own load channel, no dead-sensor filter, and a narrowband that is a
/// calibration preset rather than a sensor type.
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

  /// A seeded tune: Metric, speed density, a CAN wideband, no long-term
  /// trims - everything autotuning needs - with the display in [lambda].
  TuneState seeded({bool lambda = false}) {
    final pages = [for (final size in doc.constants.pageSizes) Uint8List(size)];
    final display = TuneState.fromPages(doc, pages);
    SettingView.of(display, 'useLambdaOnInterface')!
        .setOptionIndex(lambda ? 1 : 0);
    for (var page = 1; page <= pages.length; page++) {
      pages[page - 1].setAll(0, display.page(page));
    }
    TunedEngineSimulation(definition: doc, pages: pages).seedTune();
    return TuneState.fromPages(doc, pages);
  }

  void choose(TuneState tune, String name, String label) {
    final setting = SettingView.of(tune, name)!;
    final index = setting.options.indexOf(label);
    expect(index, isNonNegative, reason: '$name has no "$label"');
    setting.setOptionIndex(index);
  }

  void set(TuneState tune, String name, double value) =>
      SettingView.of(tune, name)!.setValue(value);

  ({VeAutotuner? tuner, AutotuneReadiness readiness}) arm(TuneState tune) =>
      VeAutotuner.create(
        tune: tune,
        permission: const WritePermission.granted(),
      );

  group('readiness', () {
    test('a seeded tune is ready', () {
      expect(arm(seeded()).readiness.reason, isNull);
    });

    test('refuses with no O2 input at all', () {
      final tune = seeded();
      choose(tune, 'enableAemXSeries', 'no');
      choose(tune, 'afr_hwChannel', 'NONE');
      expect(arm(tune).readiness.reason, contains('No O2 sensor input'));
    });

    test('refuses an analog input calibrated as a narrowband', () {
      // rusEFI's own "Narrow Band" preset for the analog input.
      final tune = seeded();
      choose(tune, 'enableAemXSeries', 'no');
      SettingView.of(tune, 'afr_hwChannel')!.setOptionIndex(1);
      set(tune, 'afr_v1', 0.1);
      set(tune, 'afr_value1', 15);
      set(tune, 'afr_v2', 0.9);
      set(tune, 'afr_value2', 14);
      expect(arm(tune).readiness.reason, contains('narrowband'));
    });

    test('accepts an analog input calibrated as a wideband', () {
      // The 14Point7 preset.
      final tune = seeded();
      choose(tune, 'enableAemXSeries', 'no');
      SettingView.of(tune, 'afr_hwChannel')!.setOptionIndex(1);
      set(tune, 'afr_v1', 0);
      set(tune, 'afr_value1', 9.996);
      set(tune, 'afr_v2', 5);
      set(tune, 'afr_value2', 19.992);
      expect(arm(tune).readiness.reason, isNull);
    });

    test('refuses a MAP axis shown in psi', () {
      // The bins would be psi while the live load is kPa.
      final tune = seeded();
      choose(tune, 'useMetricOnInterface', 'Imperial');
      expect(
        arm(tune).readiness.reason,
        allOf(contains('Imperial'), contains('Temperature/Pressure display')),
      );
    });

    test('accepts Imperial where no axis changes with it', () {
      // Alpha-N load is throttle, which reads the same either way.
      final tune = seeded();
      choose(tune, 'useMetricOnInterface', 'Imperial');
      choose(tune, 'fuelAlgorithm', 'Alpha-N');
      expect(arm(tune).readiness.reason, isNull);
    });

    test('refuses while long-term trims are applied', () {
      final tune = seeded();
      choose(tune, 'ltft_correctionEnabled', 'yes');
      expect(arm(tune).readiness.reason, contains('"Apply Correction"'));
    });
  });

  group('one sample', () {
    /// A steady reading at a mid-table operating point, [measured] in the
    /// display's units, with anything in [overrides] replacing it.
    AnalyzeSample reading(
      VeAutotuner tuner, {
      required double measured,
      Map<String, double?> overrides = const {},
    }) {
      final values = <String, double?>{
        'RPMValue': tuner.table.xAt(6),
        'veTableYAxis': tuner.table.yAt(9),
        'afrTableYAxis': tuner.table.yAt(9),
        'coolant': 85,
        'deltaTps': 0,
        'VBatt': 13.8,
        'TPSValue': 30,
        'veAnalyzeAfrLambda1': measured,
        'egoCorrectionForVeAnalyze': 100,
        ...overrides,
      };
      return (name) => values[name];
    }

    /// Offers [read] once to start the settling clock, then again once it
    /// has run out, returning the second outcome.
    AutotuneOutcome settled(VeAutotuner tuner, AnalyzeSample read) {
      final start = DateTime(2026, 1, 1);
      tuner.offer(read, start);
      return tuner.offer(read, start.add(const Duration(seconds: 1)));
    }

    test('reads 5% lean the same in AFR and in lambda', () {
      final afr = arm(seeded()).tuner!;
      final lambda = arm(seeded(lambda: true)).tuner!;
      expect(afr.units, MixtureUnits.afr);
      expect(lambda.units, MixtureUnits.lambda);

      final inAfr = settled(afr, reading(afr, measured: 14.7 * 1.05));
      final inLambda = settled(lambda, reading(lambda, measured: 1.05));
      expect(inAfr.ratio, closeTo(1.05, 1e-6));
      expect(inLambda.ratio, closeTo(1.05, 1e-6));
    });

    test('reads AFR as petrol whatever the fuel', () {
      // rusEFI's AFR channel and target are lambda times 14.7 even on E85.
      // Converting with the fuel's own ratio would call a 5% lean reading
      // lambda 1.58 - implausible - and throw it away.
      final tune = seeded();
      set(tune, 'stoichRatioPrimary', 9.8);
      final tuner = arm(tune).tuner!;
      final outcome = settled(tuner, reading(tuner, measured: 14.7 * 1.05));
      expect(outcome.accepted, isTrue);
      expect(outcome.ratio, closeTo(1.05, 1e-6));
    });

    test('folds in the closed-loop trim', () {
      final tuner = arm(seeded()).tuner!;
      final outcome = settled(
        tuner,
        reading(tuner,
            measured: 14.7, overrides: {'egoCorrectionForVeAnalyze': 105}),
      );
      expect(outcome.ratio, closeTo(1.05, 1e-6));
    });

    test('throws away a wideband reading zero', () {
      final tune = seeded();
      final tuner = arm(tune).tuner!;
      final outcome = settled(tuner, reading(tuner, measured: 0));
      expect(outcome.rejectedBy?.id, 'std_DeadLambda');
      expect(tuner.acceptedSamples, 0);
      expect(tune.dirtyPages, isEmpty);
    });

    test('throws away lambda readings once armed for AFR', () {
      // The display switched after arming: the channel now carries lambda,
      // which as AFR is an impossibly rich mixture.
      final tuner = arm(seeded()).tuner!;
      final outcome = settled(tuner, reading(tuner, measured: 1.0));
      expect(outcome.accepted, isFalse);
      expect(outcome.rejectedBy?.id, 'std_DeadLambda');
    });

    test('waits for the target table\'s own load', () {
      final tuner = arm(seeded()).tuner!;
      final outcome = settled(
        tuner,
        reading(tuner, measured: 14.7, overrides: {'afrTableYAxis': null}),
      );
      expect(outcome.accepted, isFalse);
      expect(outcome.detail, contains('afrTableYAxis'));
    });

    test('each of the definition\'s filters rejects under its own name', () {
      for (final (channel, value, id) in [
        ('RPMValue', 400.0, 'minRPMFilter'),
        ('coolant', 40.0, 'minCltFilter'),
        ('deltaTps', 60.0, 'deltaTps'),
        ('VBatt', 11.0, 'VBatt'),
        ('TPSValue', 0.5, 'minTps'),
      ]) {
        final tuner = arm(seeded()).tuner!;
        final outcome = settled(
          tuner,
          reading(tuner, measured: 14.7, overrides: {channel: value}),
        );
        expect(outcome.rejectedBy?.id, id, reason: '$channel = $value');
      }
    });
  });
}
