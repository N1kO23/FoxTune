import 'package:foxtune_ini/foxtune_ini.dart';

import 'tune_state.dart';
import 'value_resolver.dart';

/// An editable view of one named constant, in engineering units.
///
/// This is to a settings dialog what [TableView] is to a table: the one place
/// that knows how a definition's declaration turns into a number a tuner reads
/// and a number the ECU stores. A dialog is then a list of these, and nothing
/// above this layer has to think about scale factors, bit positions or which
/// page a setting lives on.
///
/// Three shapes are covered, because those are the three the definition has:
///
/// - a **scalar**, scaled and translated, bounded by the declared `lo`/`hi`;
/// - a **bitfield**, an index into its own list of option labels, written back
///   without disturbing the unrelated settings packed into the same byte;
/// - an **array element**, addressed by [index].
///
/// A constant may live on a page or, for a `[PcVariables]` entry, on the
/// tuning computer - gauge warning thresholds and the selector choosing which
/// programmable output a dialog edits. Both read and write the same way
/// through this view; [isHostSide] says which, because a host-side value is
/// never burned and a tuner should not be told otherwise.
class SettingView {
  SettingView._({
    required this.tune,
    required this.resolver,
    required this.page,
    required this.field,
    required this.index,
  });

  /// Builds a view of the constant named [constant].
  ///
  /// Returns `null` when the definition has no such constant, or declares one
  /// in a shape this does not model - the aux-channel aliases are `string`
  /// variables, which have no numeric value to edit.
  static SettingView? of(
    TuneState tune,
    String constant, {
    TuneValueResolver? resolver,
    int index = 0,
  }) {
    final located = tune.locate(constant);
    final IniField? field = located?.field.offset == null
        ? _hostField(tune, constant)
        : located!.field;
    if (field == null) return null;

    if (field is IniArrayField && (index < 0 || index >= field.length)) {
      return null;
    }

    return SettingView._(
      tune: tune,
      resolver: resolver ?? TuneValueResolver(tune),
      page: located?.field.offset == null ? null : located!.page,
      field: field,
      index: index,
    );
  }

  static IniField? _hostField(TuneState tune, String name) {
    for (final variable in tune.definition.pcVariables) {
      if (variable.name == name) return variable;
    }
    return null;
  }

  final TuneState tune;
  final TuneValueResolver resolver;

  /// 1-based page the constant lives on, or `null` when it is host-side.
  final int? page;

  /// Whether this value lives on the tuning computer rather than on the ECU.
  ///
  /// Host-side values are never written or burned, so a caller showing "burn
  /// to apply" must not show it for one of these.
  bool get isHostSide => page == null;

  /// The declaration this view projects.
  final IniField field;

  /// Element index, for an array field. Zero otherwise.
  final int index;

  /// The constant's name, as the definition and a `.msq` spell it.
  String get name => field.name;

  /// Help text from `[SettingContextHelp]`, where the definition supplies it.
  String? get help => tune.definition.helpFor(name);

  /// Whether the ECU must be power-cycled before a change takes effect.
  bool get requiresPowerCycle =>
      tune.definition.requiresPowerCycle.contains(name);

  // --- Enumerated settings -------------------------------------------------

  /// Whether this is a choice between named options rather than a number.
  bool get isEnumerated => field is IniBitsField && options.isNotEmpty;

  /// Option labels, with the trailing `INVALID` padding removed.
  ///
  /// The definition pads a bit field's option list out to the full width its
  /// bits can represent - a two-bit field with three real choices is padded
  /// with one `INVALID` - and offering that as a fourth choice would let a
  /// tuner select a value the firmware rejects.
  List<String> get options {
    final bits = field;
    if (bits is! IniBitsField) return const [];
    final labels = bits.options;
    var end = labels.length;
    while (end > 0 && labels[end - 1] == 'INVALID') {
      end--;
    }
    return labels.sublist(0, end);
  }

  /// The selected option index, or `null` when this is not enumerated.
  int? get optionIndex {
    final bits = field;
    if (bits is! IniBitsField) return null;
    final at = page;
    // A host-side bitfield has no byte to unpack, so its value is simply the
    // number stored for it.
    if (at == null) return tune.readHost(name, index)?.round();
    return tune.readBits(at, bits);
  }

