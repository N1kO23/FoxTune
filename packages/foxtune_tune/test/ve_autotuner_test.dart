import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// A 4x4 VE table with a deliberately coarser 2x2 target on its own axes.
///
/// The mismatch is the point: a target table's bins need not line up with the
/// table being tuned, so the target has to be interpolated at the operating
/// point rather than read by cell index.
const _source = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 64
page = 1
  stoich   = scalar, U08, 0, ":1", 0.1, 0.0, 8.0, 25.5, 1
  egoType  = bits,   U08, 1, [0:1], "Disabled", "Narrow Band", "Wide Band", "INVALID"
  veTable  = array,  U08, 2,  [4x4], "%",   1.0,   0.0, 0.0,   255.0,   0
  rpmBins  = array,  U08, 18, [4],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  loadBins = array,  U08, 22, [4],   "kPa", 2.0,   0.0, 0.0,   510.0,   0
  afrTable = array,  U08, 26, [2x2], "AFR", 0.1,   0.0, 10.0,  25.0,    1
  afrRpm   = array,  U08, 30, [2],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  afrLoad  = array,  U08, 32, [2],   "kPa", 2.0,   0.0, 0.0,   510.0,   0
[TableEditor]
  table = veTable1Tbl, veTable1Map, "VE Table", 1
    xBins = rpmBins, rpm
    yBins = loadBins, fuelLoad
    zBins = veTable
  table = afrTable1Tbl, afrTable1Map, "AFR Table", 1
    xBins = afrRpm, rpm
    yBins = afrLoad, fuelLoad
    zBins = afrTable
[VeAnalyze]
  veAnalyzeMap = veTable1Tbl, afrTable1Tbl, afr, egoCorrection
  filter = std_xAxisMin
  filter = std_xAxisMax
  filter = std_yAxisMin
  filter = std_yAxisMax
  filter = std_DeadLambda
  filter = minCltFilter,  "Minimum CLT", coolant,    <, 71, , true
  filter = accelFilter,   "Accel Flag",  engine,     &, 16, , false
  filter = overrunFilter, "Overrun",     pulseWidth, =, 0,  , false
  filter = std_Custom
