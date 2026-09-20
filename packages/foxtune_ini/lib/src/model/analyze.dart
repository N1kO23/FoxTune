/// How a filter compares a channel against its threshold.
enum IniFilterOperator {
  /// Reject when the channel is below the value.
  lessThan('<'),

  /// Reject when the channel is above the value.
  greaterThan('>'),

  /// Reject when the channel equals the value.
  equals('='),

  /// Reject when the channel has any of the value's bits set.
  ///
  /// The definition tests status flags this way: `engine, &, 16` is "the
  /// acceleration enrichment bit is set", which is exactly when a fuelling
  /// reading says nothing about the steady-state table.
  bitmask('&');

  const IniFilterOperator(this.token);

  /// The symbol the definition writes.
  final String token;

  /// Parses an operator symbol, or `null` if it is not one.
  static IniFilterOperator? tryParse(String token) {
    final trimmed = token.trim();
    for (final operator in values) {
      if (operator.token == trimmed) return operator;
    }
    return null;
  }
}

/// One condition under which a fuelling sample must not be trusted.
///
/// These are the safety-critical half of autotuning, and the definition
/// supplies them rather than FoxTune guessing: a reading taken while the
/// engine is cold, accelerating, in afterstart enrichment or on the overrun
/// describes something other than the steady-state fuel table.
class IniAnalyzeFilter {
  const IniAnalyzeFilter({
    required this.id,
    required this.label,
    this.channel = '',
    this.operator,
    this.value,
    this.value2,
    this.flag = false,
  });

  /// Identifier, e.g. `minCltFilter` or `std_DeadLambda`.
  final String id;

  /// Display label, e.g. "Minimum CLT". Empty for the standard filters, which
  /// the definition names but does not describe.
  final String label;

  /// Output channel to test. Empty for standard filters.
  final String channel;

  /// How [channel] is compared against [value]. Null for standard filters.
  final IniFilterOperator? operator;

  /// Threshold the channel is compared against.
  final double? value;

  /// Second threshold, where the declaration supplies one.
  final double? value2;

  /// The trailing boolean the declaration carries.
  ///
  /// Its meaning is not documented, and the shipped file's usage fits more
  /// than one reading - "the threshold is user-adjustable" fits every line,
  /// but so does "enabled by default". It is recorded and deliberately not
  /// acted on: reading it the wrong way would silently switch off a filter
  /// that exists to stop a bad sample reaching the fuel table.
  final bool flag;

  /// Whether this is one of the `std_*` filters the host implements itself.
  ///
  /// The definition names these without describing them, because TunerStudio
  /// builds them from the table's own axes and the sensor's plausible range.
  bool get isStandard => id.startsWith('std_');

  /// A label fit to show a user, falling back to the identifier.
  String get displayLabel => label.isEmpty ? id : label;

  @override
  String toString() => isStandard
      ? 'filter $id'
      : 'filter $id ($channel ${operator?.token} $value)';
}

/// The `[VeAnalyze]` section: how to autotune the VE table.
///
/// Names the table to tune, the target it is tuned against, the channel that
/// measures what the engine actually did, and the closed-loop trim already
/// being applied - plus the filters above. Under `#if LAMBDA` the target and
/// measured channel are lambda rather than AFR, which is why this is read from
/// the file instead of assumed.
class IniVeAnalyze {
  const IniVeAnalyze({
    required this.table,
    required this.targetTable,
    required this.measuredChannel,
    required this.egoCorrectionChannel,
    this.activeCondition,
    this.lambdaTargetTables = const [],
    this.filters = const [],
  });

  /// Identifier of the table to tune, e.g. `veTable1Tbl`.
  final String table;

  /// Identifier of the table holding the target, e.g. `afrTable1Tbl`.
  final String targetTable;

  /// Channel reporting what the engine actually ran, e.g. `afr` or `lambda`.
  final String measuredChannel;

  /// Channel reporting the closed-loop trim already applied, as a percentage.
  final String egoCorrectionChannel;

  /// Expression gating whether analysis may run at all.
  final String? activeCondition;

  /// Target tables a tuner may choose between.
  ///
  /// `afrTSCustom` is TunerStudio's own host-side table; FoxTune has no
  /// equivalent and ignores it, but the name is kept rather than dropped.
  final List<String> lambdaTargetTables;

  /// Filters in declaration order.
  final List<IniAnalyzeFilter> filters;

  /// Whether [measuredChannel] reports lambda rather than an air-fuel ratio.
  ///
  /// The two differ by the stoichiometric ratio, so getting this wrong scales
  /// every correction by about fourteen.
  bool get measuresLambda => measuredChannel.toLowerCase().contains('lambda');

  /// Filters the host implements itself, from their identifiers.
  Iterable<IniAnalyzeFilter> get standardFilters =>
      filters.where((f) => f.isStandard);

  /// Filters declared with a channel and a threshold.
  Iterable<IniAnalyzeFilter> get channelFilters =>
      filters.where((f) => !f.isStandard);

  @override
  String toString() =>
      'veAnalyze $table against $targetTable via $measuredChannel '
      '(${filters.length} filters)';
}
