import 'package:foxtune_ini/foxtune_ini.dart';

import '../table_view.dart';
import '../tune_state.dart';
import '../value_resolver.dart';
import '../write_guard.dart';
import 'autotune_settings.dart';
import 'mixture_units.dart';
import 'readiness_checks.dart';

/// Reads one channel of a sample, in engineering units.
///
/// Deliberately not a `RealtimeSnapshot`: the same analyser has to serve the
/// live feed and, later, a row of a recorded log.
typedef AnalyzeSample = double? Function(String channel);

/// What happened to one offered sample.
class AutotuneOutcome {
  const AutotuneOutcome._({
    required this.accepted,
    this.rejectedBy,
    this.detail,
    this.ratio,
    this.moved = const [],
  });

  const AutotuneOutcome.rejected(IniAnalyzeFilter filter, {String? detail})
      : this._(accepted: false, rejectedBy: filter, detail: detail);

  const AutotuneOutcome.unusable(String detail)
      : this._(accepted: false, detail: detail);

  const AutotuneOutcome.accepted({
    required double ratio,
    List<({int row, int column})> moved = const [],
  }) : this._(accepted: true, ratio: ratio, moved: moved);

  /// Whether the sample contributed to the correction.
  final bool accepted;

  /// The filter that rejected it, where a filter did.
  ///
  /// Named rather than counted, because "why is it not collecting data" is the
  /// question this feature gets asked most.
  final IniAnalyzeFilter? rejectedBy;

  /// Why it could not be used, when no filter is to blame - a channel the ECU
  /// is not reporting, say.
  final String? detail;

  /// How far off target the sample was: 1.0 is on target, 1.05 is 5% lean.
  final double? ratio;

  /// Cells this sample moved, if it pushed any past their threshold.
  final List<({int row, int column})> moved;

  /// A short explanation fit to show a user.
  String get description => accepted
      ? 'Collecting'
      : detail ?? 'Waiting: ${rejectedBy?.displayLabel ?? 'unknown'}';
}

/// What autotuning has gathered for one cell.
class AutotuneCell {
  AutotuneCell({required this.baseline});

  /// The cell's value when autotuning first touched it.
  ///
  /// Corrections are written as a percentage of this rather than nudged onto
  /// the current value, so repeated rounding cannot walk a cell away.
  final double baseline;

  /// Accumulated sample weight since the last application.
  double weight = 0;

  /// Weight-multiplied sum of correction ratios since the last application.
  double weightedRatio = 0;

  /// Samples that have ever landed here, for coverage display.
  int samples = 0;

  /// Total correction applied so far, as a percentage of [baseline].
  double appliedPercent = 0;

  /// The mean correction ratio held right now, or `null` with no data.
  double? get pendingRatio => weight == 0 ? null : weightedRatio / weight;
}

/// Whether a tune and definition can be autotuned at all.
class AutotuneReadiness {
  const AutotuneReadiness.ready() : reason = null;

  const AutotuneReadiness.blocked(this.reason);

  /// Why not, or `null` when it can run.
  final String? reason;

  /// Whether autotuning may be armed.
  bool get ready => reason == null;
}

/// Autotunes a VE table against a target, from fuelling measurements.
///
/// The arithmetic is the easy half. The hard half - and nearly all of the code
/// here - is deciding when a reading is telling the truth about the steady
/// state of the fuel table rather than about something else the engine was
/// doing. The definition's `[VeAnalyze]` filters supply most of those rules,
/// so they track the firmware instead of being guessed at here.
class VeAutotuner {
  VeAutotuner._({
    required this.config,
    required this.table,
    required this.target,
    required this.resolver,
    required this.settings,
    required this.permission,
    required this.units,
    required double stoich,
  }) : _stoich = stoich;

