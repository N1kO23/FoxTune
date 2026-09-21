import 'package:flutter/material.dart';

import 'gauge_status.dart';
import 'meter_gauge.dart' show AlarmBadge;
import 'sample_history.dart';

/// Recent history of one to four channels, one lane each, sharing a time axis.
///
/// Lanes rather than lines overlaid on one plot: RPM runs to thousands and AFR
/// to fifteen, so overlaying them means either flattening one or giving each
/// line its own scale on the same axis - and then how high a line sits means
/// something different for every line. A lane per channel keeps each scale
/// honest and the times lined up, which is what comparing them needs.
class TimeGraph extends StatelessWidget {
  const TimeGraph({
    super.key,
    required this.lanes,
    required this.history,
    required this.window,
  });

  /// What each lane shows, top to bottom.
  final List<GaugeSpec> lanes;

  final SampleHistory history;

  /// How much history is shown.
  final Duration window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final spec in lanes)
            Expanded(
              child: _Lane(spec: spec, history: history, window: window),
            ),
          // The time axis, shared by every lane.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Text('-${window.inSeconds}s', style: muted),
                const Spacer(),
                Text('-${window.inSeconds ~/ 2}s', style: muted),
                const Spacer(),
                Text('now', style: muted),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.spec,
    required this.history,
    required this.window,
  });

  final GaugeSpec spec;
  final SampleHistory history;
  final Duration window;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = history.latest?[spec.channel];
    final status = spec.statusFor(current);

    return Semantics(
      label: '${spec.label}: ${spec.format(current)} ${spec.units}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.units.isEmpty
                      ? spec.label
                      : '${spec.label} (${spec.units})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (status.isAlarm) ...[
                AlarmBadge(status: status),
                const SizedBox(width: 6),
              ],
              // The value sits where the line ends, in ink rather than in the
              // line's colour.
              Text(
                spec.format(current),
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          Expanded(
            child: CustomPaint(
              painter: LanePainter(
                spec: spec,
                history: history,
                window: window,
                line: scheme.primary,
                grid: scheme.outlineVariant,
                label: scheme.onSurfaceVariant,
                labelStyle: theme.textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws one lane: hairline bounds, its scale's ends, and the trace.
@visibleForTesting
class LanePainter extends CustomPainter {
  LanePainter({
    required this.spec,
    required this.history,
    required this.window,
    required this.line,
    required this.grid,
    required this.label,
    this.labelStyle,
  }) : super(repaint: history);

  final GaugeSpec spec;
  final SampleHistory history;
  final Duration window;
  final Color line;
  final Color grid;
  final Color label;
  final TextStyle? labelStyle;

  /// Where the trace would be drawn, oldest to newest, as fractions of the
  /// lane: x from 0 (the start of the window) to 1 (now), y from 0 (top, the
  /// scale's maximum) to 1 (bottom, its minimum). A gap in the data - a
  /// reading the ECU did not send - is a `null`, so the line breaks there
  /// rather than being drawn straight across it.
  List<Offset?> points() {
    final latest = history.latest;
    if (latest == null) return const [];
    final end = latest.timestamp;
    final start = end.subtract(window);
    final span = window.inMicroseconds.toDouble();

    final result = <Offset?>[];
    for (final sample in history.samples) {
      if (sample.timestamp.isBefore(start)) continue;
      final value = sample[spec.channel];
      if (value == null) {
        result.add(null);
        continue;
      }
      final x = sample.timestamp.difference(start).inMicroseconds / span;
      result.add(Offset(x, 1 - spec.fractionFor(value)));
    }
    return result;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final hairline = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas
      ..drawLine(Offset.zero, Offset(size.width, 0), hairline)
      ..drawLine(
        Offset(0, size.height),
        Offset(size.width, size.height),
        hairline,
      );

    _label(canvas, spec.formatLabel(spec.max), const Offset(2, 1));
    _label(
      canvas,
      spec.formatLabel(spec.min),
      Offset(2, size.height - (labelStyle?.fontSize ?? 11) - 3),
    );

    final trace = Paint()
      ..color = line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path? path;
    for (final point in points()) {
      if (point == null) {
        if (path != null) canvas.drawPath(path, trace);
        path = null;
        continue;
      }
      final at = Offset(point.dx * size.width, point.dy * size.height);
      if (path == null) {
        path = Path()..moveTo(at.dx, at.dy);
      } else {
        path.lineTo(at.dx, at.dy);
      }
    }
    if (path != null) canvas.drawPath(path, trace);
  }

  void _label(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: (labelStyle ?? const TextStyle(fontSize: 11)).copyWith(
          color: label,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(LanePainter old) =>
      old.spec != spec || old.window != window || old.line != line;
}