  /// The selected option's label, or `null` when there is none.
  String? get optionLabel {
    final at = optionIndex;
    if (at == null || at < 0 || at >= options.length) return null;
    return options[at];
  }

  /// Selects the option at [selection].
  ///
  /// Out-of-range selections are rejected rather than clamped: unlike a
  /// numeric setting, the nearest valid option is not a sensible substitute
  /// for the one asked for.
  void setOptionIndex(int selection) {
    final bits = field;
    if (bits is! IniBitsField) {
      throw StateError('$name is not an enumerated setting');
    }
    if (selection < 0 || selection >= options.length) {
      throw RangeError('Option $selection is outside 0..${options.length - 1} '
          'for $name');
    }
    final at = page;
    if (at == null) {
      tune.writeHost(name, selection.toDouble(), index);
    } else {
      tune.writeBits(at, bits, selection);
    }
  }

  // --- Numeric settings ----------------------------------------------------

  /// Units label, e.g. `rpm` or `kPa`. Empty where the definition gives none.
  String get units => switch (field) {
        IniScalarField(:final units) => units,
        IniArrayField(:final units) => units,
        _ => '',
      };

  /// Decimal places the definition asks for.
  int get decimals => switch (field) {
        IniScalarField(:final digits) => digits ?? 0,
        IniArrayField(:final digits) => digits ?? 0,
        _ => 0,
      };

  /// Lowest value the definition permits, in engineering units.
  double? get low => resolver.valueOf(switch (field) {
        IniScalarField(:final low) => low,
        IniArrayField(:final low) => low,
        _ => null,
      });

  /// Highest value the definition permits, in engineering units.
  double? get high => resolver.valueOf(switch (field) {
        IniScalarField(:final high) => high,
        IniArrayField(:final high) => high,
        _ => null,
      });

  /// Smallest change the storage can represent, in engineering units.
  double get step => _scale.abs();

  double get _scale {
    final scale = resolver.valueOf(switch (field) {
      IniScalarField(:final scale) => scale,
      IniArrayField(:final scale) => scale,
      _ => null,
    });
    return scale == null || scale == 0 ? 1 : scale;
  }

  double get _translate =>
      resolver.valueOf(switch (field) {
        IniScalarField(:final translate) => translate,
        IniArrayField(:final translate) => translate,
        _ => null,
      }) ??
      0;

  /// The current value in engineering units.
  ///
  /// For an enumerated setting this is the raw option index, which is what the
  /// definition's own conditions compare against.
  double? get value {
    if (field is IniBitsField) return optionIndex?.toDouble();
    final at = page;
    // A host-side value is already in engineering units; there are no stored
    // bytes for a scale to convert from.
    if (at == null) return tune.readHost(name, index);
    final raw = tune.readRaw(at, field, index);
    if (raw == null) return null;
    return raw * _scale + _translate;
  }

  /// Writes [newValue], clamped to the definition's declared bounds.
  ///
  /// Clamping rather than rejecting matches the table editor, and keeps a
  /// mistyped entry from reaching the ECU as an out-of-range number.
  void setValue(double newValue) {
    if (field is IniBitsField) {
      setOptionIndex(newValue.round());
      return;
    }
    final clamped = clampToBounds(newValue);
    final at = page;
    if (at == null) {
      tune.writeHost(name, clamped, index);
      return;
    }
    tune.writeRaw(at, field, ((clamped - _translate) / _scale).round(), index);
  }

  /// Clamps [candidate] into the definition's declared bounds.
  double clampToBounds(double candidate) {
    var result = candidate;
    final lo = low;
    final hi = high;
    if (lo != null && result < lo) result = lo;
    if (hi != null && result > hi) result = hi;
    return result;
  }

  /// The value formatted the way the definition asks for it to be shown.
  ///
  /// An enumerated setting reads as its option label; a number reads at the
  /// declared precision, without units. Returns `null` when the value cannot
  /// be read at all, so a caller can say so rather than print a zero.
  String? get displayText {
    if (isEnumerated) return optionLabel;
    final current = value;
    if (current == null) return null;
    return current.toStringAsFixed(decimals);
  }

  @override
  String toString() =>
      'SettingView($name ${isHostSide ? 'host-side' : 'on page $page'})';
}
