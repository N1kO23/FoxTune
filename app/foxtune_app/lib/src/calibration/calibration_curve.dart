import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../dashboard/gauge_status.dart';

/// A calibration's values across the sensor's range, as a line from 0 V to
/// the reference voltage.
///
/// Steps holding the fallback are ringed rather than joined into the line:
/// they are where the sensor reads as open or shorted, not part of its curve.
class CalibrationCurve extends StatelessWidget {
  const CalibrationCurve({
    super.key,
    required this.values,
    required this.fallbacks,
    required this.units,
    this.referenceVolts = 5,
    this.decimals = 1,
  });

  /// One value per ADC step, in [units].
  final List<double> values;

  /// Indices of [values] that hold the fallback.
  final Set<int> fallbacks;

  final String units;
  final double referenceVolts;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    if (values.isEmpty) return const SizedBox.shrink();

    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    if (high - low < 1e-9) {
      low -= 1;
      high += 1;
    }
    final pad = (high - low) * 0.06;
    low -= pad;
    high += pad;

    String label(double v) => '${v.toStringAsFixed(decimals)} $units';
    final curve = [
      for (var i = 0; i < values.length; i++)
        if (!fallbacks.contains(i)) values[i],
    ];

    return Semantics(
      label: curve.isEmpty
          ? 'Calibration curve: every step holds the fallback'
          : 'Calibration curve from ${label(curve.first)} at 0 volts to '
                '${label(curve.last)} at ${_volts(referenceVolts)}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 180,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 72,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(label(high - pad), style: small),
                        Text(label(low + pad), style: small),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: CustomPaint(
                      painter: _CurvePainter(
                        values: values,
                        fallbacks: fallbacks,
                        low: low,
                        high: high,
                        line: scheme.primary,
                        grid: scheme.outlineVariant,
                        ringed: StatusPalette.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 80),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('0 V', style: small),
                  Text('Sensor voltage', style: small),
                  Text(_volts(referenceVolts), style: small),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _volts(double volts) =>
      '${volts == volts.roundToDouble() ? volts.toInt() : volts} V';
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.values,
    required this.fallbacks,
    required this.low,
    required this.high,
    required this.line,
    required this.grid,
    required this.ringed,
  });

  final List<double> values;
  final Set<int> fallbacks;
  final double low;
  final double high;
  final Color line;
  final Color grid;
  final Color ringed;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    double x(int i) =>
        values.length < 2 ? 0 : size.width * i / (values.length - 1);
    double y(double v) => size.height * (1 - (v - low) / (high - low));

    final path = Path();
    var drawing = false;
    for (var i = 0; i < values.length; i++) {
      if (fallbacks.contains(i)) {
        drawing = false;
        continue;
      }
      final point = Offset(x(i), y(values[i]));
      if (drawing) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        drawing = true;
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );

    final ring = Paint()
      ..color = ringed
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final i in fallbacks) {
      canvas.drawCircle(Offset(x(i), y(values[i])), 3.5, ring);
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      !identical(old.values, values) ||
      !identical(old.fallbacks, fallbacks) ||
      old.low != low ||
      old.high != high ||
      old.line != line ||
      old.grid != grid ||
      old.ringed != ringed;
}
