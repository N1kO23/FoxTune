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
[OutputChannels]
  ochGetCommand = "r"
  ochBlockSize  = 1
  VE1      = scalar, U08, 0, "%", 1.0, 0.0
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
  ///
  /// The ECU reports running whatever the table holds at the operating point
  /// when the sample is read - as it does once a correction is burned or sent
  /// to it - unless [ve] says otherwise.
  AnalyzeSample sample({
    double rpm = 1500,
    double load = 40,
    double afr = 14.7,
    double ego = 100,
    double coolant = 85,
    double engine = 0,
    double pulseWidth = 3,
    double? ve,
  }) =>
      (channel) => switch (channel) {
            'rpm' => rpm,
            'fuelLoad' => load,
            'afr' => afr,
            'egoCorrection' => ego,
            'coolant' => coolant,
            'engine' => engine,
            'pulseWidth' => pulseWidth,
            'VE1' => ve ??
                TableView.of(tune, tune.definition.tableNamed('veTable1Tbl')!)!
                    .interpolatedAt(rpm, load),
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

    test('refuses firmware that does not say what VE it is running', () {
      // Without it there is no telling when a correction has reached the
      // engine, and every sample until then would ask for it again.
      final silent = IniParser().parse(_source.replaceFirst(
        '  VE1      = scalar, U08, 0, "%", 1.0, 0.0\n',
        '',
      ));
      final result = VeAutotuner.create(
        tune: TuneState.fromPages(silent, [tune.page(1)]),
        permission: const WritePermission.granted(),
      );

      expect(result.tuner, isNull);
      expect(result.readiness.reason, contains('VE1'));
    });

    test('refuses a filter it could not read', () {
      // Without an operator the filter would never reject anything: a guard
      // the definition asked for, silently gone.
      final unreadable = IniParser().parse(_source.replaceFirst(
        'filter = minCltFilter,  "Minimum CLT", coolant,    <, 71, , true',
        'filter = minCltFilter,  "Minimum CLT", coolant ~ 71, , true',
      ));
      final state = TuneState.fromPages(unreadable, [tune.page(1)]);
      final result = VeAutotuner.create(
        tune: state,
        permission: const WritePermission.granted(),
      );

      expect(result.tuner, isNull);
      expect(result.readiness.reason, contains('"Minimum CLT"'));
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

  group('an ECU that has not caught up', () {
    test('a corrected cell waits until the ECU runs the correction', () {
      final subject = tuner(
        settings: const AutotuneSettings(
          minWeight: 1,
          maxStepPercent: 2,
          maxTotalPercent: 10,
        ),
      );
      // 30% lean, and the ECU still running the 50 it started with: nothing
      // burned, nothing sent.
      final outcomes = feed(subject, sample(afr: 19.1, ve: 50), count: 100);

      // Two steps: the first leaves the table within a storage step of what
      // the ECU runs, which Speeduino's whole-number VE cannot tell apart.
      expect(subject.cells.values.first.appliedPercent, closeTo(4, 1e-9));
      expect(outcomes.last.rejectedBy?.id, 'std_RunningVe');
      expect(outcomes.last.description, contains('still running'));
    });

    test('carries on once the ECU runs it', () {
      final subject = tuner(
        settings: const AutotuneSettings(
          minWeight: 1,
          maxStepPercent: 2,
          maxTotalPercent: 10,
        ),
      );
      feed(subject, sample(afr: 19.1, ve: 50), count: 20);
      expect(subject.cells.values.first.appliedPercent, closeTo(4, 1e-9));

      // Burned, or sent: the ECU now reports what the table holds.
      feed(subject, sample(afr: 19.1), count: 20);
      expect(subject.cells.values.first.appliedPercent, closeTo(10, 1e-9));
    });

    test('a sample that does not say what the ECU ran is not used', () {
      final subject = tuner();
      final quiet = sample();
      final outcomes = feed(
        subject,
        (channel) => channel == 'VE1' ? null : quiet(channel),
        count: 3,
      );

      expect(outcomes.last.rejectedBy?.id, 'std_RunningVe');
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

  group('replay', () {
    VeAutotuner replayer({
      AutotuneSettings settings = const AutotuneSettings(),
    }) =>
        VeAutotuner.create(
          tune: tune,
          permission: const WritePermission.granted(),
          settings: settings,
          mode: AutotuneMode.replay,
        ).tuner!;

    /// A logged row: [sample] plus the VE the ECU looked up there.
    AnalyzeSample logged(AnalyzeSample row, {double? ve = 50}) =>
        (channel) => channel == 'VE1' ? ve : row(channel);

    test('gathers without moving anything', () {
      final subject = replayer(settings: const AutotuneSettings(minWeight: 1));
      final outcomes = feed(subject, logged(sample(afr: 15.4)), count: 20);

      expect(outcomes.where((o) => o.accepted), hasLength(20));
      expect(outcomes.expand((o) => o.moved), isEmpty);
      expect(subject.table.valueAt(1, 1), 50);
      expect(tune.isDirty, isFalse);
    });

    test('corrects each cell once, by the mean of its evidence', () {
      final subject = replayer(settings: const AutotuneSettings(minWeight: 1));
      // Half the rows 10% lean, half on target: 5% short of fuel on average.
      // The second batch's settling offer counts too, as the operating point
      // has not moved, so it is one shorter.
      feed(subject, logged(sample(afr: 14.7 * 1.1)), count: 10);
      feed(subject, logged(sample()), count: 9);
      expect(subject.acceptedSamples, 20);

      final moved = subject.applyGathered();

      expect(moved, [(row: 1, column: 1)]);
      expect(
          subject.cells[(row: 1, column: 1)]!.appliedPercent, closeTo(5, 1e-9));
      expect(subject.table.valueAt(1, 1), closeTo(52.5, subject.table.zStep));
    });

    test('is bounded by the session limit, not the step limit', () {
      final subject = replayer(
        settings: const AutotuneSettings(
          minWeight: 1,
          maxStepPercent: 2,
          maxTotalPercent: 10,
        ),
      );
      feed(subject, logged(sample(afr: 14.7 * 1.06)), count: 10);
      subject.applyGathered();
      // One step would have been 2%; the whole log asks for 6%.
      expect(subject.cells.values.first.appliedPercent, closeTo(6, 1e-9));
    });

    test('is still bounded by the session limit', () {
      final subject = replayer(
        settings: const AutotuneSettings(minWeight: 1, maxTotalPercent: 10),
      );
      // 30% lean.
      feed(subject, logged(sample(afr: 19.1)), count: 10);
      subject.applyGathered();

      expect(subject.cells.values.first.appliedPercent, closeTo(10, 1e-9));
    });

    test('a second pass over the same rows changes nothing', () {
      final subject = replayer(settings: const AutotuneSettings(minWeight: 1));
      final row = logged(sample(afr: 14.7 * 1.06));
      feed(subject, row, count: 10);
      expect(subject.applyGathered(), isNotEmpty);

      // The same log again: its rows still say the ECU ran 50, where the
      // table now holds 53.
      final again = replayer(settings: const AutotuneSettings(minWeight: 1));
      final outcomes = feed(again, row, count: 10);

      expect(
          outcomes.every((o) => o.rejectedBy?.id == 'std_RunningVe'), isTrue);
      expect(again.applyGathered(), isEmpty);
    });

    test('leaves a cell with too little evidence alone', () {
      final subject = replayer(settings: const AutotuneSettings(minWeight: 20));
      feed(subject, logged(sample(afr: 15.4)), count: 5);

      expect(subject.applyGathered(), isEmpty);
      expect(subject.table.valueAt(1, 1), 50);
    });

    test('rejects a row recorded with a different table, by name', () {
      final subject = replayer();
      // The ECU ran 45 here, but the table now holds 50: this row describes
      // fuelling the table no longer gives.
      final outcomes = feed(subject, logged(sample(), ve: 45), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'std_RunningVe');
      expect(outcomes.last.description, contains('45'));
    });

    test('accepts a row a storage step out, as integer lookups are', () {
      final subject = replayer();
      expect(feed(subject, logged(sample(), ve: 49), count: 3).last.accepted,
          isTrue);
    });

    test('rejects a row with no recorded VE', () {
      final subject = replayer();
      final outcomes = feed(subject, logged(sample(), ve: null), count: 3);

      expect(outcomes.last.rejectedBy?.id, 'std_RunningVe');
    });

    test('the live mode does not ask for a recorded VE', () {
      final subject = tuner();
      expect(feed(subject, sample(), count: 3).last.accepted, isTrue);
    });

    test('an interruption restarts settling', () {
      final subject = replayer();
      feed(subject, logged(sample()), count: 3);

      subject.interrupt();
      expect(subject.offer(logged(sample()), clock).rejectedBy?.id,
          'std_Settling');
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
