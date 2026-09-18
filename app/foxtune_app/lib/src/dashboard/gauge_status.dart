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

/// Default presentation for a Speeduino.
///
/// Thresholds are conservative starting points for a naturally aspirated
/// engine, not tuned advice - they exist so the alarm path is real and
/// visible. Making these user-configurable is follow-up work.
abstract final class DefaultGauges {
  /// The large meters: values read at a glance by angular position.
  static const List<GaugeSpec> primary = [
    GaugeSpec(
      channel: 'rpm',
      label: 'RPM',
      units: 'rpm',
      min: 0,
      max: 8000,
      warnAbove: 6000,
      dangerAbove: 7000,
    ),
    GaugeSpec(
      channel: 'coolant',
      label: 'Coolant',
      units: '°',
      min: -40,
      max: 140,
      warnAbove: 100,
      dangerAbove: 110,
    ),
    GaugeSpec(channel: 'map', label: 'MAP', units: 'kPa', min: 0, max: 260),
  ];

  /// Secondary readings, shown as numeric tiles.
  static const List<GaugeSpec> secondary = [
    GaugeSpec(
      channel: 'afr',
      label: 'AFR',
      units: '',
      min: 8,
      max: 20,
      decimals: 1,
      warnAbove: 16,
      dangerAbove: 17.5,
    ),
    GaugeSpec(
      channel: 'batteryVoltage',
      label: 'Battery',
      units: 'V',
      min: 8,
      max: 16,
      decimals: 1,
      // Low voltage is the failure mode here, not high.
      warnBelow: 12.0,
      dangerBelow: 11.0,
      warnAbove: 15.0,
    ),
    GaugeSpec(
      channel: 'iat',
      label: 'Intake air',
      units: '°',
      min: -40,
      max: 120,
      warnAbove: 60,
    ),
    GaugeSpec(channel: 'tps', label: 'Throttle', units: '%', min: 0, max: 100),
    GaugeSpec(
      channel: 'advance',
      label: 'Advance',
      units: '°',
      min: -20,
      max: 60,
    ),
    GaugeSpec(channel: 'VE1', label: 'VE', units: '%', min: 0, max: 200),
    GaugeSpec(
      channel: 'pulseWidth',
      label: 'Pulse width',
      units: 'ms',
      min: 0,
      max: 25,
      decimals: 2,
    ),
    GaugeSpec(
      channel: 'dutyCycle',
      label: 'Duty',
      units: '%',
      min: 0,
      max: 100,
      warnAbove: 85,
      dangerAbove: 95,
    ),
    GaugeSpec(
      channel: 'dwell',
      label: 'Dwell',
      units: 'ms',
      min: 0,
      max: 10,
      decimals: 2,
    ),
    GaugeSpec(
      channel: 'egoCorrection',
      label: 'EGO corr',
      units: '%',
      min: 50,
      max: 150,
    ),
  ];

  /// Status flags worth surfacing as indicator lamps.
  static const List<({String channel, String label})> flags = [
    (channel: 'running', label: 'Running'),
    (channel: 'crank', label: 'Cranking'),
    (channel: 'ase', label: 'Warmup enrich'),
    (channel: 'warmup', label: 'Warmup'),
    (channel: 'DFCOOn', label: 'DFCO'),
    (channel: 'sync', label: 'Sync'),
  ];
}