''';

IniDocument get definition => IniParser().parse(_source);

/// A tune with a flat 50% VE table and a flat 14.7 target.
TuneState buildTune({int egoType = 2, double ve = 50}) {
  final tune = TuneState.empty(definition);

  final stoich = tune.locate('stoich')!;
  tune.writeRaw(stoich.page, stoich.field, 147);
  final ego = tune.locate('egoType')!;
  tune.writeBits(ego.page, ego.field as IniBitsField, egoType);

  final veTable = TableView.of(tune, definition.tableNamed('veTable1Tbl')!)!;
  for (var i = 0; i < 4; i++) {
    veTable.setXAt(i, 500 + i * 1000);
    veTable.setYAt(i, 20 + i * 20);
  }
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      veTable.setValueAt(r, c, ve);
    }
  }

  final afr = TableView.of(tune, definition.tableNamed('afrTable1Tbl')!)!;
  afr.setXAt(0, 500);
  afr.setXAt(1, 3500);
  afr.setYAt(0, 20);
  afr.setYAt(1, 80);
  for (var r = 0; r < 2; r++) {
    for (var c = 0; c < 2; c++) {
      afr.setValueAt(r, c, 14.7);
    }
  }

  tune.markClean();
  return tune;
}

void main() {
  late TuneState tune;
  late DateTime clock;

  setUp(() {
    tune = buildTune();
    clock = DateTime(2026, 1, 1);
  });

  VeAutotuner tuner({
    AutotuneSettings settings = const AutotuneSettings(),
    WritePermission permission = const WritePermission.granted(),
    TuneState? state,
  }) =>
      VeAutotuner.create(
        tune: state ?? tune,
        permission: permission,
        settings: settings,
      ).tuner!;

  /// One sample, with everything set so nothing but the mixture is in play.
  AnalyzeSample sample({
    double rpm = 1500,
    double load = 40,
    double afr = 14.7,
    double ego = 100,
    double coolant = 85,
    double engine = 0,
    double pulseWidth = 3,
  }) =>
      (channel) => switch (channel) {
            'rpm' => rpm,
            'fuelLoad' => load,
            'afr' => afr,
            'egoCorrection' => ego,
            'coolant' => coolant,
            'engine' => engine,
            'pulseWidth' => pulseWidth,
            _ => null,
          };

  /// Offers [count] samples, letting the operating point settle first.
  List<AutotuneOutcome> feed(
    VeAutotuner subject,
    AnalyzeSample reading, {
    int count = 1,
    Duration step = const Duration(milliseconds: 50),
  }) {
    // The first offer registers the cell; time then has to pass before the
    // settling filter will let anything through.
    subject.offer(reading, clock);
    clock = clock.add(subject.settings.settlingTime);

    final outcomes = <AutotuneOutcome>[];
    for (var i = 0; i < count; i++) {
      outcomes.add(subject.offer(reading, clock));
      clock = clock.add(step);
    }
    return outcomes;
  }

  group('readiness', () {
    test('refuses a narrowband sensor', () {
      final result = VeAutotuner.create(
        tune: buildTune(egoType: 1),
        permission: const WritePermission.granted(),
      );

      expect(result.tuner, isNull);
      expect(result.readiness.ready, isFalse);
      expect(result.readiness.reason, contains('wideband'));
      expect(result.readiness.reason, contains('Narrow Band'));
    });

    test('refuses a read-only session', () {
      final result = VeAutotuner.create(
        tune: tune,
        permission: const WritePermission.refused('Write mode is off.'),
      );

      expect(result.tuner, isNull);
      expect(result.readiness.reason, 'Write mode is off.');
    });

    test('is ready with a wideband and write permission', () {
      final result = VeAutotuner.create(
        tune: tune,
        permission: const WritePermission.granted(),
      );

      expect(result.readiness.ready, isTrue);
      expect(result.tuner, isNotNull);
    });
  });

  group('correction', () {
    test('a sample on target moves nothing', () {
      final subject = tuner();
      feed(subject, sample(), count: 50);

      expect(subject.acceptedSamples, greaterThan(40));
      expect(subject.movedCells, 0);
      expect(tune.isDirty, isFalse);
    });

    test('a lean sample raises the cell', () {
      final subject = tuner();
      // 15.4 against a 14.7 target is 4.8% lean, so the table is short of
      // fuel by that much.
      final outcomes = feed(subject, sample(afr: 15.4), count: 10);

      final accepted = outcomes.firstWhere((o) => o.accepted);
      expect(accepted.ratio, closeTo(15.4 / 14.7, 1e-9));
      expect(subject.movedCells, greaterThan(0));

      final cell = subject.cells.values.first;
      expect(cell.appliedPercent, greaterThan(0));
      expect(subject.table.valueAt(1, 1), greaterThan(50));
    });

    test('a rich sample lowers the cell', () {
      final subject = tuner();
      feed(subject, sample(afr: 13.5), count: 10);

      expect(subject.table.valueAt(1, 1), lessThan(50));
    });

    test('a closed-loop trim counts as the table being wrong', () {
      // The mixture reads on target only because the ECU is adding 5%. The
      // table under it is 5% low, and tuning has to see that rather than
      // conclude everything is fine.
      final subject = tuner();
      final outcomes = feed(subject, sample(ego: 105), count: 10);

      expect(outcomes.firstWhere((o) => o.accepted).ratio, closeTo(1.05, 1e-9));
      expect(subject.table.valueAt(1, 1), greaterThan(50));
    });

    test('interpolates the target across its own coarser axes', () {
      // The target table is 2x2 on different bins; make it a ramp so reading
      // it by cell index would give a visibly different answer.
      final afr = TableView.of(tune, definition.tableNamed('afrTable1Tbl')!)!;
      afr.setValueAt(0, 0, 13.0);
      afr.setValueAt(0, 1, 13.0);
      afr.setValueAt(1, 0, 15.0);
      afr.setValueAt(1, 1, 15.0);
      tune.markClean();

      final subject = tuner();
      // Load 50 sits exactly halfway between the target's 20 and 80 bins.
      final outcomes = feed(subject, sample(load: 50, afr: 14.0), count: 3);

      expect(outcomes.firstWhere((o) => o.accepted).ratio, closeTo(1.0, 1e-9));
    });
  });

  group('filters', () {
    test('a cold engine is rejected by name', () {
      final subject = tuner();
      final outcomes = feed(subject, sample(coolant: 40), count: 3);

      final rejected = outcomes.last;
      expect(rejected.accepted, isFalse);
      expect(rejected.rejectedBy?.id, 'minCltFilter');
      expect(rejected.description, contains('Minimum CLT'));
    });

    test('acceleration enrichment is rejected by its bit', () {
      final subject = tuner();
      final outcomes = feed(subject, sample(engine: 16), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'accelFilter');
    });

    test('an unrelated status bit does not reject', () {
      final subject = tuner();
      // Bit 1 is not the mask this filter tests.
      final outcomes = feed(subject, sample(engine: 2), count: 3);

      expect(outcomes.last.accepted, isTrue);
    });

    test('the overrun is rejected', () {
      final subject = tuner();
      final outcomes = feed(subject, sample(pulseWidth: 0), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'overrunFilter');
    });

    test('an operating point off the table is rejected', () {
      final subject = tuner();
      expect(feed(subject, sample(rpm: 100), count: 3).last.rejectedBy?.id,
          'std_xAxisMin');
      expect(feed(subject, sample(rpm: 9000), count: 3).last.rejectedBy?.id,
          'std_xAxisMax');
      expect(feed(subject, sample(load: 5), count: 3).last.rejectedBy?.id,
          'std_yAxisMin');
      expect(feed(subject, sample(load: 400), count: 3).last.rejectedBy?.id,
          'std_yAxisMax');
    });

    test('an implausible mixture reading is rejected', () {
      final subject = tuner();
      // A cold or disconnected sensor reports numbers that look like data.
      final outcomes = feed(subject, sample(afr: 4.0), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'std_DeadLambda');
      expect(outcomes.last.detail, contains('plausible'));
    });

    test('a custom filter is applied when one is set', () {
      final subject = tuner(
        settings: const AutotuneSettings(customFilter: 'rpm < 2000'),
      );
      final outcomes = feed(subject, sample(rpm: 1500), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'std_Custom');
      expect(feed(subject, sample(rpm: 2500), count: 3).last.accepted, isTrue);
    });

    test('a sample is refused until the operating point settles', () {
      final subject = tuner();

      expect(subject.offer(sample(), clock).rejectedBy?.id, 'std_Settling');
      clock = clock.add(const Duration(milliseconds: 200));
      expect(subject.offer(sample(), clock).rejectedBy?.id, 'std_Settling');

      clock = clock.add(const Duration(milliseconds: 400));
      expect(subject.offer(sample(), clock).accepted, isTrue);

      // Moving to another cell restarts the wait, because the reading still
      // describes exhaust from where the engine was.
      clock = clock.add(const Duration(milliseconds: 50));
      expect(subject.offer(sample(rpm: 2500), clock).rejectedBy?.id,
          'std_Settling');
    });
  });

  group('distribution', () {
    test('weights sum to one across the bracketing cells', () {
      final view = TableView.of(tune, definition.tableNamed('veTable1Tbl')!)!;
      final weights = view.weightsAt(2000, 50);

      expect(weights, hasLength(4));
      expect(weights.fold<double>(0, (a, w) => a + w.weight), closeTo(1, 1e-9));
      expect(
        weights.map((w) => (row: w.row, column: w.column)).toSet(),
        view
            .contributingCells(
              view.preciseCellFor(2000, 50)!.row,
              view.preciseCellFor(2000, 50)!.column,
            )
            .toSet(),
      );
    });

    test('a point between cells spreads its correction over all four', () {
      final subject = tuner();
      feed(subject, sample(rpm: 2000, load: 50, afr: 15.4), count: 40);

      expect(subject.cells, hasLength(4));
      for (final cell in subject.cells.values) {
        expect(cell.appliedPercent, greaterThan(0));
      }
    });

    test('a point on a bin credits only that cell', () {
      final subject = tuner();
      feed(subject, sample(rpm: 1500, load: 40, afr: 15.4), count: 10);

      expect(subject.cells, hasLength(1));
    });
  });

  group('limits', () {
    test('no cell moves before it has enough evidence', () {
      final subject = tuner(settings: const AutotuneSettings(minWeight: 20));
      feed(subject, sample(afr: 15.4), count: 5);

      expect(subject.movedCells, 0);
      expect(subject.cells.values.first.weight, greaterThan(0));
    });

    test('a single application is capped', () {
      final subject = tuner(
        settings: const AutotuneSettings(minWeight: 1, maxStepPercent: 2),
      );
      // 30% lean, which wants far more than one step allows.
      feed(subject, sample(afr: 19.1), count: 1);

      expect(subject.cells.values.first.appliedPercent, closeTo(2, 1e-9));
      expect(subject.table.valueAt(1, 1), closeTo(51, 1e-9));
    });

    test('the session total is capped however long it runs', () {
      final subject = tuner(
        settings: const AutotuneSettings(
          minWeight: 1,
          maxStepPercent: 2,
          maxTotalPercent: 10,
        ),
      );
      feed(subject, sample(afr: 19.1), count: 1000);

      expect(subject.cells.values.first.appliedPercent, closeTo(10, 1e-9));
      expect(subject.table.valueAt(1, 1), closeTo(55, 1e-9));
    });
  });

  group('convergence', () {
    test('a table that is 20% low is brought to target and held there', () {
      // The closed loop that matters: fuelling actually responds to what the
      // tuner writes, so a sign error shows up as divergence rather than as a
      // number that merely looks plausible.
      const requiredVe = 60.0;
      final subject = tuner(settings: const AutotuneSettings(minWeight: 2));
      final view = subject.table;

      for (var i = 0; i < 400; i++) {
        final current = view.valueAt(1, 1)!;
        final measured = 14.7 * requiredVe / current;
        subject.offer(sample(afr: measured), clock);
        clock = clock.add(const Duration(milliseconds: 50));
      }

      expect(view.valueAt(1, 1), closeTo(requiredVe, view.zStep));

      // And it stays there rather than hunting past it.
      for (var i = 0; i < 200; i++) {
        final current = view.valueAt(1, 1)!;
        subject.offer(sample(afr: 14.7 * requiredVe / current), clock);
        clock = clock.add(const Duration(milliseconds: 50));
      }
      expect(view.valueAt(1, 1), closeTo(requiredVe, view.zStep));
    });
  });

  group('session', () {
    test('reset discards what was gathered', () {
      final subject = tuner();
      feed(subject, sample(afr: 15.4), count: 20);
      expect(subject.cells, isNotEmpty);

      subject.reset();

      expect(subject.cells, isEmpty);
      expect(subject.acceptedSamples, 0);
      expect(subject.rejectedSamples, 0);
    });
  });
}
