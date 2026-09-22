import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dashboard_controller.dart';
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

    // Not rebuilt per sample: the traces repaint from the history, and each
    // lane's reading follows the feed on its own.
    return Column(
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LaneHeader(spec: spec),
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
    );
  }
}

/// A lane's name and its current reading - rebuilt when the reading changes,
/// apart from the trace below it.
class _LaneHeader extends ConsumerWidget {
  const _LaneHeader({required this.spec});

  final GaugeSpec spec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = watchWhileVisible(
      ref,
      context,
      realtimeProvider.select((live) => live.valueOrNull?[spec.channel]),
    );
    final status = spec.statusFor(current);

    return Semantics(
      label: '${spec.label}: ${spec.format(current)} ${spec.units}',
      child: Row(
        children: [
          Expanded(
            child: Text(
              spec.units.isEmpty ? spec.label : '${spec.label} (${spec.units})',
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
  List<Offset?> points() => _trace().points;

  /// What the lane's height stands for, bottom to top.
  ///
  /// The gauge's range where it has one. A channel with no declared range is
  /// fitted to the readings in view instead - a made-up fixed scale would
  /// either flatten the trace or run it off the lane.
  ({double min, double max}) scale() => _trace().scale;

  /// The points and the scale, from one pass over the samples in the window.
  ({List<Offset?> points, ({double min, double max}) scale}) _trace() {
    final latest = history.latest;
    if (latest == null) return (points: const [], scale: _scaleFor(null, null));
    final start = latest.timestamp.subtract(window);
    final span = window.inMicroseconds.toDouble();

    final times = <double>[];
    final values = <double?>[];
    double? low;
    double? high;
    for (final sample in history.since(start)) {
      final value = sample[spec.channel];
      times.add(sample.timestamp.difference(start).inMicroseconds / span);
      values.add(value);
      if (value == null) continue;
      if (low == null || value < low) low = value;
      if (high == null || value > high) high = value;
    }

    final scale = _scaleFor(low, high);
    final (:min, :max) = scale;
    return (
      points: [
        for (var i = 0; i < times.length; i++)
          if (values[i] case final value?)
            Offset(times[i], 1 - ((value - min) / (max - min)).clamp(0.0, 1.0))
          else
            null,
      ],
      scale: scale,
    );
  }

  ({double min, double max}) _scaleFor(double? low, double? high) {
    if (spec.hasRange) return (min: spec.min, max: spec.max);
    if (low == null || high == null) return (min: 0, max: 1);
    // A flat trace still needs a span; centre it.
    if (high - low < 1e-9) {
      final pad = low.abs() < 1 ? 1.0 : low.abs() * 0.1;
      return (min: low - pad, max: high + pad);
    }
    return (min: low, max: high);
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

    final (:points, :scale) = _trace();
    final (:min, :max) = scale;
    _label(canvas, spec.formatLabel(max), const Offset(2, 1));
    _label(
      canvas,
      spec.formatLabel(min),
      Offset(2, size.height - (labelStyle?.fontSize ?? 11) - 3),
    );

    final trace = Paint()
      ..color = line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    Path? path;
    for (final point in decimate(points, size.width.ceil())) {
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

  /// Scale labels, laid out once and kept: on a fixed range they never
  /// change, and a fitted one changes far less often than the lane repaints.
  final _labels = <String, TextPainter>{};

  void _label(Canvas canvas, String text, Offset at) {
    if (_labels.length > 16) {
      for (final painter in _labels.values) {
        painter.dispose();
      }
      _labels.clear();
    }
    final painter = _labels[text] ??= TextPainter(
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

/// [points] thinned to at most two per column of a lane [columns] pixels
/// wide: the highest and the lowest in each column, in the order they came.
///
/// A 60 s lane holds some 1,800 samples but is a few hundred pixels wide, so
/// most of its points land on a pixel already drawn - and were stroked all the
/// same, every frame. Keeping each column's extremes draws the same picture: a
/// spike one sample wide still reaches its peak. A gap (`null`) stays a gap.
@visibleForTesting
List<Offset?> decimate(List<Offset?> points, int columns) {
  if (columns <= 0 || points.length <= columns * 2) return points;

  final result = <Offset?>[];
  int? column;
  Offset? top;
  Offset? bottom;
  var topAt = 0;
  var bottomAt = 0;

  void flush() {
    final (first, second) = topAt <= bottomAt ? (top, bottom) : (bottom, top);
    if (first != null) result.add(first);
    if (second != null && !identical(second, first)) result.add(second);
    top = null;
    bottom = null;
  }

  for (var i = 0; i < points.length; i++) {
    final point = points[i];
    if (point == null) {
      flush();
      column = null;
      if (result.isNotEmpty && result.last != null) result.add(null);
      continue;
    }
    final at = (point.dx * columns).floor().clamp(0, columns - 1);
    if (at != column) {
      flush();
      column = at;
    }
    if (top == null || point.dy < top!.dy) {
      top = point;
      topAt = i;
    }
    if (bottom == null || point.dy > bottom!.dy) {
      bottom = point;
      bottomAt = i;
    }
  }
  flush();
  return result;
}
