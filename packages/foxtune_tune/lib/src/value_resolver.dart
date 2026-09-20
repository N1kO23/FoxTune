import 'package:foxtune_ini/foxtune_ini.dart';

import 'tune_state.dart';

/// Resolves identifiers appearing in `{ ... }` expressions against a tune.
///
/// Axis scaling is not always a literal. The VE table's load axis declares
/// `scale = {fuelLoadRes}`, and `fuelLoadRes` is itself an expression over
/// `algorithm`, a constant stored on a page. Resolving that chain is what makes
/// the load axis display the right numbers for the configured load source.
class TuneValueResolver {
  TuneValueResolver(this.tune)
      : _computed = {
          for (final channel in tune.definition.outputChannels.computed)
            if (CompiledExpression.tryCompile(channel.expression)
                case final compiled?)
              channel.name: compiled,
        };

  final TuneState tune;
  final Map<String, CompiledExpression> _computed;

  final Map<String, double?> _cache = {};
  final Map<String, CompiledExpression?> _compiled = {};
  final Set<String> _resolving = {};

  /// Looks up [name], returning `null` when it cannot be resolved.
  double? resolve(String name) {
    if (_cache.containsKey(name)) return _cache[name];
    if (!_resolving.add(name)) return null; // circular reference
    try {
      final value = _compute(name);
      _cache[name] = value;
      return value;
    } finally {
      _resolving.remove(name);
    }
  }

  double? _compute(String name) {
    // `outputPin[0]` arrives as one name; the index is peeled off here so a
    // caller never has to know whether a reference was indexed.
    final indexed = parseIndexedName(name);
    final base = indexed?.name ?? name;
    final index = indexed?.index ?? 0;

    // A constant stored on a page takes precedence: it is the real setting.
    final located = tune.locate(base);
    if (located != null) {
      final value = _fromPage(
        located.page,
        located.field,
        index: index,
        wasIndexed: indexed != null,
      );
      if (value != null) return value;
    }

    // A `[PcVariables]` entry lives on the host rather than on a page. The
    // tune holds those, seeded from their factory values: Speeduino's
    // board-capability tables are of this kind, and menu entries are gated
    // on them.
    final host = tune.readHost(base, index);
    if (host != null) return host;

    // A factory value declared for something that is neither - a page
    // constant whose bytes could not be read - is still better than nothing.
    final defaults = tune.definition.defaultValues[base];
    if (defaults != null && index >= 0 && index < defaults.length) {
      return defaults[index];
    }

    if (indexed == null) {
      final expression = _computed[name];
      if (expression != null) return expression.evaluate(resolve);
    }

    return null;
  }

  double? _fromPage(
    int page,
    IniField field, {
    required int index,
    required bool wasIndexed,
  }) {
    switch (field) {
      case IniBitsField():
        return tune.readBits(page, field)?.toDouble();

      case IniScalarField(:final scale, :final translate):
        return _scaled(tune.readRaw(page, field), scale, translate);

      case IniArrayField(:final scale, :final translate):
        // A bare array name has no single value; only an indexed reference
        // is asking something this can answer.
        if (!wasIndexed) return null;
        return _scaled(tune.readRaw(page, field, index), scale, translate);
    }
  }

  /// Applies a field's scale and translate, following expressions where used.
  ///
  /// Reading the scale as a literal would be wrong often enough to matter:
  /// several constants declare `scale = {fuelLoadRes}` or similar, and a
  /// literal-only reading silently reports them as unavailable - which on a
  /// settings screen is a field that shows nothing.
  double? _scaled(int? raw, IniScalarValue scale, IniScalarValue translate) {
    if (raw == null) return null;
    final s = valueOf(scale);
    final t = valueOf(translate);
    if (s == null || t == null) return null;
    return raw * s + t;
  }

  /// Evaluates [value] to a number, following expressions where needed.
  double? valueOf(IniScalarValue? value) => switch (value) {
        null => null,
        IniLiteral(:final value) => value,
        IniExpression(:final source) => _compiled
            .putIfAbsent(source, () => CompiledExpression.tryCompile(source))
            ?.evaluate(resolve),
      };

  /// Discards cached lookups. Call after the tune changes.
  ///
  /// Compiled expressions survive: the source text they came from is part of
  /// the definition, which does not change while a tune is open.
  void invalidate() => _cache.clear();
}
