import '../data_type.dart';

/// A named entry in an ECU definition section.
///
/// The same three shapes - scalar, bits, array - appear in `[Constants]`,
/// `[OutputChannels]` and `[PcVariables]`, but with different argument lists:
/// `[PcVariables]` entries carry no byte offset, and `[OutputChannels]` entries
/// carry no display bounds. [offset] and the bounds are therefore nullable
/// rather than being invented where the file does not supply them.
sealed class IniField {
  const IniField({
    required this.name,
    required this.type,
    required this.offset,
    this.comment,
  });

  /// The identifier used to reference this field elsewhere in the file.
  final String name;

  /// Storage type on the wire.
  final IniDataType type;

  /// Byte offset within its page, or `null` for sections that do not place
  /// their entries in a page (`[PcVariables]`).
  final int? offset;

  /// Trailing `;` comment from the source line, if any.
  final String? comment;

  /// Total bytes this field occupies.
  int get sizeInBytes;
}

/// A single numeric value.
final class IniScalarField extends IniField {
  const IniScalarField({
    required super.name,
    required super.type,
    required super.offset,
    required this.units,
    required this.scale,
    required this.translate,
    this.low,
    this.high,
    this.digits,
    super.comment,
  });

  /// Display units, e.g. `rpm` or `kPa`. May be empty.
  final String units;

  /// Multiplier applied to the raw value.
  final IniScalarValue scale;

  /// Offset added after scaling.
  final IniScalarValue translate;

  /// Lower display bound, where the section supplies one.
  final IniScalarValue? low;

  /// Upper display bound, where the section supplies one.
  final IniScalarValue? high;

  /// Decimal places to display.
  final int? digits;

  @override
  int get sizeInBytes => type.bytes;

  /// Converts a raw value to engineering units.
  ///
  /// Returns `null` when [scale] or [translate] is an unevaluated expression,
  /// because guessing at a conversion factor would silently misreport a
  /// sensor reading.
  double? toDisplay(num raw) {
    final s = scale.literalValue;
    final t = translate.literalValue;
    if (s == null || t == null) return null;
    return raw * s + t;
  }

  @override
  String toString() => 'scalar $name @$offset ${type.token}';
}

/// A bitfield packed into part of a byte or word.
final class IniBitsField extends IniField {
  const IniBitsField({
    required super.name,
    required super.type,
    required super.offset,
    required this.lowBit,
    required this.highBit,
    required this.options,
    super.comment,
  });

  /// First bit index, inclusive.
  final int lowBit;

  /// Last bit index, inclusive.
  final int highBit;

  /// Labels indexed by raw value. Empty for `[OutputChannels]` flags, which
  /// declare a bit position but no labels.
  final List<String> options;

  /// Number of bits this field spans.
  int get bitCount => highBit - lowBit + 1;

  /// How many distinct values the field can hold.
  int get valueCount => 1 << bitCount;

  /// Whether [options] covers every representable value.
  ///
  /// A short list mislabels values past its end, so this is worth asserting
  /// on definitions that are meant to be complete.
  bool get hasCompleteOptions =>
      options.isEmpty || options.length >= valueCount;

  @override
  int get sizeInBytes => type.bytes;

  /// The label for [raw], or `null` if out of range or unlabelled.
  String? labelFor(int raw) =>
      raw >= 0 && raw < options.length ? options[raw] : null;

  @override
  String toString() => 'bits $name @$offset [$lowBit:$highBit]';
}

/// A one- or two-dimensional array of values.
final class IniArrayField extends IniField {
  const IniArrayField({
    required super.name,
    required super.type,
    required super.offset,
    required this.shape,
    required this.units,
    required this.scale,
    required this.translate,
    this.low,
    this.high,
    this.digits,
    super.comment,
  });

  /// `[n]` yields `[n]`; `[n x m]` yields `[n, m]`.
  final List<int> shape;

  /// Display units. May be empty.
  final String units;

  /// Multiplier applied to each raw element.
  final IniScalarValue scale;

  /// Offset added after scaling.
  final IniScalarValue translate;

  /// Lower display bound, where supplied.
  final IniScalarValue? low;

  /// Upper display bound, where supplied.
  final IniScalarValue? high;

  /// Decimal places to display.
  final int? digits;

  /// Total element count across all dimensions.
  int get length => shape.fold(1, (a, b) => a * b);

  /// Whether this is a 2D table rather than a 1D list.
  bool get isTable => shape.length > 1;

  @override
  int get sizeInBytes => length * type.bytes;

  @override
  String toString() => 'array $name @$offset ${shape.join("x")} ${type.token}';
}
