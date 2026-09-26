import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'gauge_appearance.dart';
import 'gauge_status.dart';
import 'meter_gauge.dart' show AlarmBadge, alarmRanges;

/// A reading as a filled bar - horizontal or vertical, whichever its space is.
///
/// A meter: the fill carries the state, and the unfilled track is a light step
/// of the same colour, so a bar in warning reads amber end to end rather than
/// as a small amber sliver on grey. The state is never the colour alone - an
/// alarm also shows its icon and word.
///
/// [look] can fix which way it runs, its thickness, split it into blocks and
/// mark its alarms along it. See [BarLook].
class BarGauge extends StatelessWidget {
  const BarGauge({
    super.key,
    required this.spec,
    required this.value,
    this.look = GaugeAppearance.builtIn,
  });

  final GaugeSpec spec;
  final double? value;
  final GaugeAppearance look;

  /// The least height an upright bar is laid out at.
  static const _uprightHeight = 96.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bar = look.bar.resolved;
    final colours = look.colours;
    final status = spec.statusFor(value);
    final accent = colours.forStatus(status, normal: scheme.onSurface);
    final caption = theme.textTheme.labelSmall?.copyWith(
      color: colours.captionOn(scheme),
    );

    final content = Semantics(
      label:
          '${spec.label}: ${spec.format(value)} ${spec.units}'
          '${status.isAlarm ? ', ${StatusPalette.labelFor(status)}' : ''}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final vertical = switch (bar.orientation) {
            BarOrientation.auto => constraints.maxHeight > constraints.maxWidth,
            BarOrientation.horizontal => false,
            BarOrientation.vertical => true,
          };

          final heading = Text(
            spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: caption,
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
                  color: colours.textOn(scheme),
                ),
              ),
              if (spec.units.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(spec.units, style: caption),
              ],
            ],
          );
          final painted = CustomPaint(
            painter: BarPainter(
              fraction: spec.fractionFor(value),
              vertical: vertical,
              fill: accent,
              track: colours.track,
              hasValue: value != null,
              segmented: bar.segmented,
              alarms: bar.alarms,
              ranges: bar.alarms == AlarmMarks.none
                  ? const []
                  : alarmRanges(spec, colours),
            ),
          );

          if (vertical) {
            final column = Column(
              children: [
                heading,
                const SizedBox(height: 4),
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: switch (bar.thickness) {
                        Thickness.thin => 10,
                        Thickness.regular => 20,
                        Thickness.bold => 32,
                      },
                      child: painted,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                FittedBox(child: reading),
                if (status.isAlarm)
                  FittedBox(
                    child: AlarmBadge(status: status, colours: colours),
                  ),
              ],
            );
            // Upright in a space too short for its caption, reading and a
            // bar between them - one set upright on purpose - it is laid
            // out at a height that holds them, and shrunk whole.
            if (constraints.maxHeight >= _uprightHeight) return column;
            return FittedBox(
              child: SizedBox(
                width: constraints.maxWidth,
                height: _uprightHeight,
                child: column,
              ),
            );
          }

          // At its own height, shrunk whole only if that is more than the
          // space has: a thick bar set across a short space.
          return FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
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
                                AlarmBadge(status: status, colours: colours),
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
                  SizedBox(
                    height: switch (bar.thickness) {
                      Thickness.thin => 6,
                      Thickness.regular => 12,
                      Thickness.bold => 20,
                    },
                    child: painted,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    final background = colours.background;
    if (background == null) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(padding: const EdgeInsets.all(4), child: content),
    );
  }
}

/// Draws a bar: its track, any alarm marks, and the fill.
@visibleForTesting
class BarPainter extends CustomPainter {
  BarPainter({
    required this.fraction,
    required this.vertical,
    required this.fill,
    required this.hasValue,
    this.track,
    this.segmented = false,
    this.alarms = AlarmMarks.none,
    this.ranges = const [],
  });

