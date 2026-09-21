import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gauge_status.dart';

/// A radial meter: one value against its limits.
///
/// Drawn rather than charted because the job is "ratio against a limit", read
/// at a glance by angular position. The track is a single recessive arc and the
/// value arc is one hue, so magnitude reads without a legend.
class MeterGauge extends StatelessWidget {
  const MeterGauge({
    super.key,
    required this.spec,
    required this.value,
    this.compact = false,
  });

  final GaugeSpec spec;
  final double? value;

  /// Tightens the layout for narrow screens.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = spec.statusFor(value);
    final accent = StatusPalette.forStatus(status, scheme);

    return Semantics(
      label:
          '${spec.label}: ${spec.format(value)} ${spec.units}'
          '${status.isAlarm ? ', ${StatusPalette.labelFor(status)}' : ''}',
      child: AspectRatio(
        aspectRatio: 1,
        child: CustomPaint(
          painter: _MeterPainter(
            fraction: spec.fractionFor(value),
            warnFraction: spec.warnAbove == null
                ? null
                : spec.fractionFor(spec.warnAbove),
            dangerFraction: spec.dangerAbove == null
                ? null
                : spec.fractionFor(spec.dangerAbove),
            trackColor: scheme.surfaceContainerHighest,
            accentColor: accent,
            warnColor: StatusPalette.warning,
            dangerColor: StatusPalette.critical,
            hasValue: value != null,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  spec.label.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 2),
                // The value wears a text token, not the status colour; the arc
                // and the badge carry the state.
                Text(
                  spec.format(value),
                  style:
                      (compact
                              ? theme.textTheme.headlineSmall
                              : theme.textTheme.displaySmall)
                          ?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurface,
                          ),
                ),
                if (spec.units.isNotEmpty)
                  Text(
                    spec.units,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (status.isAlarm) ...[
                  const SizedBox(height: 4),
                  AlarmBadge(status: status),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Icon plus text, so an alarm is never signalled by colour alone.
///
/// Shared by every gauge style, so a warning looks the same on a dial, a bar
/// and a graph.
class AlarmBadge extends StatelessWidget {
  const AlarmBadge({super.key, required this.status});
  final GaugeStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status == GaugeStatus.danger
        ? StatusPalette.critical
        : StatusPalette.warning;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(StatusPalette.iconFor(status), size: 13, color: color),
        const SizedBox(width: 3),
        Text(
          StatusPalette.labelFor(status)!,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({
    required this.fraction,
    required this.warnFraction,
    required this.dangerFraction,
    required this.trackColor,
    required this.accentColor,
    required this.warnColor,
    required this.dangerColor,
    required this.hasValue,
  });

  final double fraction;
  final double? warnFraction;
  final double? dangerFraction;
  final Color trackColor;
  final Color accentColor;
  final Color warnColor;
  final Color dangerColor;
  final bool hasValue;

  /// Open-bottom dial: starts at 135° and sweeps 270°.
  static const double _startAngle = math.pi * 0.75;
  static const double _sweepAngle = math.pi * 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.085;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - stroke) / 2 - 2,
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, track);

    // Threshold marks sit on the track so limits are visible before they are
    // reached, not only once they trip.
    for (final (limit, color) in <(double?, Color)>[
      (warnFraction, warnColor),
      (dangerFraction, dangerColor),
    ]) {
      if (limit == null || limit <= 0 || limit >= 1) continue;
      final angle = _startAngle + _sweepAngle * limit;
      final tick = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color.withValues(alpha: 0.55);
      canvas.drawArc(rect, angle, 0.02, false, tick);
    }

    if (!hasValue || fraction <= 0) return;

    final value = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = accentColor;
    canvas.drawArc(rect, _startAngle, _sweepAngle * fraction, false, value);
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.fraction != fraction ||
      old.accentColor != accentColor ||
      old.hasValue != hasValue ||
      old.trackColor != trackColor;
}