  /// Builds a tuner, or returns why one cannot be built.
  ///
  /// [tune] supplies the tables; [permission] is the same gate every other
  /// edit passes through, so a read-only session cannot autotune either.
  static ({VeAutotuner? tuner, AutotuneReadiness readiness}) create({
    required TuneState tune,
    required WritePermission permission,
    TuneValueResolver? resolver,
    AutotuneSettings settings = const AutotuneSettings(),
  }) {
    final definition = tune.definition;
    final config = definition.veAnalyze;
    if (config == null) {
      return (
        tuner: null,
        readiness: const AutotuneReadiness.blocked(
          'This definition does not describe VE autotuning.',
        ),
      );
    }

    final shared = resolver ?? TuneValueResolver(tune);

    final tableDefinition = definition.tableNamed(config.table);
    final targetDefinition = definition.tableNamed(config.targetTable);
    if (tableDefinition == null || targetDefinition == null) {
      return (
        tuner: null,
        readiness: AutotuneReadiness.blocked(
          'The definition names tables "${config.table}" and '
          '"${config.targetTable}" that it does not declare.',
        ),
      );
    }

    final table = TableView.of(tune, tableDefinition, resolver: shared);
    final target = TableView.of(tune, targetDefinition, resolver: shared);
    if (table == null || target == null) {
      return (
        tuner: null,
        readiness: const AutotuneReadiness.blocked(
          'The VE or target table could not be resolved from this tune.',
        ),
      );
    }

    final problem = autotuneSetupProblem(
      tune: tune,
      resolver: shared,
      config: config,
      table: table,
      target: target,
    );
    if (problem != null) {
      return (tuner: null, readiness: AutotuneReadiness.blocked(problem));
    }

    if (!permission.allowed) {
      return (
        tuner: null,
        readiness: AutotuneReadiness.blocked(
          permission.reason ?? 'Writing is not permitted in this session.',
        ),
      );
    }

    return (
      tuner: VeAutotuner._(
        config: config,
        table: table,
        target: target,
        resolver: shared,
        settings: settings,
        permission: permission,
        units: mixtureUnitsOf(config, target),
        // rusEFI declares no `stoich`, and needs none: its AFR is always
        // gasoline-scaled - lambda times 14.7 - whatever the fuel.
        stoich: shared.resolve('stoich') ?? 14.7,
      ),
      readiness: const AutotuneReadiness.ready(),
    );
  }

  /// The `[VeAnalyze]` description this follows.
  final IniVeAnalyze config;

  /// The VE table being tuned.
  final TableView table;

  /// The table supplying the target at each operating point.
  final TableView target;

  final TuneValueResolver resolver;

  /// The limits this session runs under.
  final AutotuneSettings settings;

  /// The write gate this session passed.
  final WritePermission permission;

  /// Whether readings and targets are lambda or AFR, fixed when armed.
  final MixtureUnits units;

  final double _stoich;

  final Map<({int row, int column}), AutotuneCell> _cells = {};
  final Map<String, CompiledExpression?> _compiled = {};

  ({int row, int column})? _lastCell;
  DateTime? _cellEnteredAt;

  int _accepted = 0;
  int _rejected = 0;

  /// Samples used so far.
  int get acceptedSamples => _accepted;

  /// Samples discarded by a filter so far.
  int get rejectedSamples => _rejected;

  /// Cells holding data or corrections, keyed by position.
  Map<({int row, int column}), AutotuneCell> get cells =>
      Map.unmodifiable(_cells);

  /// Cells that have been moved.
  int get movedCells =>
      _cells.values.where((c) => c.appliedPercent != 0).length;

  /// The settling rule, which the definition does not describe.
  static const settlingFilter = IniAnalyzeFilter(
    id: 'std_Settling',
    label: 'Settling',
  );

  /// The plausible-mixture rule, applied whether or not the definition
  /// declares it.
  ///
  /// rusEFI's does not. Without it, a wideband that has died and reads zero
  /// would ask for every cell it passes to be taken out entirely - and each
  /// would be, a step at a time, down to the session limit: leaner.
  static const deadSensorFilter = IniAnalyzeFilter(
    id: 'std_DeadLambda',
    label: 'Mixture reading',
  );

  /// Discards everything gathered, and re-reads each cell's starting value.
  void reset() {
    _cells.clear();
    _lastCell = null;
    _cellEnteredAt = null;
    _accepted = 0;
    _rejected = 0;
  }

