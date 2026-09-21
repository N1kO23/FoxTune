/// Parsers for `[GaugeConfigurations]` and `[FrontPage]`.
library;

import 'data_type.dart';
import 'model/dialogs.dart';
import 'model/gauges.dart';
import 'tokenizer.dart';
import 'ui_sections.dart';

/// Builds gauges from `[GaugeConfigurations]` lines.
class GaugeCollector {
  // Keyed by name so a later declaration replaces an earlier one, the way the
  // rest of the definition resolves duplicates.
  final Map<String, IniGauge> _gauges = {};
  String _category = '';

  /// The gauges, in declaration order.
  List<IniGauge> get gauges => List.unmodifiable(_gauges.values);

  /// Feeds one `key = value` line.
  void add(String key, String value) {
    if (key == 'gaugeCategory') {
      _category = unquote(value);
      return;
    }
    final gauge = parseGauge(key, value, category: _category);
    if (gauge != null) _gauges[gauge.name] = gauge;
  }

  /// Parses `name = channel, title, units, lo, hi, loD, loW, hiW, hiD, vd, ld`.
  ///
  /// Read loosely, because the shipped file is loose: `systemTempGauge` leaves
  /// out the commas between its first three arguments. A line that stops
  /// before its bands keeps its gauge with those bands absent - a gauge with
  /// no warning point simply never warns - rather than losing the gauge.
  static IniGauge? parseGauge(
    String name,
    String value, {
    String category = '',
  }) {
    final atoms = splitArguments(value);
    if (name.isEmpty || atoms.length < 5) return null;

    final channel = unquote(atoms[0]);
    if (channel.isEmpty) return null;

    final title = _text(atoms[1]);
    final units = _text(atoms[2]);

    IniScalarValue? number(int index) =>
        index < atoms.length ? IniScalarValue.parse(atoms[index]) : null;
    int digits(int index) =>
        index < atoms.length ? int.tryParse(atoms[index].trim()) ?? 0 : 0;

    final lo = number(3);
    final hi = number(4);
    if (lo == null || hi == null) return null;

    return IniGauge(
      name: name,
      channel: channel,
      title: title.text,
      titleExpression: title.expression,
      units: units.text,
      unitsExpression: units.expression,
      lo: lo,
      hi: hi,
      loDanger: number(5),
      loWarning: number(6),
      hiWarning: number(7),
      hiDanger: number(8),
      valueDigits: digits(9),
      labelDigits: digits(10),
      category: category,
    );
  }

  /// Splits a title or units argument into literal text or an expression.
  static ({String text, String? expression}) _text(String atom) =>
      isBraceGroup(atom)
          ? (text: '', expression: braceContents(atom))
          : (text: unquote(atom), expression: null);
}

/// Builds the default dashboard from `[FrontPage]` lines.
class FrontPageCollector {
  final Map<int, String> _slots = {};
  final List<IniDialogIndicator> _indicators = [];

  /// The front page as declared.
  IniFrontPage get frontPage {
    final order = _slots.keys.toList()..sort();
    return IniFrontPage(
      gauges: [for (final slot in order) _slots[slot]!],
      indicators: List.unmodifiable(_indicators),
    );
  }

  /// Feeds one `key = value` line.
  void add(String key, String value) {
    final slot = RegExp(r'^gauge(\d+)$').firstMatch(key);
    if (slot != null) {
      final name = unquote(value);
      if (name.isNotEmpty) _slots[int.parse(slot.group(1)!)] = name;
      return;
    }
    if (key == 'indicator') {
      final indicator = parseIndicator(value);
      if (indicator != null) _indicators.add(indicator);
    }
  }
}
