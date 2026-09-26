import 'package:flutter/material.dart';

import '../app_settings/map_colours.dart' show colorFromHex, hexOf, readableOn;
import 'gauge_status.dart';
import 'layout/dashboard_layout.dart' show GaugeStyle;

/// How a dial draws its reading.
enum DialFace {
  /// A band that fills along the scale.
  arc('Arc'),

  /// A needle over a scale, like an analogue instrument.
  needle('Needle');

  const DialFace(this.label);
  final String label;
}

/// How far round a dial's scale runs, in degrees.
const dialSweeps = [180, 240, 270, 300];

/// How heavy a gauge's line, band or bar is drawn.
enum Thickness {
  thin('Thin'),
  regular('Regular'),
  bold('Bold');

  const Thickness(this.label);
  final String label;
}

/// What is marked along a dial's scale.
enum ScaleMarks {
  none('None'),
  ticks('Ticks'),
  numbers('Numbers');

  const ScaleMarks(this.label);
  final String label;
}

/// How a gauge shows where its alarms start, before they are reached.
enum AlarmMarks {
  none('None'),

  /// A mark at each alarm point.
  ticks('Marks'),

  /// The alarm ranges shaded.
  bands('Bands');

  const AlarmMarks(this.label);
  final String label;
}

/// Which way a bar runs.
enum BarOrientation {
  /// Along the longer side of its space.
  auto('Fit'),
  horizontal('Across'),
  vertical('Upright');

  const BarOrientation(this.label);
  final String label;
}

/// How large a digital readout's number is, against its caption.
enum ValueSize {
  regular('Regular'),
  large('Large');

  const ValueSize(this.label);
  final String label;
}

/// The outline of a lamp.
enum LampShape {
  pill('Pill'),
  square('Square'),

  /// No outline: the light and its label alone.
  plain('Plain');

  const LampShape(this.label);
  final String label;
}

/// Marks a `copyWith` argument that was left out, as against one set to
/// `null` - which, for a look, means "back to the default".
const Object _unset = _Unset();

class _Unset {
  const _Unset();
}

T? _pick<T>(Object? given, T? current) =>
    identical(given, _unset) ? current : given as T?;

/// [values]'s entry named [name], or `null` where there is none.
T? _named<T extends Enum>(List<T> values, Object? name) =>
    values.asNameMap()[name];

bool? _flag(Object? value) => value is bool ? value : null;

Color? _colour(Object? value) => value is String ? colorFromHex(value) : null;

/// How a dial looks. Every field left `null` follows the default.
@immutable
class DialLook {
  const DialLook({
    this.face,
    this.sweep,
    this.thickness,
    this.scale,
    this.alarms,
  });

  /// The dial as FoxTune has always drawn it.
  static const builtIn = DialLook(
    face: DialFace.arc,
    sweep: 270,
    thickness: Thickness.regular,
    scale: ScaleMarks.none,
    alarms: AlarmMarks.ticks,
  );

  final DialFace? face;

  /// One of [dialSweeps].
  final int? sweep;
  final Thickness? thickness;
  final ScaleMarks? scale;
  final AlarmMarks? alarms;

  /// How many of its fields are set.
  int get changes => [face, sweep, thickness, scale, alarms].nonNulls.length;

  /// Every field, from this look where it has one, else from [builtIn].
  ({
    DialFace face,
    int sweep,
    Thickness thickness,
    ScaleMarks scale,
    AlarmMarks alarms,
  })
  get resolved => (
    face: face ?? builtIn.face!,
    sweep: sweep ?? builtIn.sweep!,
    thickness: thickness ?? builtIn.thickness!,
    scale: scale ?? builtIn.scale!,
    alarms: alarms ?? builtIn.alarms!,
  );

  /// This look, with [base]'s fields where it has none of its own.
  DialLook over(DialLook base) => DialLook(
    face: face ?? base.face,
    sweep: sweep ?? base.sweep,
    thickness: thickness ?? base.thickness,
    scale: scale ?? base.scale,
    alarms: alarms ?? base.alarms,
  );

  /// A copy with the fields given changed; one given as `null` is cleared.
  DialLook copyWith({
    Object? face = _unset,
    Object? sweep = _unset,
    Object? thickness = _unset,
    Object? scale = _unset,
    Object? alarms = _unset,
  }) => DialLook(
    face: _pick(face, this.face),
    sweep: _pick(sweep, this.sweep),
    thickness: _pick(thickness, this.thickness),
    scale: _pick(scale, this.scale),
    alarms: _pick(alarms, this.alarms),
  );

