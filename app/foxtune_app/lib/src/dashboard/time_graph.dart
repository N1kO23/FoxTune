import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../motion/motion.dart';
import '../motion/readout_text.dart';
import 'dashboard_controller.dart';
import 'gauge_appearance.dart';
import 'gauge_status.dart';
import 'meter_gauge.dart' show AlarmBadge, alarmRanges;
import 'sample_history.dart';

/// Recent history of one to four channels, one lane each, sharing a time axis.
///
/// Lanes rather than lines overlaid on one plot: RPM runs to thousands and AFR
/// to fifteen, so overlaying them means either flattening one or giving each
/// line its own scale on the same axis - and then how high a line sits means
/// something different for every line. A lane per channel keeps each scale
/// honest and the times lined up, which is what comparing them needs.
///
/// [look] sets the trace's weight and colour, shades under it, and marks
/// where each lane alarms. See [GraphLook].
class TimeGraph extends StatelessWidget {
  const TimeGraph({
    super.key,
    required this.lanes,
    required this.history,
    required this.window,
    this.look = GaugeAppearance.builtIn,
    this.readings,
  });

  /// What each lane shows, top to bottom.
  final List<GaugeSpec> lanes;

  final SampleHistory history;

  /// How much history is shown.
  final Duration window;

  final GaugeAppearance look;

  /// Readings shown in the lanes' headings by channel, in place of the live
  /// feed's: for a preview, which has no ECU behind it.
  final Map<String, double>? readings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: look.colours.captionOn(scheme),
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    // Not rebuilt per sample: the traces repaint from the history, and each
    // lane's reading follows the feed on its own.
    Widget graphTo(ValueListenable<DateTime?>? edge) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final spec in lanes)
          Expanded(
            child: _Lane(
              spec: spec,
              history: history,
              window: window,
              edge: edge,
              look: look,
              readings: readings,
            ),
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

    // With live motion, the traces scroll on between samples rather than
    // stepping with each one.
    final graph = Motion.of(context).liveData
        ? LiveEdge(history: history, builder: (context, edge) => graphTo(edge))
        : graphTo(null);

    final background = look.colours.background;
    if (background == null) return graph;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(padding: const EdgeInsets.all(4), child: graph),
    );
  }
}

class _Lane extends StatelessWidget {
  const _Lane({
    required this.spec,
    required this.history,
    required this.window,
    required this.edge,
    required this.look,
    required this.readings,
  });

