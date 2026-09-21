import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import 'gauge_status.dart';
import 'layout/dashboard_layout.dart';

/// A live channel the definition has no gauge for, as the picker offers it.
class ChannelChoice {
  const ChannelChoice({
    required this.name,
    required this.units,
    required this.isFlag,
  });

  final String name;

  /// Units as declared, where they are plain text. Empty otherwise.
  final String units;

  /// Whether it is a single status bit, shown as a lamp rather than a number.
  final bool isFlag;
}

/// Turns the definition's gauges, channels and indicators into what the
/// dashboard draws.
///
/// A gauge's range, its warning and danger points and its units come from
/// `[GaugeConfigurations]` - and where those are expressions, they are
/// evaluated here, each time the gauge is drawn. That is what makes the
/// tachometer follow Gauge Limits: its upper end and its warning points are
/// `{rpmhigh}`, `{rpmwarn}` and `{rpmdang}`, which resolve through the tune to
/// whatever the tuner last set.
///
/// A tuner can replace any gauge's limits with their own ([limits]), and a
/// channel the definition has no gauge for is drawn from what its
/// `[OutputChannels]` entry says, which is far less.
class GaugeCatalog {
  GaugeCatalog({
    required this.definition,
    this.resolver,
    this.realtime,
    this.limits = const {},
  });

  final IniDocument definition;

  /// The loaded tune, where Gauge Limits and other settings live.
  final TuneValueResolver? resolver;

  /// The latest realtime sample, for indicators and live-derived values.
  final RealtimeSnapshot? realtime;

  /// Limits the tuner has set, by [GaugeRef].
  final Map<String, GaugeLimits> limits;

  static final Map<String, CompiledExpression?> _compiled = {};

  static CompiledExpression? _compile(String source) => _compiled.putIfAbsent(
    source,
    () => CompiledExpression.tryCompile(source),
  );

  /// Resolves a name for a gauge's limits: the tune first, since limits are
  /// settings, then the live sample, then the definition's factory value.
  ///
  /// The last step matters in the moment after connecting, before the tune has
  /// been read: the tachometer should still have a scale, and the factory
  /// values are the honest one to use.
  double? resolveSetting(String name) =>
      resolver?.resolve(name) ?? realtime?[name] ?? _factoryValue(name);

  /// Resolves a name for an indicator: the live sample first, since an
  /// indicator reports what the engine is doing now.
  double? resolveLive(String name) =>
      realtime?[name] ?? resolver?.resolve(name) ?? _factoryValue(name);

  double? _factoryValue(String name) {
    final indexed = parseIndexedName(name);
    final values = definition.defaultValues[indexed?.name ?? name];
    final index = indexed?.index ?? 0;
    return values != null && index < values.length ? values[index] : null;
  }

  double? _limit(IniScalarValue? value) => switch (value) {
    null => null,
    IniLiteral(:final value) => value,
    IniExpression(:final source) => _compile(source)?.evaluate(resolveSetting),
  };

  /// This catalog with the tuner's limits replaced by [limits].
  GaugeCatalog withLimits(Map<String, GaugeLimits> limits) => GaugeCatalog(
    definition: definition,
    resolver: resolver,
    realtime: realtime,
    limits: limits,
  );

  // --- By reference ----------------------------------------------------------

  /// How to draw what [ref] names, with any limits the tuner set, or `null`
  /// when this definition has no such gauge or channel.
  GaugeSpec? specOf(String ref) {
    final spec = definedSpecOf(ref);
    final own = limits[ref];
    if (spec == null || own == null) return spec;
    return GaugeSpec(
      channel: spec.channel,
      label: spec.label,
      units: spec.units,
      min: own.min,
      max: own.max,
      decimals: own.decimals,
      dangerBelow: own.dangerBelow,
      warnBelow: own.warnBelow,
      warnAbove: own.warnAbove,
      dangerAbove: own.dangerAbove,
    );
  }

  /// How the definition alone says to draw what [ref] names.
  GaugeSpec? definedSpecOf(String ref) {
    final channel = GaugeRef.channelOf(ref);
    if (channel != null) return _channelSpec(channel);
    final gauge = definition.gaugeNamed(ref);
    return gauge == null ? null : specFor(gauge);
  }

  /// The live reading of what [ref] names, or `null` when unavailable.
  double? readingOf(String ref) {
    final channel =
        GaugeRef.channelOf(ref) ?? definition.gaugeNamed(ref)?.channel;
    return channel == null ? null : realtime?[channel];
  }

  /// A name for [ref] fit to show a user.
  String titleOfRef(String ref) {
    final channel = GaugeRef.channelOf(ref);
    if (channel != null) return channel;
    final gauge = definition.gaugeNamed(ref);
    return gauge == null ? ref : titleOf(gauge);
  }