  final double fraction;
  final bool vertical;
  final Color fill;
  final bool hasValue;

  /// The unfilled part. Left `null`, a light step of [fill].
  final Color? track;

  /// Whether it fills in blocks rather than one run.
  final bool segmented;

  final AlarmMarks alarms;

  /// Where the gauge alarms along the bar, from 0 to 1, and in what colour.
  final List<(double, double, Color)> ranges;

  /// Round at the data end only; the baseline end stays square.
  static const _radius = Radius.circular(4);

  Color get _track => track ?? fill.withValues(alpha: 0.18);

  /// The part of the bar from [from] to [to] of the way along it.
  Rect _span(Size size, double from, double to) => vertical
      ? Rect.fromLTRB(
          0,
          size.height * (1 - to),
          size.width,
          size.height * (1 - from),
        )
      : Rect.fromLTRB(size.width * from, 0, size.width * to, size.height);

  /// The colour an unfilled stretch at [at] is tinted, where it lies in an
  /// alarm range. Danger comes after warning, so it wins where they overlap.
  Color? _alarmAt(double at) {
    if (alarms != AlarmMarks.bands) return null;
    Color? colour;
    for (final (from, to, color) in ranges) {
      if (at >= from && at <= to) colour = color;
    }
    return colour?.withValues(alpha: 0.4);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (segmented) {
      _paintBlocks(canvas, size);
    } else {
      _paintRun(canvas, size);
    }

    if (alarms == AlarmMarks.ticks) {
      final mark = Paint()..strokeWidth = 2;
      final ends = {
        for (final (from, to, color) in ranges) ...{
          if (from > 0) from: color,
          if (to < 1) to: color,
        },
      };
      for (final MapEntry(key: at, value: color) in ends.entries) {
        mark.color = color;
        final line = _span(size, at, at);
        canvas.drawLine(line.topLeft, line.bottomRight, mark);
      }
    }
  }

  void _paintRun(Canvas canvas, Size size) {
    final whole = RRect.fromRectAndRadius(Offset.zero & size, _radius);
    canvas.drawRRect(whole, Paint()..color = _track);
    if (alarms == AlarmMarks.bands) {
      canvas
        ..save()
        ..clipRRect(whole);
      for (final (from, to, color) in ranges) {
        canvas.drawRect(
          _span(size, from, to),
          Paint()..color = color.withValues(alpha: 0.4),
        );
      }
      canvas.restore();
    }
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

  void _paintBlocks(Canvas canvas, Size size) {
    final length = vertical ? size.height : size.width;
    final breadth = vertical ? size.width : size.height;
    // Blocks a little longer than the bar is thick, and a gap between each.
    final count = (length / (breadth * 0.9 + 3)).floor().clamp(4, 40);
    final gap = (length / count) * 0.25;
    final lit = Paint()..color = fill;
    for (var i = 0; i < count; i++) {
      final from = i / count;
      final to = (i + 1) / count;
      final middle = (from + to) / 2;
      final rect = _span(size, from, to);
      final block = vertical
          ? Rect.fromLTRB(
              rect.left,
              rect.top + gap / 2,
              rect.right,
              rect.bottom - gap / 2,
            )
          : Rect.fromLTRB(
              rect.left + gap / 2,
              rect.top,
              rect.right - gap / 2,
              rect.bottom,
            );
      final on = hasValue && fraction > 0 && middle <= fraction;
      canvas.drawRRect(
        RRect.fromRectAndRadius(block, const Radius.circular(2)),
        on ? lit : (Paint()..color = _alarmAt(middle) ?? _track),
      );
    }
  }

  @override
  bool shouldRepaint(BarPainter old) =>
      old.fraction != fraction ||
      old.vertical != vertical ||
      old.fill != fill ||
      old.hasValue != hasValue ||
      old.track != track ||
      old.segmented != segmented ||
      old.alarms != alarms ||
      !listEquals(old.ranges, ranges);
}
