/// Scalar storage types used by TunerStudio ECU definitions.
enum IniDataType {
  u08('U08', bytes: 1, signed: false),
  s08('S08', bytes: 1, signed: true),
  u16('U16', bytes: 2, signed: false),
  s16('S16', bytes: 2, signed: true),
  u32('U32', bytes: 4, signed: false),
  s32('S32', bytes: 4, signed: true),
  f32('F32', bytes: 4, signed: true);

  const IniDataType(this.token, {required this.bytes, required this.signed});

  /// The literal token as it appears in the file, e.g. `U16`.
  final String token;

  /// Width in bytes on the wire.
  final int bytes;

  /// Whether the type is two's-complement signed.
  final bool signed;

  /// Whether this is an IEEE-754 float rather than an integer.
  bool get isFloat => this == IniDataType.f32;

  /// Parses a type token, case-insensitively.
  ///
  /// Throws [ArgumentError] on an unknown token - an unrecognised type would
  /// silently corrupt every offset after it, so it must not be skipped.
  static IniDataType parse(String token) {
    final normalised = token.trim().toUpperCase();
    for (final type in IniDataType.values) {
      if (type.token == normalised) return type;
    }
    throw ArgumentError.value(token, 'token', 'Unknown INI data type');
  }

  /// Parses a type token, returning `null` rather than throwing.
  static IniDataType? tryParse(String token) {
    final normalised = token.trim().toUpperCase();
    for (final type in IniDataType.values) {
      if (type.token == normalised) return type;
    }
    return null;
  }
}

/// A numeric field in an ECU definition: either a literal, or a `{ ... }`
/// expression that TunerStudio evaluates at runtime.
///
/// Expressions such as `{ 0.1 / stoich }` reference other constants, so they
/// cannot be reduced at parse time. They are preserved verbatim and left for a
/// later evaluation pass rather than being silently dropped.
sealed class IniScalarValue {
  const IniScalarValue();

  /// Parses a raw token into a literal or an expression.
  factory IniScalarValue.parse(String token) {
    final trimmed = token.trim();
    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      return IniExpression(trimmed.substring(1, trimmed.length - 1).trim());
    }
    final value = double.tryParse(trimmed);
    if (value == null) {
      // Bare identifiers appear where a constant is referenced directly.
      return IniExpression(trimmed);
    }
    return IniLiteral(value);
  }

  /// The literal value, or `null` when this is an unevaluated expression.
  double? get literalValue;
}

/// A numeric literal.
final class IniLiteral extends IniScalarValue {
  const IniLiteral(this.value);

  final double value;

  @override
  double? get literalValue => value;

  @override
  bool operator ==(Object other) => other is IniLiteral && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

/// An unevaluated `{ ... }` expression, stored verbatim.
final class IniExpression extends IniScalarValue {
  const IniExpression(this.source);

  final String source;

  @override
  double? get literalValue => null;

  @override
  bool operator ==(Object other) =>
      other is IniExpression && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => '{ $source }';
}