  /// Whether the definition ties [ref]'s limits to settings in the tune, as
  /// the tachometer's follow Gauge Limits.
  ///
  /// Limits a tuner types in replace those, and stop following the tune - which
  /// is worth saying before they do it.
  bool followsTune(String ref) {
    final gauge = definition.gaugeNamed(ref);
    if (gauge == null) return false;
    return [
      gauge.lo,
      gauge.hi,
      gauge.loDanger,
      gauge.loWarning,
      gauge.hiWarning,
      gauge.hiDanger,
    ].any((value) => value is IniExpression);
  }

  /// Whether the definition gives [ref] alarm bands that FoxTune ignores
  /// because they contradict each other. See [_consistent].
  bool ignoresDefinedBands(String ref) {
    final gauge = definition.gaugeNamed(ref);
    if (gauge == null) return false;
    return _consistent(
          dangerBelow: _limit(gauge.loDanger),
          warnBelow: _limit(gauge.loWarning),
          warnAbove: _limit(gauge.hiWarning),
          dangerAbove: _limit(gauge.hiDanger),
        ) ==
        null;
  }

  // --- Defined gauges --------------------------------------------------------

  /// [gauge], resolved from the definition into what a widget draws.
  GaugeSpec specFor(IniGauge gauge) {
    final lo = _limit(gauge.lo) ?? 0;
    var hi = _limit(gauge.hi) ?? lo + 100;
    // A scale with no span cannot place a needle; give it one rather than
    // divide by zero.
    if (hi <= lo) hi = lo + 1;

    final bands = _consistent(
      dangerBelow: _limit(gauge.loDanger),
      warnBelow: _limit(gauge.loWarning),
      warnAbove: _limit(gauge.hiWarning),
      dangerAbove: _limit(gauge.hiDanger),
    );

    return GaugeSpec(
      channel: gauge.channel,
      label: titleOf(gauge),
      units: unitsOf(gauge),
      min: lo,
      max: hi,
      decimals: gauge.valueDigits,
      labelDecimals: gauge.labelDigits,
      dangerBelow: bands?.dangerBelow,
      warnBelow: bands?.warnBelow,
      warnAbove: bands?.warnAbove,
      dangerAbove: bands?.dangerAbove,
    );
  }

  /// The definition's alarm bands, or `null` where they contradict each other.
  ///
  /// A reading is normal from the higher of the low bands to the lower of the
  /// high ones. Where those meet or cross, one exact value at most is normal -
  /// which no gauge can mean. Speeduino's definition has exactly this on
  /// eight gauges, all copied from one line (`130, 140, 140, 150`): warmup
  /// enrichment reads DANGER at 100%, which is where it sits on every warm
  /// engine, and the squirt count reads DANGER whatever it is but 140. Its
  /// free-memory gauge has the high bands the wrong way round and does the
  /// same.
  ///
  /// Guessing which half was meant would be inventing limits, so the whole set
  /// is dropped. The gauge shows plainly, and a tuner who wants alarms on it
  /// sets their own.
  static ({
    double? dangerBelow,
    double? warnBelow,
    double? warnAbove,
    double? dangerAbove,
  })?
  _consistent({
    double? dangerBelow,
    double? warnBelow,
    double? warnAbove,
    double? dangerAbove,
  }) {
    final lows = [?dangerBelow, ?warnBelow];
    final highs = [?warnAbove, ?dangerAbove];
    if (lows.isNotEmpty &&
        highs.isNotEmpty &&
        lows.reduce(math.max) >= highs.reduce(math.min)) {
      return null;
    }
    return (
      dangerBelow: dangerBelow,
      warnBelow: warnBelow,
      warnAbove: warnAbove,
      dangerAbove: dangerAbove,
    );
  }

  /// The heading to show for [gauge].
  String titleOf(IniGauge gauge) {
    final expression = gauge.titleExpression;
    if (expression == null) return gauge.displayTitle;
    return evaluateLabel(
          expression,
          definition: definition,
          resolve: resolveSetting,
        ) ??
        gauge.displayTitle;
  }

  /// The units to show for [gauge].
  String unitsOf(IniGauge gauge) {
    final expression = gauge.unitsExpression;
    if (expression == null) return gauge.units;
    return evaluateLabel(
          expression,
          definition: definition,
          resolve: resolveSetting,
        ) ??
        '';
  }

  // --- Bare channels ---------------------------------------------------------

  /// A channel with no gauge definition, drawn from its `[OutputChannels]`
  /// entry.
  ///
  /// That entry gives units and a scale, and nothing about what is normal: no
  /// alarms, and no range beyond what the channel can physically report. A
  /// computed channel does not even have that, and says so with
  /// [GaugeSpec.hasRange].
  GaugeSpec? _channelSpec(String name) {
    final channels = definition.outputChannels;
    final field = channels.channelNamed(name);
    if (field != null) {
      final range = _representable(field);
      return GaugeSpec(
        channel: name,
        label: name,
        units: _plainUnits(switch (field) {
          IniScalarField(:final units) => units,
          _ => '',
        }),
        min: range?.min ?? 0,
        max: range?.max ?? 100,
        hasRange: range != null,
        decimals: switch (field) {
          IniScalarField(:final digits?) => digits,
          IniScalarField(:final scale) => _decimalsFor(_limit(scale)),
          _ => 0,
        },
      );
    }

    final computed = channels.computedNamed(name);
    if (computed == null) return null;
    return GaugeSpec(
      channel: name,
      label: name,
      units: _plainUnits(computed.units),
      min: 0,
      max: 100,
      hasRange: false,
      decimals: 2,
    );
  }

