import 'package:foxtune_ini/foxtune_ini.dart';

import '../msl_reader.dart';
import '../table_view.dart';
import '../temperature_scale.dart';
import '../tune_state.dart';
import '../write_guard.dart';
import 'autotune_settings.dart';
import 've_autotuner.dart';

/// What replaying a log found, and what it would do to the VE table.
class LogReplayResult {
  const LogReplayResult._({
    required this.rows,
    this.blockedReason,
    this.preview,
    this.changes = const {},
    this.coverage = const {},
    this.used = 0,
    this.skipped = const {},
    Map<({int row, int column}), double> original = const {},
  }) : _original = original;

  const LogReplayResult._blocked(String reason, {required int rows})
      : this._(rows: rows, blockedReason: reason);

  /// Rows of data in the log.
  final int rows;

  /// Why the log cannot be replayed at all, or `null`.
  final String? blockedReason;

  /// A copy of the tune with the corrections made, for showing before they
  /// are applied; `null` when blocked.
  final TuneState? preview;

  /// Cells the replay would change, each with its correction as a percentage
  /// of its value.
  final Map<({int row, int column}), double> changes;

  /// Evidence gathered, by cell: where the log had data.
  final Map<({int row, int column}), AutotuneCell> coverage;

  /// Rows that counted towards a correction.
  final int used;

  /// Rows passed over, counted by why.
  final Map<String, int> skipped;

  /// Each changed cell's value when analysed.
  final Map<({int row, int column}), double> _original;

  bool get blocked => blockedReason != null;
}

/// Replays a recorded log into the VE autotuner.
///
/// A log is worked through as a live session would be - the same filters, the
/// same settling - but each cell is corrected once from all of its evidence,
/// because every row describes the table the log was recorded with: see
/// [AutotuneMode.replay]. That happens on a copy of the tune; the tune itself
/// changes only through [applyTo].
abstract final class LogReplay {
  /// Replays [log] against [tune], without changing [tune].
  static LogReplayResult analyse({
    required TuneState tune,
    required MslLog log,
    AutotuneSettings settings = const AutotuneSettings(),
  }) {
    LogReplayResult blocked(String reason) =>
        LogReplayResult._blocked(reason, rows: log.rowCount);

    final preview = tune.copy();
    final created = VeAutotuner.create(
      tune: preview,
      // The copy cannot reach the tune it was taken from, let alone an ECU:
      // that is what [applyTo] is for, and its caller holds the real gate.
      permission: const WritePermission.granted(),
      settings: settings,
      mode: AutotuneMode.replay,
    );
    final tuner = created.tuner;
    if (tuner == null) {
      return blocked(
        created.readiness.reason ?? 'This tune cannot be autotuned.',
      );
    }

    final channels = MslChannels(
      log,
      tune.definition,
      constantResolver: tuner.resolver.resolve,
    );

    final time = channels.columns['time'] ?? log.indexOf('Time');
    if (time == null) {
      return blocked(
        'This log has no Time column. Without one there is no telling whether '
        'the engine held still long enough for a reading to count.',
      );
    }

    if (!VeAutotuner.runningVeChannels.any(channels.columns.containsKey)) {
      return blocked(
        'This log did not record the VE the ECU was running '
        '(${VeAutotuner.runningVeChannels.join(' or ')}), so there is no '
        'telling whether it was recorded with the table loaded now. A log '
        'recorded with another table would correct cells a second time.',
      );
    }

    final scale = _temperatureMismatch(channels);
    if (scale != null) return blocked(scale);

    final config = tuner.config;
    final axes = [
      tuner.table.table.xBins.channel,
      tuner.table.table.yBins.channel,
    ].whereType<String>();
    channels.prepare([
      ...axes,
      ...[
        tuner.target.table.xBins.channel,
        tuner.target.table.yBins.channel,
      ].whereType<String>(),
      config.measuredChannel,
      config.egoCorrectionChannel,
      for (final filter in config.channelFilters) filter.channel,
      ...VeAutotuner.runningVeChannels,
    ]);

    for (final channel in {...axes, config.measuredChannel}) {
      if (!_everRead(channels, channel)) {
        return blocked(
          'No row of this log has a reading of "$channel", which autotuning '
          'needs.',
        );
      }
    }

    // Seconds since the log began, on a clock of its own: only differences
    // between rows mean anything.
    final epoch = DateTime.utc(2000);
    final settling = settings.settlingTime.inMicroseconds / 1e6;
    final gap = settling * 2 > 1 ? settling * 2 : 1.0;

    final skipped = <String, int>{};
    void skip(String reason) => skipped[reason] = (skipped[reason] ?? 0) + 1;

    double? previous;
    for (var row = 0; row < log.rowCount; row++) {
      final seconds = log.valueAt(row, time);
      if (seconds == null) {
        skip('No time');
        continue;
      }
      // Across a break the engine may have been anywhere, so it has to be
      // seen to settle again.
      if (previous != null &&
          (seconds < previous || seconds - previous > gap)) {
        tuner.interrupt();
      }
      previous = seconds;

      final outcome = tuner.offer(
        channels.row(row),
        epoch.add(Duration(microseconds: (seconds * 1e6).round())),
      );
      if (!outcome.accepted) skip(_reasonFor(outcome));
    }

    final moved = tuner.applyGathered();
    final cells = tuner.cells;
    return LogReplayResult._(
      rows: log.rowCount,
      preview: preview,
      changes: {for (final cell in moved) cell: cells[cell]!.appliedPercent},
      original: {for (final cell in moved) cell: cells[cell]!.baseline},
      coverage: cells,
      used: tuner.acceptedSamples,
      skipped: skipped,
    );
  }