  Map<String, Object?> toJson() => {
    'face': ?face?.name,
    'sweep': ?sweep,
    'thickness': ?thickness?.name,
    'scale': ?scale?.name,
    'alarms': ?alarms?.name,
  };

  static DialLook fromJson(Object? json) {
    if (json is! Map) return const DialLook();
    final sweep = json['sweep'];
    return DialLook(
      face: _named(DialFace.values, json['face']),
      sweep: sweep is int && dialSweeps.contains(sweep) ? sweep : null,
      thickness: _named(Thickness.values, json['thickness']),
      scale: _named(ScaleMarks.values, json['scale']),
      alarms: _named(AlarmMarks.values, json['alarms']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DialLook &&
      other.face == face &&
      other.sweep == sweep &&
      other.thickness == thickness &&
      other.scale == scale &&
      other.alarms == alarms;

  @override
  int get hashCode => Object.hash(face, sweep, thickness, scale, alarms);
}

/// How a bar looks. Every field left `null` follows the default.
@immutable
class BarLook {
  const BarLook({
    this.orientation,
    this.thickness,
    this.segmented,
    this.alarms,
  });

  /// The bar as FoxTune has always drawn it.
  static const builtIn = BarLook(
    orientation: BarOrientation.auto,
    thickness: Thickness.regular,
    segmented: false,
    alarms: AlarmMarks.none,
  );

  final BarOrientation? orientation;
  final Thickness? thickness;

  /// Whether the bar fills in separate blocks rather than one run.
  final bool? segmented;
  final AlarmMarks? alarms;

  int get changes =>
      [orientation, thickness, segmented, alarms].nonNulls.length;

  ({
    BarOrientation orientation,
    Thickness thickness,
    bool segmented,
    AlarmMarks alarms,
  })
  get resolved => (
    orientation: orientation ?? builtIn.orientation!,
    thickness: thickness ?? builtIn.thickness!,
    segmented: segmented ?? builtIn.segmented!,
    alarms: alarms ?? builtIn.alarms!,
  );

  BarLook over(BarLook base) => BarLook(
    orientation: orientation ?? base.orientation,
    thickness: thickness ?? base.thickness,
    segmented: segmented ?? base.segmented,
    alarms: alarms ?? base.alarms,
  );

  BarLook copyWith({
    Object? orientation = _unset,
    Object? thickness = _unset,
    Object? segmented = _unset,
    Object? alarms = _unset,
  }) => BarLook(
    orientation: _pick(orientation, this.orientation),
    thickness: _pick(thickness, this.thickness),
    segmented: _pick(segmented, this.segmented),
    alarms: _pick(alarms, this.alarms),
  );

  Map<String, Object?> toJson() => {
    'orientation': ?orientation?.name,
    'thickness': ?thickness?.name,
    'segmented': ?segmented,
    'alarms': ?alarms?.name,
  };

  static BarLook fromJson(Object? json) {
    if (json is! Map) return const BarLook();
    return BarLook(
      orientation: _named(BarOrientation.values, json['orientation']),
      thickness: _named(Thickness.values, json['thickness']),
      segmented: _flag(json['segmented']),
      alarms: _named(AlarmMarks.values, json['alarms']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BarLook &&
      other.orientation == orientation &&
      other.thickness == thickness &&
      other.segmented == segmented &&
      other.alarms == alarms;

  @override
  int get hashCode => Object.hash(orientation, thickness, segmented, alarms);
}

/// How a digital readout looks. Every field left `null` follows the default.
@immutable
class ReadoutLook {
  const ReadoutLook({this.framed, this.magnitudeBar, this.valueSize});

  /// The readout as FoxTune has always drawn it.
  static const builtIn = ReadoutLook(
    framed: true,
    magnitudeBar: true,
    valueSize: ValueSize.regular,
  );

  /// Whether it sits on a card with an outline.
  final bool? framed;

  /// Whether a thin bar under the number shows where it is in its range.
  final bool? magnitudeBar;
  final ValueSize? valueSize;

  int get changes => [framed, magnitudeBar, valueSize].nonNulls.length;

  ({bool framed, bool magnitudeBar, ValueSize valueSize}) get resolved => (
    framed: framed ?? builtIn.framed!,
    magnitudeBar: magnitudeBar ?? builtIn.magnitudeBar!,
    valueSize: valueSize ?? builtIn.valueSize!,
  );

  ReadoutLook over(ReadoutLook base) => ReadoutLook(
    framed: framed ?? base.framed,
    magnitudeBar: magnitudeBar ?? base.magnitudeBar,
    valueSize: valueSize ?? base.valueSize,
  );

  ReadoutLook copyWith({
    Object? framed = _unset,
    Object? magnitudeBar = _unset,
    Object? valueSize = _unset,
  }) => ReadoutLook(
    framed: _pick(framed, this.framed),
    magnitudeBar: _pick(magnitudeBar, this.magnitudeBar),
    valueSize: _pick(valueSize, this.valueSize),
  );

  Map<String, Object?> toJson() => {
    'framed': ?framed,
    'magnitudeBar': ?magnitudeBar,
    'valueSize': ?valueSize?.name,
  };

  static ReadoutLook fromJson(Object? json) {
    if (json is! Map) return const ReadoutLook();
    return ReadoutLook(
      framed: _flag(json['framed']),
      magnitudeBar: _flag(json['magnitudeBar']),
      valueSize: _named(ValueSize.values, json['valueSize']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReadoutLook &&
      other.framed == framed &&
      other.magnitudeBar == magnitudeBar &&
      other.valueSize == valueSize;

  @override
  int get hashCode => Object.hash(framed, magnitudeBar, valueSize);
}

/// How a time graph looks. Every field left `null` follows the default.
@immutable
class GraphLook {
  const GraphLook({this.thickness, this.fill, this.alarms});

  /// The graph as FoxTune has always drawn it.
  static const builtIn = GraphLook(
    thickness: Thickness.regular,
    fill: false,
    alarms: AlarmMarks.none,
  );

  /// How heavy the trace is.
  final Thickness? thickness;

  /// Whether the area under the trace is shaded.
  final bool? fill;
  final AlarmMarks? alarms;

  int get changes => [thickness, fill, alarms].nonNulls.length;

  ({Thickness thickness, bool fill, AlarmMarks alarms}) get resolved => (
    thickness: thickness ?? builtIn.thickness!,
    fill: fill ?? builtIn.fill!,
    alarms: alarms ?? builtIn.alarms!,
  );

  GraphLook over(GraphLook base) => GraphLook(
    thickness: thickness ?? base.thickness,
    fill: fill ?? base.fill,
    alarms: alarms ?? base.alarms,
  );

  GraphLook copyWith({
    Object? thickness = _unset,
    Object? fill = _unset,
    Object? alarms = _unset,
  }) => GraphLook(
    thickness: _pick(thickness, this.thickness),
    fill: _pick(fill, this.fill),
    alarms: _pick(alarms, this.alarms),
  );

  Map<String, Object?> toJson() => {
    'thickness': ?thickness?.name,
    'fill': ?fill,
    'alarms': ?alarms?.name,
  };

  static GraphLook fromJson(Object? json) {
    if (json is! Map) return const GraphLook();
    return GraphLook(
      thickness: _named(Thickness.values, json['thickness']),
      fill: _flag(json['fill']),
      alarms: _named(AlarmMarks.values, json['alarms']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GraphLook &&
      other.thickness == thickness &&
      other.fill == fill &&
      other.alarms == alarms;

  @override
  int get hashCode => Object.hash(thickness, fill, alarms);
}

/// How a lamp looks. Every field left `null` follows the default.
@immutable
class LampLook {
  const LampLook({this.shape, this.onColour});

  /// The lamp as FoxTune has always drawn it.
  static const builtIn = LampLook(shape: LampShape.pill);

  final LampShape? shape;

  /// The colour it lights in. Left `null`, a lamp lights in the colour its
  /// ECU definition gives it, or green where it gives none.
  final Color? onColour;

  int get changes => [shape, onColour].nonNulls.length;

  ({LampShape shape, Color? onColour}) get resolved =>
      (shape: shape ?? builtIn.shape!, onColour: onColour);

  LampLook over(LampLook base) =>
      LampLook(shape: shape ?? base.shape, onColour: onColour ?? base.onColour);

  LampLook copyWith({Object? shape = _unset, Object? onColour = _unset}) =>
      LampLook(
        shape: _pick(shape, this.shape),
        onColour: _pick(onColour, this.onColour),
      );

  Map<String, Object?> toJson() => {
    'shape': ?shape?.name,
    if (onColour case final colour?) 'onColour': hexOf(colour),
  };

  static LampLook fromJson(Object? json) {
    if (json is! Map) return const LampLook();
    return LampLook(
      shape: _named(LampShape.values, json['shape']),
      onColour: _colour(json['onColour']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LampLook && other.shape == shape && other.onColour == onColour;

  @override
  int get hashCode => Object.hash(shape, onColour);
}

/// The colours a gauge is drawn in. Every one left `null` is the theme's, so
/// it follows the light theme and the dark; one that is set is used in both.
///
/// Whatever colours are chosen, an alarm is still shown by its icon and word
/// as well - so a warning recoloured to look like a normal reading is still
/// plainly a warning.
@immutable
class GaugeColours {
  const GaugeColours({
    this.normal,
    this.warning,
    this.danger,
    this.track,
    this.background,
    this.text,
  });

  /// The reading, while it is in its normal range: a dial's band or needle, a
  /// bar's fill, a graph's trace.
  final Color? normal;

  /// The reading, while it is past a warning point.
  final Color? warning;

  /// The reading, while it is past a danger point.
  final Color? danger;

  /// The part of the scale the reading has not reached.
  final Color? track;

  /// Behind the whole gauge.
  final Color? background;

  /// The number, and the captions around it.
  final Color? text;

  int get changes =>
      [normal, warning, danger, track, background, text].nonNulls.length;

  Color get warningColour => warning ?? StatusPalette.warning;
  Color get dangerColour => danger ?? StatusPalette.critical;

  /// The colour for a reading in [status], where [normal] is the gauge's own
  /// colour for a normal reading when none is set.
  Color forStatus(GaugeStatus status, {required Color normal}) =>
      switch (status) {
        GaugeStatus.normal => this.normal ?? normal,
        GaugeStatus.warning => warningColour,
        GaugeStatus.danger => dangerColour,
      };

  /// The number's colour. Where a background is set and a text colour is
  /// not, the theme's text colour is swapped for black or white if it would
  /// not stand out from it.
  Color textOn(ColorScheme scheme) => _ink(scheme.onSurface, 4.5);

  /// The captions' colour: the label, the units.
  Color captionOn(ColorScheme scheme) => text != null
      ? text!.withValues(alpha: text!.a * 0.75)
      : _ink(scheme.onSurfaceVariant, 3);

  Color _ink(Color themed, double minContrast) {
    if (text case final chosen?) return chosen;
    if (background case final behind?) {
      return readableOn(behind, themed, minContrast: minContrast);
    }
    return themed;
  }

  GaugeColours over(GaugeColours base) => GaugeColours(
    normal: normal ?? base.normal,
    warning: warning ?? base.warning,
    danger: danger ?? base.danger,
    track: track ?? base.track,
    background: background ?? base.background,
    text: text ?? base.text,
  );

  GaugeColours copyWith({
    Object? normal = _unset,
    Object? warning = _unset,
    Object? danger = _unset,
    Object? track = _unset,
    Object? background = _unset,
    Object? text = _unset,
  }) => GaugeColours(
    normal: _pick(normal, this.normal),
    warning: _pick(warning, this.warning),
    danger: _pick(danger, this.danger),
    track: _pick(track, this.track),
    background: _pick(background, this.background),
    text: _pick(text, this.text),
  );

  /// Just the colours a lamp uses: it lights in its own colour - see
  /// [LampLook.onColour] - and has no alarms or scale.
  GaugeColours get lampOnly => GaugeColours(background: background, text: text);

  Map<String, Object?> toJson() => {
    for (final (name, colour) in [
      ('normal', normal),
      ('warning', warning),
      ('danger', danger),
      ('track', track),
      ('background', background),
      ('text', text),
    ])
      if (colour != null) name: hexOf(colour),
  };

  static GaugeColours fromJson(Object? json) {
    if (json is! Map) return const GaugeColours();
    return GaugeColours(
      normal: _colour(json['normal']),
      warning: _colour(json['warning']),
      danger: _colour(json['danger']),
      track: _colour(json['track']),
      background: _colour(json['background']),
      text: _colour(json['text']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GaugeColours &&
      other.normal == normal &&
      other.warning == warning &&
      other.danger == danger &&
      other.track == track &&
      other.background == background &&
      other.text == text;

  @override
  int get hashCode =>
      Object.hash(normal, warning, danger, track, background, text);
}

/// How gauges look, as against what they show.
///
/// The same shape serves as the default every gauge follows, kept in the app
/// settings, and as one gauge's own changes to it, kept with the gauge. A
/// field left `null` follows the layer below: a gauge's own look, over the
/// default, over [builtIn]. So a gauge given a wider sweep still takes up a
/// new default colour - only what was changed on it stays changed.
///
/// A look for each kind of gauge, because they share few settings and those
/// they share start from different places: a dial marks its alarm points
/// and a bar does not. The colours are shared, so a gauge switched from a
/// dial to a bar keeps them.
@immutable
class GaugeAppearance {
  const GaugeAppearance({
    this.dial = const DialLook(),
    this.bar = const BarLook(),
    this.readout = const ReadoutLook(),
    this.graph = const GraphLook(),
    this.lamp = const LampLook(),
    this.colours = const GaugeColours(),
  });

  /// Gauges as FoxTune has always drawn them.
  static const builtIn = GaugeAppearance(
    dial: DialLook.builtIn,
    bar: BarLook.builtIn,
    readout: ReadoutLook.builtIn,
    graph: GraphLook.builtIn,
    lamp: LampLook.builtIn,
  );

  final DialLook dial;
  final BarLook bar;
  final ReadoutLook readout;
  final GraphLook graph;
  final LampLook lamp;
  final GaugeColours colours;

  /// Whether nothing is set: a look that changes nothing.
  bool get isEmpty => this == const GaugeAppearance();

  /// How many settings a gauge of [kind] has changed.
  int changesFor(GaugeStyle kind) =>
      only(kind).colours.changes +
      switch (kind) {
        GaugeStyle.dial => dial.changes,
        GaugeStyle.bar => bar.changes,
        GaugeStyle.digital => readout.changes,
        GaugeStyle.graph => graph.changes,
        GaugeStyle.lamp => lamp.changes,
      };

  /// Just what a gauge of [kind] uses of this look.
  GaugeAppearance only(GaugeStyle kind) => switch (kind) {
    GaugeStyle.dial => GaugeAppearance(dial: dial, colours: colours),
    GaugeStyle.bar => GaugeAppearance(bar: bar, colours: colours),
    GaugeStyle.digital => GaugeAppearance(readout: readout, colours: colours),
    GaugeStyle.graph => GaugeAppearance(graph: graph, colours: colours),
    GaugeStyle.lamp => GaugeAppearance(lamp: lamp, colours: colours.lampOnly),
  };

  /// This look without what a gauge of [kind] uses of it - what is left once
  /// that has been handed to the default.
  GaugeAppearance without(GaugeStyle kind) => switch (kind) {
    GaugeStyle.dial => copyWith(dial: const DialLook(), colours: _noColours),
    GaugeStyle.bar => copyWith(bar: const BarLook(), colours: _noColours),
    GaugeStyle.digital => copyWith(
      readout: const ReadoutLook(),
      colours: _noColours,
    ),
    GaugeStyle.graph => copyWith(graph: const GraphLook(), colours: _noColours),
    GaugeStyle.lamp => copyWith(
      lamp: const LampLook(),
      colours: colours.copyWith(background: null, text: null),
    ),
  };

  static const _noColours = GaugeColours();

  /// This look, with [base]'s settings wherever it has none of its own.
  GaugeAppearance over(GaugeAppearance base) => GaugeAppearance(
    dial: dial.over(base.dial),
    bar: bar.over(base.bar),
    readout: readout.over(base.readout),
    graph: graph.over(base.graph),
    lamp: lamp.over(base.lamp),
    colours: colours.over(base.colours),
  );

  GaugeAppearance copyWith({
    DialLook? dial,
    BarLook? bar,
    ReadoutLook? readout,
    GraphLook? graph,
    LampLook? lamp,
    GaugeColours? colours,
  }) => GaugeAppearance(
    dial: dial ?? this.dial,
    bar: bar ?? this.bar,
    readout: readout ?? this.readout,
    graph: graph ?? this.graph,
    lamp: lamp ?? this.lamp,
    colours: colours ?? this.colours,
  );

  /// What is set, and nothing else.
  Map<String, Object?> toJson() => {
    for (final (name, section) in [
      ('dial', dial.toJson()),
      ('bar', bar.toJson()),
      ('readout', readout.toJson()),
      ('graph', graph.toJson()),
      ('lamp', lamp.toJson()),
      ('colours', colours.toJson()),
    ])
      if (section.isNotEmpty) name: section,
  };

  /// Reads what [toJson] wrote.
  ///
  /// A setting that cannot be read - from a later version, or edited by hand
  /// - follows the default, one setting at a time, rather than costing the
  /// rest.
  static GaugeAppearance fromJson(Object? json) {
    if (json is! Map) return const GaugeAppearance();
    return GaugeAppearance(
      dial: DialLook.fromJson(json['dial']),
      bar: BarLook.fromJson(json['bar']),
      readout: ReadoutLook.fromJson(json['readout']),
      graph: GraphLook.fromJson(json['graph']),
      lamp: LampLook.fromJson(json['lamp']),
      colours: GaugeColours.fromJson(json['colours']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GaugeAppearance &&
      other.dial == dial &&
      other.bar == bar &&
      other.readout == readout &&
      other.graph == graph &&
      other.lamp == lamp &&
      other.colours == colours;

  @override
  int get hashCode => Object.hash(dial, bar, readout, graph, lamp, colours);
}
