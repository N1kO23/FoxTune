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

/// Replaying recorded logs into the autotuner, end to end.
///
/// Each log is recorded as FoxTune records one: the tune-driven engine is
/// encoded into the simulated ECU's realtime block, decoded by the real
/// decoder and written by the real `.msl` writer. Nothing feeds back while
/// recording - it is a log of an engine running the tune it had - so a replay
/// has to find the whole error in it at once.
void main() {
  String fixture(String name) {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/$name'),
      File('../foxtune_ini/test/fixtures/$name'),
    ];
    return candidates.firstWhere((f) => f.existsSync()).readAsStringSync();
  }

  EngineConditions at({
    required double seconds,
    required double rpm,
    required double map,
    double coolant = 85,
  }) =>
      EngineConditions(
        seconds: seconds,
        phase: 0.5,
        throttle: 30,
        throttleRate: 0,
        rpm: rpm,
        map: map,
        coolant: coolant,
        iat: 30,
        battery: 13.8,
        cranking: false,
        overrun: false,
      );

  /// Records the engine held at each of [points] in turn.
  String record(
    IniDocument doc,
    FakeTsEcu ecu,
    TunedEngineSimulation engine,
    List<({double rpm, double map})> points, {
    double secondsEach = 20,
    double step = 0.05,
  }) {
    final decoder = RealtimeDecoder(
      doc.outputChannels,
      constantResolver: engine.resolve,
    );
    RealtimeSnapshot sample(double t, ({double rpm, double map}) point) {
      ecu.writeEngineSample(
        engine,
        at(seconds: 100 + t, rpm: point.rpm, map: point.map),
      );
      return decoder.decode(Uint8List.fromList(ecu.realtime));
    }

    final writer = MslLogWriter.forDefinition(
      doc,
      probe: sample(0, points.first),
      constantResolver: engine.resolve,
    );
    final log = StringBuffer(writer.header());
    var t = 0.0;
    for (final point in points) {
      for (var held = 0.0; held < secondsEach; held += step) {
        log.write(writer.row(
          sample(t, point),
          Duration(microseconds: (t * 1e6).round()),
        ));
        t += step;
      }
    }
    return log.toString();
  }

  /// Drops the column headed [label] from every line of [log].
  String withoutColumn(String log, String label) {
    final lines = log.split('\n');
    final index = lines[2].split('\t').indexOf(label);
    expect(index, isNonNegative, reason: 'no "$label" column');
    return [
      for (final (i, line) in lines.indexed)
        i < 2 || line.isEmpty
            ? line
            : ([...line.split('\t')]..removeAt(index)).join('\t'),
    ].join('\n');
  }

  group('Speeduino', () {
    late IniDocument doc;

    setUpAll(() {
      doc = IniParser(defined: {'CELSIUS'}).parse(fixture('speeduino.ini'));
    });

    void setOption(List<Uint8List> pages, String name, String label) {
      final tune = TuneState.fromPages(doc, pages);
      final setting = SettingView.of(tune, name)!;
      final index = setting.options
          .indexWhere((o) => o.toLowerCase().contains(label.toLowerCase()));
      expect(index, isNonNegative, reason: '$name has no "$label"');
      setting.setOptionIndex(index);
      for (var page = 1; page <= pages.length; page++) {
        pages[page - 1].setAll(0, tune.page(page));
      }
    }

    ({FakeSpeeduino ecu, TunedEngineSimulation engine}) rig({
      double veError = 0,
      bool closedLoop = false,
    }) {
      late final TunedEngineSimulation engine;
      final ecu = FakeSpeeduino(
        pageSizes: doc.constants.pageSizes,
        realtimeBlockSize: doc.outputChannels.blockSize!,
        channels: doc.outputChannels,
        constantResolver: (name) => engine.resolve(name),
      );
      for (final page in ecu.pages) {
        page.fillRange(0, page.length, 0);
      }
      engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
        ..seedTune(errorPercent: veError);
      if (!closedLoop) setOption(ecu.pages, 'egoAlgorithm', 'no correct');
      return (ecu: ecu, engine: engine);
    }

    TableView veOf(TuneState tune) =>
        TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

    /// Two operating points on the table's own bins, one cell each.
    List<({double rpm, double map})> pointsOn(TableView ve) => [
          (rpm: ve.xAt(6)!, map: ve.yAt(9)!),
          (rpm: ve.xAt(3)!, map: ve.yAt(4)!),
        ];

    void expectTuned(
      TableView ve,
      List<({double rpm, double map})> points, {
      double within = 0.03,
    }) {
      for (final point in points) {
        final cell = ve.cellFor(point.rpm, point.map)!;
        final truth =
            TunedEngineSimulation.defaultAirflow(point.rpm, point.map);
        expect(
            ve.valueAt(cell.row, cell.column), closeTo(truth, truth * within),
            reason: 'at ${point.rpm} rpm, ${point.map} kPa');
      }
    }

    test('one replay brings a low table up to the engine', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final points = pointsOn(veOf(tune));
      final log = MslLog.parse(record(doc, r.ecu, r.engine, points));

      final result = LogReplay.analyse(tune: tune, log: log);

      expect(result.blockedReason, isNull);
      expect(result.changes, hasLength(2));
      for (final percent in result.changes.values) {
        expect(percent, closeTo(100 / 90 * 100 - 100, 2));
      }
      expect(LogReplay.applyTo(tune, result), isTrue);
      expectTuned(veOf(tune), points);
    });

    test('one replay brings a high table down to the engine', () {
      final r = rig(veError: 12);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final points = pointsOn(veOf(tune));
      final log = MslLog.parse(record(doc, r.ecu, r.engine, points));

      final result = LogReplay.analyse(tune: tune, log: log);
      LogReplay.applyTo(tune, result);

      expectTuned(veOf(tune), points);
    });

    test('sees through the closed loop rather than tuning against it', () {
      final r = rig(veError: -10, closedLoop: true);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final points = pointsOn(veOf(tune));
      final log = MslLog.parse(
        record(doc, r.ecu, r.engine, points, secondsEach: 60),
      );

      final result = LogReplay.analyse(tune: tune, log: log);
      LogReplay.applyTo(tune, result);

      expectTuned(veOf(tune), points, within: 0.05);
    });

    test('a scripted drive brings every cell it reaches closer', () {
      // Idle, a pull to redline, a cruise and an overrun, over and over: a
      // log of transients, cold running and fuel cut as much as of steady
      // state, which the filters and settling have to sort out.
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final decoder = RealtimeDecoder(
        doc.outputChannels,
        constantResolver: r.engine.resolve,
      );
      RealtimeSnapshot sample(double t) {
        r.ecu.writeEngineSample(r.engine, r.engine.conditionsAt(t));
        return decoder.decode(Uint8List.fromList(r.ecu.realtime));
      }

      final writer = MslLogWriter.forDefinition(
        doc,
        probe: sample(0),
        constantResolver: r.engine.resolve,
      );
      final text = StringBuffer(writer.header());
      for (var t = 0.0; t < 600; t += 0.05) {
        text.write(
          writer.row(sample(t), Duration(microseconds: (t * 1e6).round())),
        );
      }

      final result = LogReplay.analyse(
        tune: tune,
        log: MslLog.parse(text.toString()),
      );

      expect(result.changes.length, greaterThan(10));
      final before = veOf(tune);
      final after = veOf(result.preview!);
      for (final cell in result.changes.keys) {
        final truth = TunedEngineSimulation.defaultAirflow(
          before.xAt(cell.column)!,
          before.yAt(cell.row)!,
        );
        final was = before.valueAt(cell.row, cell.column)! / truth - 1;
        final now = after.valueAt(cell.row, cell.column)! / truth - 1;
        expect(now.abs(), lessThan(was.abs()), reason: '$cell');
        expect(now.abs(), lessThan(0.05), reason: '$cell');
      }
    });

    test('changes nothing until applied', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final before = veOf(tune).toGrid();
      final log =
          MslLog.parse(record(doc, r.ecu, r.engine, pointsOn(veOf(tune))));

      final result = LogReplay.analyse(tune: tune, log: log);

      expect(result.changes, isNotEmpty);
      expect(veOf(tune).toGrid(), before);
      expect(tune.isDirty, isFalse);
      expect(veOf(result.preview!).changesAgainst(veOf(tune)).keys.toSet(),
          result.changes.keys.toSet());
    });

    test('accounts for every row, used or skipped by why', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final log =
          MslLog.parse(record(doc, r.ecu, r.engine, pointsOn(veOf(tune))));

      final result = LogReplay.analyse(tune: tune, log: log);

      expect(result.rows, log.rowCount);
      expect(result.used + result.skipped.values.fold(0, (a, b) => a + b),
          result.rows);
      // Each point is arrived at once, and waited out.
      expect(result.skipped['Settling'], greaterThan(0));
      // Recorded with this very table: VE1 is a whole number, and the
      // tolerance has to allow for it.
      expect(result.skipped, isNot(contains('Table since changed')));
      // Counted under names fit to show, not the definition's identifiers.
      expect(result.skipped.keys.where((k) => k.startsWith('std_')), isEmpty);
    });

    test('names why rows were skipped in words', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final ve = veOf(tune);
      // Below the lowest RPM bin, where the definition's std_xAxisMin filter
      // has no label of its own.
      final below = (rpm: ve.xAt(0)! - 100, map: ve.yAt(4)!);
      final log = MslLog.parse(
        record(doc, r.ecu, r.engine, [below], secondsEach: 5),
      );

      final result = LogReplay.analyse(tune: tune, log: log);

      expect(result.skipped['Off the table'], greaterThan(0));
      expect(result.skipped.keys.where((k) => k.startsWith('std_')), isEmpty);
    });

    test('replaying the same log twice corrects nothing the second time', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final points = pointsOn(veOf(tune));
      final log = MslLog.parse(record(doc, r.ecu, r.engine, points));

      LogReplay.applyTo(tune, LogReplay.analyse(tune: tune, log: log));
      final tuned = veOf(tune).toGrid();

      final again = LogReplay.analyse(tune: tune, log: log);

      expect(again.changes, isEmpty);
      expect(again.skipped['Table since changed'], greaterThan(0));
      LogReplay.applyTo(tune, again);
      expect(veOf(tune).toGrid(), tuned);
    });

    test('skips only the part of a log whose table has changed since', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final ve = veOf(tune);
      final points = pointsOn(ve);
      final log = MslLog.parse(record(doc, r.ecu, r.engine, points));

      // Hand-edit the first point's cell after the log was recorded.
      final edited = ve.cellFor(points.first.rpm, points.first.map)!;
      ve.setValueAt(
        edited.row,
        edited.column,
        ve.valueAt(edited.row, edited.column)! + 5,
      );

      final result = LogReplay.analyse(tune: tune, log: log);

      expect(result.changes.keys, isNot(contains(edited)));
      expect(result.changes.keys,
          contains(ve.cellFor(points.last.rpm, points.last.map)));
      expect(result.skipped['Table since changed'], greaterThan(0));
    });

    test('refuses to apply over a cell edited after the analysis', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final ve = veOf(tune);
      final log = MslLog.parse(record(doc, r.ecu, r.engine, pointsOn(ve)));

      final result = LogReplay.analyse(tune: tune, log: log);
      final cell = result.changes.keys.first;
      ve.setValueAt(cell.row, cell.column, 40);
      final before = ve.toGrid();

      expect(LogReplay.applyTo(tune, result), isFalse);
      expect(ve.toGrid(), before);
    });

    test('a break in the log is waited out again', () {
      final r = rig(veError: -10);
      final tune = TuneState.fromPages(doc, r.ecu.pages);
      final ve = veOf(tune);
      final text = record(doc, r.ecu, r.engine, [pointsOn(ve).first]);
      final lines = text.split('\n');

      // The same rows with the clock jumping ten minutes half-way through,
      // as though logging had been paused.
      final half = 4 + (lines.length - 4) ~/ 2;
      final gapped = [
        for (final (i, line) in lines.indexed)
          if (i < half || line.isEmpty)
            line
          else
            line.replaceFirstMapped(RegExp(r'^[\d.]+'),
                (m) => (double.parse(m[0]!) + 600).toStringAsFixed(3)),
      ].join('\n');

      final steady = LogReplay.analyse(tune: tune, log: MslLog.parse(text));
      final broken = LogReplay.analyse(tune: tune, log: MslLog.parse(gapped));

      expect(
          broken.skipped['Settling'], greaterThan(steady.skipped['Settling']!));
    });

    group('refuses', () {
      late ({FakeSpeeduino ecu, TunedEngineSimulation engine}) r;
      late TuneState tune;
      late String text;

      setUp(() {
        r = rig(veError: -10);
        tune = TuneState.fromPages(doc, r.ecu.pages);
        text =
            record(doc, r.ecu, r.engine, pointsOn(veOf(tune)), secondsEach: 2);
      });

      test('a log without a time column', () {
        final result = LogReplay.analyse(
          tune: tune,
          log: MslLog.parse(withoutColumn(text, 'Time')),
        );
        expect(result.blockedReason, contains('Time'));
        expect(result.preview, isNull);
      });

      test('a log that does not say which VE the ECU ran', () {
        final result = LogReplay.analyse(
          tune: tune,
          log: MslLog.parse(withoutColumn(text, 'VE1')),
        );
        expect(result.blockedReason, contains('VE1'));
      });

      test('a log without the mixture reading', () {
        final result = LogReplay.analyse(
          tune: tune,
          log: MslLog.parse(withoutColumn(text, 'AFR')),
        );
        expect(result.blockedReason, contains('"afr"'));
      });

      test('a log in another temperature scale', () {
        final fahrenheit = IniParser().parse(fixture('speeduino.ini'));
        final result = LogReplay.analyse(
          tune: TuneState.fromPages(fahrenheit, r.ecu.pages),
          log: MslLog.parse(text),
        );
        expect(result.blockedReason, contains('Celsius'));
        expect(result.blockedReason, contains('Fahrenheit'));
      });

      test('a tune autotuning refuses, for the same reason', () {
        setOption(r.ecu.pages, 'egoType', 'narrow');
        final result = LogReplay.analyse(
          tune: TuneState.fromPages(doc, r.ecu.pages),
          log: MslLog.parse(text),
        );
        expect(result.blockedReason, contains('wideband'));
      });
    });
  });

  group('rusEFI', () {
    late IniDocument doc;

    setUpAll(() => doc = IniParser().parse(fixture('rusefi_uaefi.ini')));

    void setOption(List<Uint8List> pages, String name, String label) {
      final tune = TuneState.fromPages(doc, pages);
      final setting = SettingView.of(tune, name)!;
      setting.setOptionIndex(setting.options.indexOf(label));
      for (var page = 1; page <= pages.length; page++) {
        pages[page - 1].setAll(0, tune.page(page));
      }
    }

    for (final lambda in [false, true]) {
      test('one replay brings a low table up, in ${lambda ? 'lambda' : 'AFR'}',
          () {
        late final TunedEngineSimulation engine;
        final ecu = FakeRusEfi.fromDefinition(
          doc,
          constantResolver: (name) => engine.resolve(name),
        );
        for (final page in ecu.pages) {
          page.fillRange(0, page.length, 0);
        }
        setOption(ecu.pages, 'useLambdaOnInterface', lambda ? 'Lambda' : 'AFR');
        engine = TunedEngineSimulation(definition: doc, pages: ecu.pages)
          ..seedTune(errorPercent: -10);
        setOption(ecu.pages, 'fuelClosedLoopCorrectionEnabled', 'disabled');

        final tune = TuneState.fromPages(doc, ecu.pages);
        final ve = TableView.of(tune, doc.tableNamed('veTableTbl')!)!;
        final point = (rpm: ve.xAt(6)!, map: ve.yAt(9)!);
        final log = MslLog.parse(record(doc, ecu, engine, [point]));

        final result = LogReplay.analyse(tune: tune, log: log);

        expect(result.blockedReason, isNull);
        expect(result.skipped, isNot(contains('Table since changed')));
        expect(LogReplay.applyTo(tune, result), isTrue);
        final cell = ve.cellFor(point.rpm, point.map)!;
        final truth =
            TunedEngineSimulation.defaultAirflow(point.rpm, point.map);
        expect(ve.valueAt(cell.row, cell.column), closeTo(truth, truth * 0.03));
      });
    }
  });
}
