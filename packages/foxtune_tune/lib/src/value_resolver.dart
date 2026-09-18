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
    // A constant stored on a page takes precedence: it is the real setting.
    final located = tune.locate(name);
    if (located != null) {
      final field = located.field;
      final raw = tune.readRaw(located.page, field);
      if (raw == null) return null;

      switch (field) {
        case IniBitsField(:final lowBit, :final highBit):
          final width = highBit - lowBit + 1;
          return ((raw >> lowBit) & ((1 << width) - 1)).toDouble();
        case IniScalarField(:final scale, :final translate):
          final s = scale.literalValue;
          final t = translate.literalValue;
          if (s == null || t == null) return null;
          return raw * s + t;
        case IniArrayField():
          // An array has no single value; an expression referencing one is
          // asking for something this cannot answer.
          return null;
      }
    }

    final expression = _computed[name];
    if (expression != null) return expression.evaluate(resolve);

    return null;
  }

  /// Evaluates [value] to a number, following expressions where needed.
  double? valueOf(IniScalarValue? value) => switch (value) {
        null => null,
        IniLiteral(:final value) => value,
        IniExpression(:final source) =>
          CompiledExpression.tryCompile(source)?.evaluate(resolve),
      };

  /// Discards cached lookups. Call after the tune changes.
  void invalidate() => _cache.clear();
}