  /// Offers one sample, applying a correction if it earns one.
  AutotuneOutcome offer(AnalyzeSample read, DateTime at) {
    final xChannel = table.table.xBins.channel;
    final yChannel = table.table.yBins.channel;
    if (xChannel == null || yChannel == null) {
      return const AutotuneOutcome.unusable(
        'The VE table declares no realtime channels for its axes.',
      );
    }

    final x = read(xChannel);
    final y = read(yChannel);
    if (x == null || y == null) {
      return AutotuneOutcome.unusable(
        'Waiting for $xChannel and $yChannel from the ECU.',
      );
    }

    final active = config.activeCondition;
    if (active != null && !_holds(active, read)) {
      _rejected++;
      return const AutotuneOutcome.unusable(
        'The definition says analysis does not apply right now.',
      );
    }

    // Settling comes first: until the operating point holds still there is no
    // point asking anything else about the sample.
    final settling = _settlingCheck(x, y, at);
    if (settling != null) {
      _rejected++;
      return settling;
    }

    for (final filter in config.filters) {
      final rejection = _evaluate(filter, read, x, y);
      if (rejection != null) {
        _rejected++;
        return rejection;
      }
    }

    final measured = read(config.measuredChannel);
    if (measured == null) {
      return AutotuneOutcome.unusable(
        'Waiting for ${config.measuredChannel} from the ECU.',
      );
    }

    final dead = _evaluateStandard(deadSensorFilter, read, x, y);
    if (dead != null) {
      _rejected++;
      return dead;
    }
    final measuredLambda = _toLambda(measured);

    // The target is read where the target table says the engine is, which
    // need not be where the VE table does: rusEFI gives each its own load
    // channel, and either can be overridden to TPS. Falling back to the VE
    // table's reading would look the target up at the wrong load.
    final tx = _targetAxis(target.table.xBins.channel, xChannel, x, read);
    final ty = _targetAxis(target.table.yBins.channel, yChannel, y, read);
    if (tx == null || ty == null) {
      return AutotuneOutcome.unusable(
        'Waiting for ${target.table.xBins.channel} and '
        '${target.table.yBins.channel} from the ECU.',
      );
    }

    final targetValue = target.interpolatedAt(tx, ty);
    if (targetValue == null) {
      return const AutotuneOutcome.unusable(
        'The target table has no value at this operating point.',
      );
    }
    final targetLambda = _toLambda(targetValue);
    // No engine is tuned for a mixture outside this. A target that reads as
    // one has been misread - in the wrong units, most likely - and tuning
    // against it would move every cell the wrong way.
    if (!(targetLambda >= _targetLambdaMin &&
        targetLambda <= _targetLambdaMax)) {
      return AutotuneOutcome.unusable(
        'The target reads as ${targetLambda.toStringAsFixed(2)} lambda here, '
        'which cannot be a mixture target.',
      );
    }

    // A closed loop already trimming fuel means the table under it is wrong by
    // that much, even though the measurement looks on target. Folding the trim
    // in tunes the table rather than fighting the correction.
    final trim = read(config.egoCorrectionChannel);
    final egoFactor = trim == null || trim <= 0 ? 1.0 : trim / 100.0;

    final ratio = (measuredLambda / targetLambda) * egoFactor;

    _accepted++;
    final moved = _distribute(x, y, ratio);
    return AutotuneOutcome.accepted(ratio: ratio, moved: moved);
  }

  static const _targetLambdaMin = 0.4;
  static const _targetLambdaMax = 2.5;

  /// Converts a reading to lambda, using the tune's own stoichiometric ratio.
  double _toLambda(double value) =>
      units == MixtureUnits.lambda ? value : value / _stoich;

  /// The target table's reading on one axis: the VE table's [shared] reading
  /// where both follow the same channel, otherwise the target's own.
  double? _targetAxis(
    String? channel,
    String veChannel,
    double shared,
    AnalyzeSample read,
  ) =>
      channel == null || channel == veChannel ? shared : read(channel);

  AutotuneOutcome? _settlingCheck(double x, double y, DateTime at) {
    final cell = table.cellFor(x, y);
    if (cell == null) return null;

    if (_lastCell != cell) {
      _lastCell = cell;
      _cellEnteredAt = at;
    }
    final since = _cellEnteredAt;
    if (since == null) {
      _cellEnteredAt = at;
      return const AutotuneOutcome.rejected(settlingFilter);
    }

    if (at.difference(since) < settings.settlingTime) {
      return const AutotuneOutcome.rejected(settlingFilter);
    }
    return null;
  }

  /// Applies one filter, returning a rejection when it blocks the sample.
  AutotuneOutcome? _evaluate(
    IniAnalyzeFilter filter,
    AnalyzeSample read,
    double x,
    double y,
  ) {
    if (filter.isStandard) return _evaluateStandard(filter, read, x, y);

    final operator = filter.operator;
    final threshold = filter.value;
    if (operator == null || threshold == null) return null;

    final value = read(filter.channel);
    // A channel this ECU does not report cannot condemn a sample. Rejecting
    // on it would stop autotuning entirely on firmware that omits it.
    if (value == null) return null;

    final blocks = switch (operator) {
      IniFilterOperator.lessThan => value < threshold,
      IniFilterOperator.greaterThan => value > threshold,
      IniFilterOperator.equals => value == threshold,
      IniFilterOperator.bitmask => (value.toInt() & threshold.toInt()) != 0,
    };
    return blocks ? AutotuneOutcome.rejected(filter) : null;
  }