  final GaugeSpec spec;
  final SampleHistory history;
  final Duration window;
  final ValueListenable<DateTime?>? edge;
  final GaugeAppearance look;
  final Map<String, double>? readings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final graph = look.graph.resolved;
    final colours = look.colours;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _LaneHeader(spec: spec, colours: colours, readings: readings),
        Expanded(
          child: CustomPaint(
            painter: LanePainter(
              spec: spec,
              history: history,
              window: window,
              edge: edge,
              line: colours.normal ?? scheme.primary,
              grid: colours.track ?? scheme.outlineVariant,
              label: colours.captionOn(scheme),
              labelStyle: theme.textTheme.labelSmall,
              lineWidth: switch (graph.thickness) {
                Thickness.thin => 1,
                Thickness.regular => 2,
                Thickness.bold => 3.5,
              },
              fill: graph.fill,
              alarms: graph.alarms,
              // Where it alarms, on the gauge's own scale: a lane fitted to
              // its readings has no fixed place to mark them.
              ranges: graph.alarms == AlarmMarks.none || !spec.hasRange
                  ? const []
                  : alarmRanges(spec, colours),
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
  const _LaneHeader({
    required this.spec,
    required this.colours,
    required this.readings,
  });

  final GaugeSpec spec;
  final GaugeColours colours;
  final Map<String, double>? readings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = switch (readings) {
      final shown? => shown[spec.channel],
      null => watchWhileVisible(
        ref,
        context,
        liveProvider.select((live) => live?[spec.channel]),
      ),
    };
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
                color: colours.captionOn(scheme),
              ),
            ),
          ),
          if (status.isAlarm) ...[
            AlarmBadge(status: status, colours: colours),
            const SizedBox(width: 6),
          ],
          // The value sits where the line ends, in ink rather than in the
          // line's colour.
          ReadoutText(
            spec.format(current),
            maxLines: null,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: colours.textOn(scheme),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws one lane: hairline bounds, its scale's ends, any alarm marks, and
/// the trace.
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
    this.lineWidth = 2,
    this.fill = false,
    this.alarms = AlarmMarks.none,
    this.ranges = const [],
    this.edge,
  }) : super(
         repaint: edge == null ? history : Listenable.merge([history, edge]),
       );

  final GaugeSpec spec;
  final SampleHistory history;
  final Duration window;

  /// Where the window ends, while it scrolls on between samples - see
  /// [LiveEdge]. `null`, or holding `null`: at the newest sample.
  final ValueListenable<DateTime?>? edge;
  final Color line;
  final Color grid;
  final Color label;
  final TextStyle? labelStyle;
  final double lineWidth;

  /// Whether the area under the trace is shaded.
  final bool fill;

  final AlarmMarks alarms;

  /// Where the gauge alarms up the lane, from 0 at the bottom to 1 at the
  /// top, and in what colour.
  final List<(double, double, Color)> ranges;

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
    final (:column, :first, :stop, :scale) = _window();
    if (column == null) return (points: const [], scale: scale);
    final points = <Offset?>[];
    _plot(column, first, stop, scale, points.add);
    return (points: points, scale: scale);
  }

  /// The readings in view: [first] up to [stop] in [column], and the scale
  /// they are drawn on - from the channel's column, decoded once as each
  /// sample arrived, rather than from the samples on every frame.
  ({
    SampleColumn? column,
    int first,
    int stop,
    ({double min, double max}) scale,
  })
  _window() {
    final latest = history.latest;
    if (latest == null) {
      return (column: null, first: 0, stop: 0, scale: _scaleFor(null, null));
    }
    final column = history.column(spec.channel);
    final end = (edge?.value ?? latest.timestamp).microsecondsSinceEpoch
        .toDouble();
    final first = column.indexAtOrAfter(end - window.inMicroseconds);
    // A window scrolling on ends a little short of the newest sample: the
    // first one past its end is kept, for the trace to run off the edge to,
    // and no more.
    final past = column.indexAtOrAfter(end + 1);
    final stop = past < column.length ? past + 1 : past;

    double? low;
    double? high;
    if (!spec.hasRange) {
      for (var i = first; i < stop; i++) {
        final value = column.valueAt(i);
        if (value.isNaN) continue;
        if (low == null || value < low) low = value;
        if (high == null || value > high) high = value;
      }
    }
    return (
      column: column,
      first: first,
      stop: stop,
      scale: _scaleFor(low, high),
    );
  }

  /// What [paint] draws in [size]: the readings in view, thinned to two a
  /// pixel column - as [decimate] would thin [points], without making that
  /// list first.
  @visibleForTesting
  List<Offset?> pointsDrawn(Size size) => _drawn(_window(), size);

  List<Offset?> _drawn(
    ({
      SampleColumn? column,
      int first,
      int stop,
      ({double min, double max}) scale,
    })
    inView,
    Size size,
  ) {
    final (:column, :first, :stop, :scale) = inView;
    if (column == null) return const [];
    final columns = size.width.ceil();
    if (columns <= 0 || stop - first <= columns * 2) {
      final all = <Offset?>[];
      _plot(column, first, stop, scale, all.add);
      return all;
    }
    final thinned = _Decimator(columns);
    _plot(column, first, stop, scale, thinned.add);
    return thinned.finish();
  }

  /// Hands each reading from [first] up to [stop] to [point], as a fraction
  /// of the lane: `null` for a gap.
  void _plot(
    SampleColumn column,
    int first,
    int stop,
    ({double min, double max}) scale,
    void Function(Offset? point) point,
  ) {
    final (:min, :max) = scale;
    final span = window.inMicroseconds.toDouble();
    final start =
        (edge?.value ?? history.latest!.timestamp).microsecondsSinceEpoch -
        window.inMicroseconds;
    for (var i = first; i < stop; i++) {
      final value = column.valueAt(i);
      point(
        value.isNaN
            ? null
            : Offset(
                (column.timeAt(i) - start) / span,
                1 - ((value - min) / (max - min)).clamp(0.0, 1.0),
              ),
      );
    }
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
    // The trace can run past the edge of a window that scrolls on.
    canvas.clipRect(Offset.zero & size);
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

    _paintAlarms(canvas, size);

    final inView = _window();
    final drawn = _drawn(inView, size);
    final (:min, :max) = inView.scale;
    _label(canvas, spec.formatLabel(max), const Offset(2, 1));
    _label(
      canvas,
      spec.formatLabel(min),
      Offset(2, size.height - (labelStyle?.fontSize ?? 11) - 3),
    );

    final trace = Paint()
      ..color = line
      ..strokeWidth = lineWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shade = Paint()..color = line.withValues(alpha: 0.15);

    Path? path;
    Offset? first;
    Offset? last;
    void finish() {
      if (path == null) return;
      if (fill) {
        // Down to the floor and back, under this run of the trace alone.
        final under = Path.from(path!)
          ..lineTo(last!.dx, size.height)
          ..lineTo(first!.dx, size.height)
          ..close();
        canvas.drawPath(under, shade);
      }
      canvas.drawPath(path!, trace);
      path = null;
    }

    for (final point in drawn) {
      if (point == null) {
        finish();
        continue;
      }
      final at = Offset(point.dx * size.width, point.dy * size.height);
      if (path == null) {
        path = Path()..moveTo(at.dx, at.dy);
        first = at;
      } else {
        path!.lineTo(at.dx, at.dy);
      }
      last = at;
    }
    finish();
  }

  /// Shades each range the gauge alarms in, or rules a dashed line where
  /// each starts.
  void _paintAlarms(Canvas canvas, Size size) {
    double y(double fraction) => size.height * (1 - fraction);
    switch (alarms) {
      case AlarmMarks.none:
        return;
      case AlarmMarks.bands:
        for (final (from, to, color) in ranges) {
          canvas.drawRect(
            Rect.fromLTRB(0, y(to), size.width, y(from)),
            Paint()..color = color.withValues(alpha: 0.15),
          );
        }
      case AlarmMarks.ticks:
        final dash = Paint()..strokeWidth = 1;
        for (final (from, to, color) in ranges) {
          dash.color = color.withValues(alpha: 0.8);
          for (final at in [if (from > 0) from, if (to < 1) to]) {
            for (var x = 0.0; x < size.width; x += 6) {
              canvas.drawLine(Offset(x, y(at)), Offset(x + 3, y(at)), dash);
            }
          }
        }
    }
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
      old.spec != spec ||
      old.window != window ||
      old.line != line ||
      old.grid != grid ||
      old.label != label ||
      old.lineWidth != lineWidth ||
      old.fill != fill ||
      old.alarms != alarms ||
      old.edge != edge ||
      !listEquals(old.ranges, ranges);
}

