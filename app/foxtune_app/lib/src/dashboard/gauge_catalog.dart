import 'package:flutter/material.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import 'gauge_status.dart';

/// Turns the definition's gauges and indicators into what the dashboard draws.
///
/// Nothing about a gauge is typed into FoxTune. Its range, its warning and
/// danger points and its units all come from `[GaugeConfigurations]` - and
/// where those are expressions, they are evaluated here, each time the gauge is
/// drawn. That is what makes the tachometer follow Gauge Limits: its upper end
/// and its warning points are `{rpmhigh}`, `{rpmwarn}` and `{rpmdang}`, which
/// resolve through the tune to whatever the tuner last set.
class GaugeCatalog {
  GaugeCatalog({required this.definition, this.resolver, this.realtime});

  final IniDocument definition;

  /// The loaded tune, where Gauge Limits and other settings live.
  final TuneValueResolver? resolver;

  /// The latest realtime sample, for indicators and live-derived values.
  final RealtimeSnapshot? realtime;

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

  /// [gauge], resolved into what a widget draws.
  GaugeSpec specFor(IniGauge gauge) {
    final lo = _limit(gauge.lo) ?? 0;
    var hi = _limit(gauge.hi) ?? lo + 100;
    // A scale with no span cannot place a needle; give it one rather than
    // divide by zero.
    if (hi <= lo) hi = lo + 1;

    return GaugeSpec(
      channel: gauge.channel,
      label: titleOf(gauge),
      units: unitsOf(gauge),
      min: lo,
      max: hi,
      decimals: gauge.valueDigits,
      labelDecimals: gauge.labelDigits,
      dangerBelow: _limit(gauge.loDanger),
      warnBelow: _limit(gauge.loWarning),
      warnAbove: _limit(gauge.hiWarning),
      dangerAbove: _limit(gauge.hiDanger),
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

  /// The live reading for [gauge], or `null` when unavailable.
  double? valueOf(IniGauge gauge) => realtime?[gauge.channel];

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
