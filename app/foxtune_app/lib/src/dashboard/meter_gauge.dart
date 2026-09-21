import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gauge_status.dart';

/// A radial meter: one value against its limits.
///
/// Drawn rather than charted because the job is "ratio against a limit", read
/// at a glance by angular position. The track is a single recessive arc and the
/// value arc is one hue, so magnitude reads without a legend.
///
/// Its text is set in the same sizes as the rest of the dashboard - captions
/// like a lamp's label, the value like a digital readout's - and kept inside
/// the arc: a line too long for the space shrinks rather than running into it.
class MeterGauge extends StatelessWidget {
  const MeterGauge({super.key, required this.spec, required this.value});

  final GaugeSpec spec;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = spec.statusFor(value);
    final accent = StatusPalette.forStatus(status, scheme);
    final caption = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    // One line of text, shrunk to the width it is given if it needs to be.
    Widget line(Widget child) => FittedBox(fit: BoxFit.scaleDown, child: child);

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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The largest box that sits clear of the arc: its corners lie
              // just inside the inner edge of the track.
              final inner = _MeterPainter.innerRadius(
                constraints.biggest.shortestSide,
              );
              final width = inner * 1.5;
              return Center(
                child: SizedBox(
                  width: width,
                  height: inner * 1.3,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          line(Text(spec.label, maxLines: 1, style: caption)),
                          // The value wears a text token, not the status
                          // colour; the arc and the badge carry the state.
                          line(
                            Text(
                              spec.format(value),
                              maxLines: 1,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if (spec.units.isNotEmpty)
                            line(Text(spec.units, maxLines: 1, style: caption)),
                          if (status.isAlarm) ...[
                            const SizedBox(height: 2),
                            line(AlarmBadge(status: status)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
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

  static double _strokeFor(double side) => side * 0.085;

  static double _radiusFor(double side) => (side - _strokeFor(side)) / 2 - 2;

  /// How far from the centre the track's inner edge is, on a dial [side]
  /// across: the room the text has.
  static double innerRadius(double side) =>
      _radiusFor(side) - _strokeFor(side) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = _strokeFor(size.shortestSide);
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: _radiusFor(size.shortestSide),
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