  AutotuneOutcome? _evaluateStandard(
    IniAnalyzeFilter filter,
    AnalyzeSample read,
    double x,
    double y,
  ) {
    switch (filter.id) {
      case 'std_xAxisMin':
        final low = table.xAt(0);
        return low != null && x < low
            ? AutotuneOutcome.rejected(filter,
                detail: 'Below the table at ${x.round()} ${table.xUnits}')
            : null;

      case 'std_xAxisMax':
        final high = table.xAt(table.columns - 1);
        return high != null && x > high
            ? AutotuneOutcome.rejected(filter,
                detail: 'Past the table at ${x.round()} ${table.xUnits}')
            : null;

      case 'std_yAxisMin':
        final low = table.yAt(0);
        return low != null && y < low
            ? AutotuneOutcome.rejected(filter,
                detail: 'Below the table at ${y.round()} ${table.yUnits}')
            : null;

      case 'std_yAxisMax':
        final high = table.yAt(table.rows - 1);
        return high != null && y > high
            ? AutotuneOutcome.rejected(filter,
                detail: 'Past the table at ${y.round()} ${table.yUnits}')
            : null;

      case 'std_DeadLambda':
        final measured = read(config.measuredChannel);
        if (measured == null) return AutotuneOutcome.rejected(filter);
        final lambda = _toLambda(measured);
        final dead = !lambda.isFinite ||
            lambda < settings.lambdaMin ||
            lambda > settings.lambdaMax;
        return dead
            ? AutotuneOutcome.rejected(filter,
                detail: 'Mixture reading of ${lambda.toStringAsFixed(2)} '
                    'lambda is outside the plausible range')
            : null;

      case 'std_Custom':
        final source = settings.customFilter.trim();
        if (source.isEmpty) return null;
        return _holds(source, read)
            ? AutotuneOutcome.rejected(filter, detail: 'Custom filter: $source')
            : null;

      default:
        // A standard filter this version does not implement must not silently
        // pass as though it had been applied.
        return AutotuneOutcome.rejected(filter,
            detail: 'Filter "${filter.id}" is not supported yet');
    }
  }

  /// Whether [source] evaluates true against the sample and the tune.
  bool _holds(String source, AnalyzeSample read) {
    final compiled = _compiled.putIfAbsent(
      source,
      () => CompiledExpression.tryCompile(source),
    );
    if (compiled == null) return false;
    final value =
        compiled.evaluate((name) => read(name) ?? resolver.resolve(name));
    return value != null && value != 0;
  }

  /// Credits [ratio] to the cells around the operating point and applies any
  /// that have gathered enough evidence.
  List<({int row, int column})> _distribute(double x, double y, double ratio) {
    final moved = <({int row, int column})>[];

    for (final entry in table.weightsAt(x, y)) {
      final key = (row: entry.row, column: entry.column);
      final current = table.valueAt(key.row, key.column);
      if (current == null) continue;

      final cell =
          _cells.putIfAbsent(key, () => AutotuneCell(baseline: current));
      cell.weight += entry.weight;
      cell.weightedRatio += entry.weight * ratio;
      cell.samples++;

      if (cell.weight < settings.minWeight) continue;
      if (_apply(key, cell)) moved.add(key);
    }

    return moved;
  }

  /// Moves one cell towards what its samples are asking for.
  ///
  /// Returns whether the stored value actually changed, which is not the same
  /// as whether a correction was book-kept: the running total accumulates
  /// steps too small for the storage to hold, so a cell on a coarse table
  /// still reaches its target over several passes rather than being rounded
  /// away to nothing each time.
  bool _apply(({int row, int column}) key, AutotuneCell cell) {
    final mean = cell.pendingRatio;
    final wanted = mean == null ? 0.0 : (mean - 1) * 100;

    // The accumulator is cleared however this turns out. Once a correction has
    // been applied - or declined - the readings behind it describe fuelling
    // the engine no longer has.
    cell.weight = 0;
    cell.weightedRatio = 0;
    if (mean == null) return false;

    // An error the storage could not represent even if it were applied is not
    // an error. Without this, floating-point noise on a perfectly on-target
    // sample reads as a change to the tune.
    if (wanted.abs() < _deadbandPercent(cell.baseline)) return false;

    final step =
        wanted.clamp(-settings.maxStepPercent, settings.maxStepPercent);
    final next = (cell.appliedPercent + step)
        .clamp(-settings.maxTotalPercent, settings.maxTotalPercent);
    if (next == cell.appliedPercent) return false;

    cell.appliedPercent = next;
    final before = table.rawAt(key.row, key.column);
    table.setValueAt(key.row, key.column, cell.baseline * (1 + next / 100));
    return table.rawAt(key.row, key.column) != before;
  }

  /// The smallest correction worth making, as a percentage of [baseline].
  ///
  /// Half of what one step of the table's storage represents: below that, the
  /// value written back would be the value already there.
  double _deadbandPercent(double baseline) {
    if (baseline == 0) return 0;
    return (table.zStep / 2) / baseline.abs() * 100;
  }
}