  /// Everything [field] can report, in display units.
  ({double min, double max})? _representable(IniField field) {
    if (field is IniBitsField) {
      return (min: 0, max: (field.valueCount - 1).toDouble());
    }
    if (field is! IniScalarField || field.type.isFloat) return null;

    final bits = field.type.bytes * 8;
    final rawMin = field.type.signed ? -math.pow(2, bits - 1) : 0;
    final rawMax = field.type.signed
        ? math.pow(2, bits - 1) - 1
        : math.pow(2, bits) - 1;
    final scale = _limit(field.scale);
    final translate = _limit(field.translate);
    if (scale == null || translate == null || scale == 0) return null;

    final a = rawMin * scale + translate;
    final b = rawMax * scale + translate;
    return (min: math.min(a, b).toDouble(), max: math.max(a, b).toDouble());
  }

  /// Decimals that show every step a channel scaled by [scale] can take:
  /// none for whole units, one for tenths, and so on.
  static int _decimalsFor(double? scale) {
    if (scale == null || scale == 0) return 0;
    final step = scale.abs();
    if (step >= 1 && step == step.roundToDouble()) return 0;
    return (-math.log(step) / math.ln10).ceil().clamp(0, 4);
  }

  /// [units] where they are text; empty where they are an expression, which
  /// would otherwise show as its source.
  String _plainUnits(String units) {
    final trimmed = units.trim();
    if (!trimmed.startsWith('{')) return trimmed;
    final inner = trimmed.substring(1, trimmed.length - 1);
    return evaluateLabel(
          inner,
          definition: definition,
          resolve: resolveSetting,
        ) ??
        '';
  }

  /// Every live channel no `[GaugeConfigurations]` gauge shows, in declaration
  /// order.
  ///
  /// Single status bits the definition's front page already offers as an
  /// indicator are left out: that indicator has proper labels.
  static List<ChannelChoice> channelsWithoutGauges(IniDocument definition) {
    final shown = {for (final gauge in definition.gauges) gauge.channel};
    final indicators = {
      for (final indicator in definition.frontPage.indicators)
        indicator.expression.trim(),
    };
    final channels = definition.outputChannels;

    String plain(String units) => units.trim().startsWith('{') ? '' : units;

    final choices = <ChannelChoice>[];
    for (final field in channels.channels) {
      if (shown.contains(field.name)) continue;
      switch (field) {
        case IniBitsField(bitCount: 1):
          if (indicators.contains(field.name)) continue;
          choices.add(ChannelChoice(name: field.name, units: '', isFlag: true));
        case IniBitsField():
          choices.add(
            ChannelChoice(name: field.name, units: '', isFlag: false),
          );
        case IniScalarField(:final units):
          choices.add(
            ChannelChoice(name: field.name, units: plain(units), isFlag: false),
          );
        case IniArrayField():
          continue;
      }
    }
    for (final computed in channels.computed) {
      if (shown.contains(computed.name)) continue;
      choices.add(
        ChannelChoice(
          name: computed.name,
          units: plain(computed.units),
          isFlag: false,
        ),
      );
    }
    return choices;
  }

  // --- Indicators ------------------------------------------------------------

  /// The indicator a lamp showing [expression] draws: the front page's, or
  /// failing that a status bit of that name, labelled with its own name.
  IniDialogIndicator? indicatorFor(String? expression) {
    if (expression == null) return null;
    final defined = definition.frontPage.indicators
        .where((i) => i.expression == expression)
        .firstOrNull;
    if (defined != null) return defined;

    final field = definition.outputChannels.channelNamed(expression);
    if (field is IniBitsField && field.bitCount == 1) {
      return IniDialogIndicator(
        expression: expression,
        offLabel: expression,
        onLabel: expression,
      );
    }
    return null;
  }

  /// Whether [indicator] is on, or `null` when it cannot be told yet.
  bool? isOn(IniDialogIndicator indicator) {
    final value = _compile(indicator.expression)?.evaluate(resolveLive);
    return value == null ? null : value != 0;
  }

  /// The colour an indicator lights in, from the colour the definition names.
  ///
  /// The definition's own choices carry meaning - red for "Hard Limiter", green
  /// for "Running" - so they are kept, but mapped onto the fixed status palette
  /// rather than used raw: a literal red on a dark theme is hard to read, and
  /// the palette's colours are the ones every alarm elsewhere uses.
  static Color? colorFor(String? name) => switch (name?.toLowerCase()) {
    'green' => StatusPalette.good,
    'red' => StatusPalette.critical,
    'yellow' || 'orange' => StatusPalette.warning,
    _ => null,
  };
}
