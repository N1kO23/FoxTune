import 'package:flutter/material.dart';

/// Severity of a reading relative to its configured limits.
enum GaugeStatus {
  normal,
  warning,
  danger;

  /// Whether this state needs to be called out rather than just shown.
  bool get isAlarm => this != GaugeStatus.normal;
}

/// Fixed status colors, never themed and never reused for anything else.
///
/// On a light surface `warning` falls below 3:1 contrast by design. That is why
/// every alarm here is rendered with an icon and a text label as well: colour
/// alone never carries the meaning, which also keeps the cluster readable for
/// colour-blind users and in direct sunlight.
abstract final class StatusPalette {
  static const Color good = Color(0xFF0CA30C);
  static const Color warning = Color(0xFFFAB219);
  static const Color critical = Color(0xFFD03B3B);

  static Color forStatus(GaugeStatus status, ColorScheme scheme) =>
      switch (status) {
        GaugeStatus.normal => scheme.primary,
        GaugeStatus.warning => warning,
        GaugeStatus.danger => critical,
      };

  /// The icon that accompanies an alarm. Never omitted.
  static IconData? iconFor(GaugeStatus status) => switch (status) {
    GaugeStatus.normal => null,
    GaugeStatus.warning => Icons.warning_amber_rounded,
    GaugeStatus.danger => Icons.error_rounded,
  };

  /// The short text that accompanies an alarm. Never omitted.
  static String? labelFor(GaugeStatus status) => switch (status) {
    GaugeStatus.normal => null,
    GaugeStatus.warning => 'WARN',
    GaugeStatus.danger => 'DANGER',
  };
}

/// How one channel should be presented.
class GaugeSpec {
  const GaugeSpec({
    required this.channel,
    required this.label,
    required this.units,
    required this.min,
    required this.max,
    this.decimals = 0,
    this.labelDecimals,
    this.warnAbove,
    this.dangerAbove,
    this.warnBelow,
    this.dangerBelow,
  });

  /// Channel name as the definition declares it.
  final String channel;

  /// Short display label.
  final String label;

  /// Units suffix. May be empty.
  final String units;

  final double min;
  final double max;

  /// Decimal places to display.
  final int decimals;

  /// Decimal places for scale labels, where they differ from the value's.
  final int? labelDecimals;

  /// Formats a scale label - an end of the range, a band - at label precision.
  String formatLabel(double value) =>
      value.toStringAsFixed(labelDecimals ?? decimals);

  /// Upper limits, for values that are dangerous when too high.
  final double? warnAbove;
  final double? dangerAbove;

  /// Lower limits, for values that are dangerous when too low.
  ///
  /// Battery voltage and oil pressure are the cases that matter: for those,
  /// low is the failure, not high.
  final double? warnBelow;
  final double? dangerBelow;

  /// Classifies [value] against the configured limits.
  GaugeStatus statusFor(double? value) {
    if (value == null) return GaugeStatus.normal;
    if (dangerAbove != null && value >= dangerAbove!) return GaugeStatus.danger;
    if (dangerBelow != null && value <= dangerBelow!) return GaugeStatus.danger;
    if (warnAbove != null && value >= warnAbove!) return GaugeStatus.warning;
    if (warnBelow != null && value <= warnBelow!) return GaugeStatus.warning;
    return GaugeStatus.normal;
  }

  /// [value] mapped to 0..1 across the gauge's span, clamped.
  double fractionFor(double? value) {
    if (value == null || max <= min) return 0;
    return ((value - min) / (max - min)).clamp(0.0, 1.0);
  }

  /// Formats [value] for display, or a placeholder when unavailable.
  String format(double? value) =>
      value == null ? '--' : value.toStringAsFixed(decimals);
}

/// Which temperature scale the ECU definition is parsed for.
///
/// This is not cosmetic. The definition computes `coolant` and `iat` from the
/// raw channels with different expressions per scale, so the choice changes the
/// *numbers* the decoder produces - and therefore what a gauge range and its
/// warning thresholds have to mean. Getting the two out of step is how a
/// healthy 108 degree engine reads as 226 and pegs the gauge.
enum TemperatureUnit {
  celsius('\u00B0C'),
  fahrenheit('\u00B0F');

  const TemperatureUnit(this.symbol);

  /// Display suffix.
  final String symbol;

  /// Preprocessor symbols to parse the definition with.
  ///
  /// The Speeduino definition gates its Celsius expressions behind `CELSIUS`
  /// and falls through to Fahrenheit otherwise.
  Set<String> get iniSymbols =>
      this == TemperatureUnit.celsius ? const {'CELSIUS'} : const {};

  /// Converts a threshold expressed in Celsius into this scale.
  double fromCelsius(double celsius) =>
      this == TemperatureUnit.celsius ? celsius : celsius * 1.8 + 32;
}
