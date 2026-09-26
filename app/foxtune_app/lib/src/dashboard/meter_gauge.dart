import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'gauge_appearance.dart';
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
///
/// [look] can change its face to a needle, how far round its scale runs, what
/// is marked along it and its colours. See [DialLook].
class MeterGauge extends StatelessWidget {
  const MeterGauge({
    super.key,
    required this.spec,
    required this.value,
    this.look = GaugeAppearance.builtIn,
  });

  final GaugeSpec spec;
  final double? value;
  final GaugeAppearance look;

  /// Where the text of a dial laid out in [size] and drawn as [dial] may go:
  /// within `clear` of `centre`, clear of the track and anything marked along
  /// it.
  @visibleForTesting
  static ({Offset centre, double clear}) textRoom(Size size, DialLook dial) {
    final geometry = _DialGeometry.of(size, dial);
    return (centre: geometry.centre, clear: geometry.clear);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dial = look.dial.resolved;
    final colours = look.colours;
    final status = spec.statusFor(value);
    final needle = dial.face == DialFace.needle;
    final accent = colours.forStatus(status, normal: scheme.onSurface);
    final shown = _DialValuePainter(
      look: look.dial,
      fraction: spec.fractionFor(value),
      color: accent,
      hasValue: value != null,
    );
    final caption = theme.textTheme.labelSmall?.copyWith(
      color: colours.captionOn(scheme),
    );

    // One line of text, shrunk to the width it is given if it needs to be.
    Widget line(Widget child) => FittedBox(fit: BoxFit.scaleDown, child: child);

    final title = line(Text(spec.label, maxLines: 1, style: caption));
    // The value wears a text token, not the status colour; the arc and the
    // badge carry the state.
    final number = Text(
      spec.format(value),
      maxLines: 1,
      style: theme.textTheme.titleLarge?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: FontWeight.w600,
        color: colours.textOn(scheme),
      ),
    );
    final units = Text(spec.units, maxLines: 1, style: caption);
    // Where a scale or a needle leaves the text little room, the units share
    // the number's line rather than taking one of their own - which would
    // shrink the number with them.
    final compact = needle || dial.scale != ScaleMarks.none;
    final reading = [
      if (compact && spec.units.isNotEmpty)
        line(
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [number, const SizedBox(width: 3), units],
          ),
        )
      else ...[
        line(number),
        if (spec.units.isNotEmpty) line(units),
      ],
      if (status.isAlarm) ...[
        const SizedBox(height: 2),
        line(AlarmBadge(status: status, colours: colours)),
      ],
    ];

    // A block of text [width] wide, shrunk as a whole to fit [height].
    Widget block(double width, double height, List<Widget> children) =>
        SizedBox(
          width: width,
          height: height,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: width,
              child: Column(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        );

    return Semantics(
      label:
          '${spec.label}: ${spec.format(value)} ${spec.units}'
          '${status.isAlarm ? ', ${StatusPalette.labelFor(status)}' : ''}',
      child: AspectRatio(
        aspectRatio: _DialGeometry.aspectFor(dial.sweep),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The scale changes only with the limits, not with the reading:
            // its own layer, so its numbers are not set again every sample.
            RepaintBoundary(
              child: CustomPaint(
                painter: _DialFacePainter(
                  look: look.dial,
                  scale: _scale(dial.scale),
                  warnAbove: _fraction(spec.warnAbove),
                  dangerAbove: _fraction(spec.dangerAbove),
                  warnBelow: _fraction(spec.warnBelow),
                  dangerBelow: _fraction(spec.dangerBelow),
                  // A needle is a thin line to carry an alarm alone: the whole
                  // scale takes on its colour with it.
                  trackColor: needle && status.isAlarm
                      ? accent
                      : colours.track ??
                            (needle
                                ? scheme.outline
                                : scheme.surfaceContainerHighest),
                  tickColor: colours.captionOn(scheme),
                  warnColor: colours.warningColour,
                  dangerColor: colours.dangerColour,
                  background: colours.background,
                  labelStyle: caption,
                ),
              ),
            ),
            // A band runs round the track, under the text; a needle crosses
            // the middle, over it.
            CustomPaint(
              painter: needle ? null : shown,
              foregroundPainter: needle ? shown : null,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final geometry = _DialGeometry.of(
                    constraints.biggest,
                    look.dial,
                  );
                  final inner = geometry.clear;
                  final centre = geometry.centre;
                  if (!needle) {
                    // The largest box that sits clear of the arc: its corners
                    // lie just inside the inner edge of the track.
                    return Stack(
                      children: [
                        Positioned(
                          left: centre.dx - inner * 0.75,
                          top: centre.dy - inner * 0.65,
                          child: block(inner * 1.5, inner * 1.3, [
                            title,
                            ...reading,
                          ]),
                        ),
                      ],
                    );
                  }
                  // A needle sweeps the middle: the caption above its hub, the
                  // reading below it, where the scale is open.
                  final hub = geometry.hub * 1.3;
                  final below = math.min(inner * 0.78, geometry.floor * 0.95);
                  return Stack(
                    children: [
                      Positioned(
                        left: centre.dx - inner * 0.65,
                        top: centre.dy - inner * 0.62,
                        child: block(inner * 1.3, inner * 0.62 - hub, [title]),
                      ),
                      Positioned(
                        left: centre.dx - inner * 0.6,
                        top: centre.dy + hub,
                        child: block(inner * 1.2, below - hub, reading),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  double? _fraction(double? limit) =>
      limit == null ? null : spec.fractionFor(limit);

  /// What is marked along the scale, each where it sits from 0 to 1.
  ///
  /// Round steps where the gauge has a range. Where it has none, even tenths:
  /// they still read as a scale, without numbers claiming a range it does
  /// not have.
  _Scale _scale(ScaleMarks marks) {
    if (marks == ScaleMarks.none) return const _Scale();
    if (!spec.hasRange) {
      return const _Scale(
        majors: [0, 0.2, 0.4, 0.6, 0.8, 1],
        minors: [0.1, 0.3, 0.5, 0.7, 0.9],
      );
    }
    final (:majors, :minors) = scaleDivisions(spec.min, spec.max);
    return _Scale(
      majors: [for (final at in majors) spec.fractionFor(at)],
      minors: [for (final at in minors) spec.fractionFor(at)],
      labels: [
        if (marks == ScaleMarks.numbers)
          for (final at in majors) (spec.fractionFor(at), spec.formatLabel(at)),
      ],
    );
  }
}

/// Where a scale from [min] to [max] is marked: major steps of a round size,
/// and minor steps between them.
///
/// Where a round step divides the range into a handful and meets both its
/// ends, those - so -40 to 120 is marked every 40, ends included. Otherwise
/// round steps within it - 1, 2 or 5 times a power of ten, about five of
/// them - and its ends go unmarked: 0 to 255 is marked every 50.
({List<double> majors, List<double> minors}) scaleDivisions(
  double min,
  double max,
) {
  if (!min.isFinite || !max.isFinite || !(max > min)) {
    return (majors: const [], minors: const []);
  }
  final span = max - min;

  bool meets(double value, double step) {
    final steps = value / step;
    return (steps - steps.round()).abs() < 1e-6;
  }

  var (step, parts) = (0.0, 0);
  for (final count in const [5, 4, 6, 8, 7, 3]) {
    final even = span / count;
    if (_partsOf(even) case final split? when meets(min, even)) {
      (step, parts) = (even, split);
      break;
    }
  }
  if (parts == 0) {
    final raw = span / 5;
    final magnitude = math
        .pow(10, (math.log(raw) / math.ln10).floor())
        .toDouble();
    final normal = raw / magnitude;
    step =
        (normal < 1.5 ? 1 : (normal < 3 ? 2 : (normal < 7 ? 5 : 10))) *
        magnitude;
    parts = _partsOf(step)!;
  }

  final minorStep = step / parts;
  final majors = <double>[];
  final minors = <double>[];
  // Counted in minor steps from zero, so every major lands on a multiple of
  // the major step whatever the range starts at.
  for (
    var i = (min / minorStep - 1e-6).ceil();
    i * minorStep <= max + minorStep * 1e-6;
    i++
  ) {
    // Snapped, so 0.30000000000000004 is written 0.3.
    final value = double.parse((i * minorStep).toStringAsPrecision(12));
    (i % parts == 0 ? majors : minors).add(value);
  }
  return (majors: majors, minors: minors);
}

/// How many minor steps a major [step] splits into, or `null` where it is not
/// a round number.
int? _partsOf(double step) {
  final magnitude = math
      .pow(10, (math.log(step) / math.ln10).floor())
      .toDouble();
  final normal = step / magnitude;
  for (final (round, parts) in const [
    (1.0, 5),
    (1.5, 3),
    (2.0, 4),
    (2.5, 5),
    (3.0, 3),
    (4.0, 4),
    (5.0, 5),
    (6.0, 3),
    (8.0, 4),
    (10.0, 5),
  ]) {
    if ((normal - round).abs() < 1e-6) return parts;
  }
  return null;
}

/// Icon plus text, so an alarm is never signalled by colour alone.
///
/// Shared by every gauge style, so a warning looks the same on a dial, a bar
/// and a graph - in the gauge's own alarm [colours], where it has them.
class AlarmBadge extends StatelessWidget {
  const AlarmBadge({
    super.key,
    required this.status,
    this.colours = const GaugeColours(),
  });

  final GaugeStatus status;
  final GaugeColours colours;

  @override
  Widget build(BuildContext context) {
    final color = status == GaugeStatus.danger
        ? colours.dangerColour
        : colours.warningColour;
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

/// The marks along a dial's scale, each where it sits from 0 to 1.
@immutable
class _Scale {
  const _Scale({
    this.majors = const [],
    this.minors = const [],
    this.labels = const [],
  });

  final List<double> majors;
  final List<double> minors;

  /// The numbers, where it has them.
  final List<(double, String)> labels;

  @override
  bool operator ==(Object other) =>
      other is _Scale &&
      listEquals(other.majors, majors) &&
      listEquals(other.minors, minors) &&
      listEquals(other.labels, labels);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(majors),
    Object.hashAll(minors),
    Object.hashAll(labels),
  );
}

/// Where the parts of a dial are drawn, in a space [size].
class _DialGeometry {
  _DialGeometry._({
    required this.side,
    required this.centre,
    required this.aspect,
    required this.face,
    required this.thickness,
    required this.scale,
    required this.sweepAngle,
  });

  factory _DialGeometry.of(Size size, DialLook look) {
    final dial = look.resolved;
    final aspect = aspectFor(dial.sweep);
    final side = math.min(size.width, size.height * aspect);
    return _DialGeometry._(
      side: side,
      // The dial's box, centred in the space; the circle's centre, half its
      // width down from the box's top.
      centre: Offset(
        size.width / 2,
        (size.height - side / aspect) / 2 + side / 2,
      ),
      aspect: aspect,
      face: dial.face,
      thickness: dial.thickness,
      scale: dial.scale,
      sweepAngle: dial.sweep * math.pi / 180,
    );
  }

  /// How much wider than tall a dial of [sweep] degrees is laid out.
  ///
  /// One whose scale leaves the lower half of the circle empty is laid out
  /// low and wide, rather than in a square it would fill the top of: room
  /// under its centre for the reading, and no more.
  static double aspectFor(int sweep) => sweep <= 180 ? 1.25 : 1;

  /// How much wider than tall its box is. See [aspectFor].
  final double aspect;

  /// How far across the dial is: the width of its box.
  final double side;

  /// How far below the centre the dial's box reaches.
  double get floor => side / aspect - side / 2;

  /// The middle of its space, which it is centred on.
  final Offset centre;

  final DialFace face;
  final Thickness thickness;
  final ScaleMarks scale;

  /// How far round the scale runs, in radians.
  final double sweepAngle;

  /// Where the scale starts: its gap is centred on the bottom.
  double get startAngle => math.pi / 2 + (2 * math.pi - sweepAngle) / 2;

  /// The track's width. A needle's track is a line; the needle carries the
  /// reading.
  double get stroke =>
      side *
      switch ((face, thickness)) {
        (DialFace.arc, Thickness.thin) => 0.05,
        (DialFace.arc, Thickness.regular) => 0.085,
        (DialFace.arc, Thickness.bold) => 0.13,
        (DialFace.needle, Thickness.thin) => 0.012,
        (DialFace.needle, Thickness.regular) => 0.02,
        (DialFace.needle, Thickness.bold) => 0.032,
      };

  /// The radius the track is drawn along, through the middle of its width.
  double get radius => (side - stroke) / 2 - 2;

  /// The inner edge of the track, where scale ticks start.
  double get trackInner => radius - stroke / 2;

  double get majorTick => side * 0.055;
  double get minorTick => side * 0.03;

  double get numberSize => side * 0.06;

  /// Half the reach of a scale number from its middle: enough for four
  /// figures.
  double get numberReach => numberSize * 1.25;

  /// The radius scale numbers are centred on.
  double get numberRadius =>
      trackInner - majorTick - side * 0.015 - numberReach;

  /// The needle's pivot.
  double get hub => side * 0.04;

  /// How far from the centre text may reach.
  double get clear => switch (scale) {
    ScaleMarks.none => trackInner,
    ScaleMarks.ticks => trackInner - majorTick,
    ScaleMarks.numbers => numberRadius - numberReach,
  };

  Rect get rect => Rect.fromCircle(center: centre, radius: radius);

  double angleAt(double fraction) => startAngle + sweepAngle * fraction;
}

/// The parts of a dial that do not move with the reading: its background,
/// track, alarm marks and scale.
class _DialFacePainter extends CustomPainter {
  _DialFacePainter({
    required this.look,
    required this.scale,
    required this.warnAbove,
    required this.dangerAbove,
    required this.warnBelow,
    required this.dangerBelow,
    required this.trackColor,
    required this.tickColor,
    required this.warnColor,
    required this.dangerColor,
    required this.background,
    required this.labelStyle,
  });

  final DialLook look;
  final _Scale scale;

  /// Where the alarm points sit along the scale, from 0 to 1.
  final double? warnAbove;
  final double? dangerAbove;
  final double? warnBelow;
  final double? dangerBelow;

  final Color trackColor;
  final Color tickColor;
  final Color warnColor;
  final Color dangerColor;
  final Color? background;
  final TextStyle? labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = _DialGeometry.of(size, look);
    final dial = look.resolved;
    final stroke = geometry.stroke;
    final rect = geometry.rect;

    if (background case final fill?) {
      canvas.drawCircle(
        geometry.centre,
        geometry.radius + stroke / 2 + 1,
        Paint()..color = fill,
      );
    }

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(
      rect,
      geometry.startAngle,
      geometry.sweepAngle,
      false,
      track,
    );

    switch (dial.alarms) {
      case AlarmMarks.none:
        break;
      case AlarmMarks.ticks:
        // Threshold marks sit on the track so limits are visible before they
        // are reached, not only once they trip.
        for (final (limit, color) in <(double?, Color)>[
          (warnAbove, warnColor),
          (dangerAbove, dangerColor),
        ]) {
          if (limit == null || limit <= 0 || limit >= 1) continue;
          final tick = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(stroke, geometry.side * 0.03)
            ..color = color.withValues(alpha: 0.55);
          canvas.drawArc(
            _band(geometry, tick.strokeWidth),
            geometry.angleAt(limit),
            0.02,
            false,
            tick,
          );
        }
      case AlarmMarks.bands:
        // Each range where the gauge alarms, shaded along the track.
        final width = math.max(stroke, geometry.side * 0.03);
        for (final (from, to, color) in _alarmRanges(
          warnBelow: warnBelow,
          dangerBelow: dangerBelow,
          warnAbove: warnAbove,
          dangerAbove: dangerAbove,
          warnColor: warnColor,
          dangerColor: dangerColor,
        )) {
          canvas.drawArc(
            _band(geometry, width),
            geometry.angleAt(from),
            geometry.sweepAngle * (to - from),
            false,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = width
              ..color = color.withValues(alpha: 0.45),
          );
        }
    }

    if (dial.scale != ScaleMarks.none) _paintScale(canvas, geometry);
  }

  /// The rectangle an arc [width] wide is drawn round so its outer edge meets
  /// the track's.
  static Rect _band(_DialGeometry geometry, double width) => Rect.fromCircle(
    center: geometry.centre,
    radius: geometry.radius + geometry.stroke / 2 - width / 2,
  );

  void _paintScale(Canvas canvas, _DialGeometry geometry) {
    final paint = Paint()
      ..color = tickColor
      ..strokeCap = StrokeCap.round;
    final outer = geometry.trackInner;

    void tick(double fraction, double length, double width) {
      final angle = geometry.angleAt(fraction);
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        geometry.centre + direction * outer,
        geometry.centre + direction * (outer - length),
        paint..strokeWidth = width,
      );
    }

    for (final at in scale.majors) {
      tick(at, geometry.majorTick, geometry.side * 0.012);
    }
    for (final at in scale.minors) {
      tick(at, geometry.minorTick, geometry.side * 0.007);
    }

    for (final (at, text) in scale.labels) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: (labelStyle ?? const TextStyle()).copyWith(
            fontSize: geometry.numberSize,
            color: tickColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final angle = geometry.angleAt(at);
      final middle =
          geometry.centre +
          Offset(math.cos(angle), math.sin(angle)) * geometry.numberRadius;
      painter
        ..paint(canvas, middle - Offset(painter.width / 2, painter.height / 2))
        ..dispose();
    }
  }

  @override
  bool shouldRepaint(_DialFacePainter old) =>
      old.look != look ||
      old.scale != scale ||
      old.warnAbove != warnAbove ||
      old.dangerAbove != dangerAbove ||
      old.warnBelow != warnBelow ||
      old.dangerBelow != dangerBelow ||
      old.trackColor != trackColor ||
      old.tickColor != tickColor ||
      old.warnColor != warnColor ||
      old.dangerColor != dangerColor ||
      old.background != background ||
      old.labelStyle != labelStyle;
}

/// The reading on a dial: a band along the track, or a needle.
class _DialValuePainter extends CustomPainter {
  _DialValuePainter({
    required this.look,
    required this.fraction,
    required this.color,
    required this.hasValue,
  });

  final DialLook look;
  final double fraction;
  final Color color;
  final bool hasValue;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = _DialGeometry.of(size, look);
    final side = geometry.side;

    if (geometry.face == DialFace.arc) {
      if (!hasValue || fraction <= 0) return;
      final value = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.stroke
        ..strokeCap = StrokeCap.round
        ..color = color;
      canvas.drawArc(
        geometry.rect,
        geometry.startAngle,
        geometry.sweepAngle * fraction,
        false,
        value,
      );
      return;
    }

    // With no reading there is nothing to point at: the hub alone.
    final hub = Paint()
      ..color = hasValue ? color : color.withValues(alpha: 0.4);
    if (hasValue) {
      final angle = geometry.angleAt(fraction);
      final direction = Offset(math.cos(angle), math.sin(angle));
      final reach = geometry.trackInner - side * 0.015;
      canvas.drawLine(
        geometry.centre - direction * side * 0.06,
        geometry.centre + direction * reach,
        Paint()
          ..color = color
          ..strokeCap = StrokeCap.round
          ..strokeWidth =
              side *
              switch (geometry.thickness) {
                Thickness.thin => 0.012,
                Thickness.regular => 0.02,
                Thickness.bold => 0.03,
              },
      );
    }
    canvas.drawCircle(geometry.centre, geometry.hub, hub);
  }

  @override
  bool shouldRepaint(_DialValuePainter old) =>
      old.fraction != fraction ||
      old.color != color ||
      old.hasValue != hasValue ||
      old.look != look;
}

/// The stretches of a scale, from 0 to 1, where a reading alarms: each with
/// the colour it alarms in. Danger is laid over warning, so where they
/// overlap the worse one shows.
List<(double, double, Color)> _alarmRanges({
  required double? warnBelow,
  required double? dangerBelow,
  required double? warnAbove,
  required double? dangerAbove,
  required Color warnColor,
  required Color dangerColor,
}) {
  double clamp(double at) => at.clamp(0.0, 1.0);
  return <(double, double, Color)>[
    if (warnBelow case final at?) (0, clamp(at), warnColor),
    if (warnAbove case final at?) (clamp(at), 1, warnColor),
    if (dangerBelow case final at?) (0, clamp(at), dangerColor),
    if (dangerAbove case final at?) (clamp(at), 1, dangerColor),
  ].where((range) => range.$2 > range.$1).toList();
}

/// The same ranges, for bars and graphs: see [_alarmRanges].
List<(double, double, Color)> alarmRanges(
  GaugeSpec spec,
  GaugeColours colours,
) {
  double? at(double? limit) => limit == null ? null : spec.fractionFor(limit);
  return _alarmRanges(
    warnBelow: at(spec.warnBelow),
    dangerBelow: at(spec.dangerBelow),
    warnAbove: at(spec.warnAbove),
    dangerAbove: at(spec.dangerAbove),
    warnColor: colours.warningColour,
    dangerColor: colours.dangerColour,
  );
}