/// Where a graph's window ends while samples are coming in: run on from the
/// newest by the time since it arrived, a sample's interval behind it - so
/// the traces scroll smoothly rather than stepping with each sample.
///
/// With samples arriving evenly, the window's end reaches each one just as
/// the next arrives, and the scroll never stops or jumps. A late sample holds
/// the window at the newest one, and when samples stop coming, so does the
/// scrolling - a stalled feed is not scrolled away.
///
/// The interval is measured from the samples themselves, so a slow link that
/// manages less than the rate asked for still scrolls evenly. Arrival is timed
/// by [clock], so it works whatever clock the samples' timestamps were taken
/// by.
@visibleForTesting
class LiveEdge extends StatefulWidget {
  const LiveEdge({
    super.key,
    required this.history,
    required this.builder,
    this.clock = DateTime.now,
  });

  final SampleHistory history;
  final Widget Function(BuildContext context, ValueListenable<DateTime?> edge)
  builder;
  final DateTime Function() clock;

  @override
  State<LiveEdge> createState() => _LiveEdgeState();
}

class _LiveEdgeState extends State<LiveEdge>
    with SingleTickerProviderStateMixin {
  final _edge = ValueNotifier<DateTime?>(null);
  late final Ticker _ticker = createTicker((_) => _advance());

  DateTime? _latest;
  DateTime? _arrived;
  Duration _interval = const Duration(milliseconds: 33);

  @override
  void initState() {
    super.initState();
    widget.history.addListener(_onSample);
  }

  @override
  void didUpdateWidget(LiveEdge old) {
    super.didUpdateWidget(old);
    if (old.history == widget.history) return;
    old.history.removeListener(_onSample);
    widget.history.addListener(_onSample);
    _latest = null;
    _arrived = null;
    _edge.value = null;
  }

  @override
  void dispose() {
    widget.history.removeListener(_onSample);
    _ticker.dispose();
    _edge.dispose();
    super.dispose();
  }

  void _onSample() {
    final latest = widget.history.latest?.timestamp;
    if (latest == null || latest == _latest) return;
    if (_latest case final previous?) {
      final gap = latest.difference(previous);
      // A gap of a second or more is a pause, not the rate.
      if (gap > Duration.zero && gap < const Duration(seconds: 1)) {
        _interval = _interval * 0.8 + gap * 0.2;
      }
    }
    _latest = latest;
    _arrived = widget.clock();
    _advance();
    if (!_ticker.isActive) _ticker.start();
  }

  void _advance() {
    final latest = _latest;
    final arrived = _arrived;
    if (latest == null || arrived == null) return;
    final since = widget.clock().difference(arrived);
    final lead = since < _interval ? since : _interval;
    _edge.value = latest.add(lead - _interval);
    if (since > _interval * 3) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _edge);
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
  final thinned = _Decimator(columns);
  points.forEach(thinned.add);
  return thinned.finish();
}

/// [decimate], a point at a time - so a lane can thin its readings as it
/// plots them, without a list of every one first.
class _Decimator {
  _Decimator(this.columns);

  final int columns;
  final _result = <Offset?>[];

  int? _column;
  Offset? _top;
  Offset? _bottom;
  var _topAt = 0;
  var _bottomAt = 0;
  var _index = 0;

  void add(Offset? point) {
    final index = _index++;
    if (point == null) {
      _flush();
      _column = null;
      if (_result.isNotEmpty && _result.last != null) _result.add(null);
      return;
    }
    final at = (point.dx * columns).floor().clamp(0, columns - 1);
    if (at != _column) {
      _flush();
      _column = at;
    }
    if (_top == null || point.dy < _top!.dy) {
      _top = point;
      _topAt = index;
    }
    if (_bottom == null || point.dy > _bottom!.dy) {
      _bottom = point;
      _bottomAt = index;
    }
  }

  void _flush() {
    final (first, second) = _topAt <= _bottomAt
        ? (_top, _bottom)
        : (_bottom, _top);
    if (first != null) _result.add(first);
    if (second != null && !identical(second, first)) _result.add(second);
    _top = null;
    _bottom = null;
  }

  /// The points kept, once every point has been added.
  List<Offset?> finish() {
    _flush();
    return _result;
  }
}
