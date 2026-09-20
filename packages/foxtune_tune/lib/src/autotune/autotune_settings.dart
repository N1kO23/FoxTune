/// The limits a VE autotuning session runs under.
///
/// Every default here is deliberately timid. Autotuning writes the fuel table,
/// and the failure mode of being too eager - a cell moved a long way on thin
/// evidence - is an engine running lean under load. Being too cautious just
/// means another lap.
class AutotuneSettings {
  const AutotuneSettings({
    this.maxStepPercent = 2,
    this.maxTotalPercent = 25,
    this.minWeight = 5,
    this.settlingTime = const Duration(milliseconds: 500),
    this.lambdaMin = 0.6,
    this.lambdaMax = 1.5,
    this.customFilter = '',
  });

  /// Most a cell may move in one application, as a percentage of its value.
  ///
  /// Small steps let the next measurement judge the last one, which is what
  /// makes this converge rather than oscillate.
  final double maxStepPercent;

  /// Most a cell may move over the whole session, against where it started.
  ///
  /// A cell that wants to move more than this is usually being told something
  /// other than "the VE is wrong" - an injector at its duty limit, a fuel
  /// pressure problem, a leaking exhaust near the sensor.
  final double maxTotalPercent;

  /// Accumulated sample weight a cell needs before it is allowed to move.
  final double minWeight;

  /// How long the operating point must hold still before a reading counts.
  ///
  /// Exhaust gas takes time to reach the sensor, so a reading describes
  /// combustion that already happened. Accepting one taken mid-transition
  /// credits it to whichever cell the engine has moved into, which is how an
  /// autotuner teaches itself nonsense on a road drive.
  final Duration settlingTime;

  /// Lowest lambda treated as a real reading.
  final double lambdaMin;

  /// Highest lambda treated as a real reading.
  ///
  /// A cold, disconnected or rail-pinned sensor reports numbers that look
  /// exactly like data. Bounding the plausible range is what `std_DeadLambda`
  /// asks for, and the definition leaves the bounds to the host.
  final double lambdaMax;

  /// An extra user expression; a sample is rejected while it holds.
  ///
  /// This is the definition's `std_Custom` filter. Empty means no extra rule.
  final String customFilter;

  /// A copy with the given fields replaced.
  AutotuneSettings copyWith({
    double? maxStepPercent,
    double? maxTotalPercent,
    double? minWeight,
    Duration? settlingTime,
    double? lambdaMin,
    double? lambdaMax,
    String? customFilter,
  }) =>
      AutotuneSettings(
        maxStepPercent: maxStepPercent ?? this.maxStepPercent,
        maxTotalPercent: maxTotalPercent ?? this.maxTotalPercent,
        minWeight: minWeight ?? this.minWeight,
        settlingTime: settlingTime ?? this.settlingTime,
        lambdaMin: lambdaMin ?? this.lambdaMin,
        lambdaMax: lambdaMax ?? this.lambdaMax,
        customFilter: customFilter ?? this.customFilter,
      );
}