  /// Writes [result]'s corrections into [target], the tune it was analysed
  /// from.
  ///
  /// Returns `false`, changing nothing, when one of those cells has changed
  /// since: its correction was worked out against the value it had then.
  static bool applyTo(TuneState target, LogReplayResult result) {
    final preview = result.preview;
    final name = target.definition.veAnalyze?.table;
    final table = name == null ? null : target.definition.tableNamed(name);
    if (preview == null || table == null) return false;

    final to = TableView.of(target, table);
    final from = TableView.of(preview, table);
    if (to == null || from == null) return false;

    for (final cell in result.changes.keys) {
      if (to.valueAt(cell.row, cell.column) != result._original[cell]) {
        return false;
      }
    }
    for (final cell in result.changes.keys) {
      to.setValueAt(
        cell.row,
        cell.column,
        from.valueAt(cell.row, cell.column)!,
      );
    }
    return true;
  }

  /// Why a row was passed over, as a heading rows are counted under.
  ///
  /// By filter rather than by the outcome's own detail, which carries the
  /// reading - "Below the table at 480 rpm" - and would count every row
  /// apart. The definition leaves its standard filters unlabelled, so those
  /// are named here.
  static String _reasonFor(AutotuneOutcome outcome) {
    final filter = outcome.rejectedBy;
    if (filter == null) return outcome.detail ?? 'Unusable';
    if (filter.label.isNotEmpty) return filter.label;
    return switch (filter.id) {
      'std_xAxisMin' ||
      'std_xAxisMax' ||
      'std_yAxisMin' ||
      'std_yAxisMax' =>
        'Off the table',
      'std_DeadLambda' => VeAutotuner.deadSensorFilter.label,
      'std_Custom' => 'Custom filter',
      _ => filter.displayLabel,
    };
  }

  static bool _everRead(MslChannels channels, String channel) {
    for (var row = 0; row < channels.log.rowCount; row++) {
      if (channels.row(row)(channel) != null) return true;
    }
    return false;
  }

  /// Why the log's temperatures cannot be compared with the definition's
  /// filters, or `null` when they can.
  ///
  /// Speeduino's definition computes coolant in whichever scale it was read
  /// in, and its minimum-coolant filter is in that scale too. A log recorded
  /// in the other one would be judged against the wrong number: 100 °F is a
  /// cold engine, and passes a 71 °C minimum.
  static String? _temperatureMismatch(MslChannels channels) {
    for (final channel in channels.columns.keys) {
      final logged = TemperatureScale.of(channels.unitsOf(channel));
      if (logged == null) continue;
      final expected =
          TemperatureScale.of(_unitsOf(channels.definition, channel));
      if (expected == null || expected == logged) continue;

      String name(TemperatureScale scale) =>
          scale == TemperatureScale.celsius ? 'Celsius' : 'Fahrenheit';
      return 'This log records temperatures in ${name(logged)}, but the '
          'definition is being read in ${name(expected)}, so its temperature '
          'filters would be judged in the wrong scale. Switch the temperature '
          'scale to ${name(logged)} to replay it.';
    }
    return null;
  }

  static String _unitsOf(IniDocument definition, String channel) {
    final field = definition.outputChannels.channelNamed(channel);
    if (field is IniScalarField && field.units.isNotEmpty) return field.units;
    final computed = definition.outputChannels.computedNamed(channel)?.units;
    if (computed != null && computed.isNotEmpty) return computed;
    return definition.gaugeForChannel(channel)?.units ?? '';
  }
}
