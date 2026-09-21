import 'package:flutter/material.dart';

import 'gauge_status.dart';
import 'meter_gauge.dart' show AlarmBadge;

/// A reading as a filled bar - horizontal or vertical, whichever its space is.
///
/// A meter: the fill carries the state, and the unfilled track is a light step
/// of the same colour, so a bar in warning reads amber end to end rather than
/// as a small amber sliver on grey. The state is never the colour alone - an
/// alarm also shows its icon and word.
class BarGauge extends StatelessWidget {
  const BarGauge({super.key, required this.spec, required this.value});

  final GaugeSpec spec;
  final double? value;

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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vertical = constraints.maxHeight > constraints.maxWidth;

          final heading = Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          );
          final reading = Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                spec.format(value),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              if (spec.units.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(
                  spec.units,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );
          final bar = CustomPaint(
            painter: _BarPainter(
              fraction: spec.fractionFor(value),
              vertical: vertical,
              fill: accent,
              hasValue: value != null,
            ),
          );

          if (vertical) {
            return Column(
              children: [
                heading,
                const SizedBox(height: 4),
                Expanded(
                  child: Center(child: SizedBox(width: 20, child: bar)),
                ),
                const SizedBox(height: 4),
                FittedBox(child: reading),
                if (status.isAlarm)
                  FittedBox(child: AlarmBadge(status: status)),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: heading),
                  // The reading and its alarm shrink before they overflow:
                  // a readout restyled as a bar keeps its narrow width.
                  Flexible(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (status.isAlarm) ...[
                            AlarmBadge(status: status),
                            const SizedBox(width: 6),
                          ],
                          reading,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SizedBox(height: 12, child: bar),
            ],
          );
        },
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.fraction,
    required this.vertical,
    required this.fill,
    required this.hasValue,
  });

  final double fraction;
  final bool vertical;
  final Color fill;
  final bool hasValue;

  /// Round at the data end only; the baseline end stays square.
  static const _radius = Radius.circular(4);

  @override
  void paint(Canvas canvas, Size size) {
    final track = Paint()..color = fill.withValues(alpha: 0.18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, _radius),
      track,
    );
    if (!hasValue || fraction <= 0) return;

    final paint = Paint()..color = fill;
    if (vertical) {
      final height = size.height * fraction;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, size.height - height, size.width, height),
          topLeft: _radius,
          topRight: _radius,
        ),
        paint,
      );
    } else {
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, 0, size.width * fraction, size.height),
          topRight: _radius,
          bottomRight: _radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.fraction != fraction ||
      old.vertical != vertical ||
      old.fill != fill ||
      old.hasValue != hasValue;
}
