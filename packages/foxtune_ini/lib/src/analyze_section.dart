/// Parser for `[VeAnalyze]`, the definition's description of VE autotuning.
///
/// Stateful in the same way the section is: a `veAnalyzeMap` line opens the
/// description and the `filter` lines after it belong to it.
library;

import 'model/analyze.dart';
import 'tokenizer.dart';

/// Builds an [IniVeAnalyze] from `[VeAnalyze]` lines.
class AnalyzeCollector {
  String? _table;
  String _targetTable = '';
  String _measuredChannel = '';
  String _egoChannel = '';
  String? _activeCondition;
  List<String> _lambdaTargetTables = const [];
  final List<IniAnalyzeFilter> _filters = [];

  /// The parsed section, or `null` when the file declares none.
  IniVeAnalyze? get result {
    final table = _table;
    if (table == null || table.isEmpty) return null;
    return IniVeAnalyze(
      table: table,
      targetTable: _targetTable,
      measuredChannel: _measuredChannel,
      egoCorrectionChannel: _egoChannel,
      activeCondition: _activeCondition,
      lambdaTargetTables: List.unmodifiable(_lambdaTargetTables),
      filters: List.unmodifiable(_filters),
    );
  }

  /// Feeds one `key = value` line.
  void add(String key, String value) {
    switch (key) {
      case 'veAnalyzeMap':
        final tokens = splitTopLevel(value);
        // A second declaration replaces the first: the file declares one per
        // `#if LAMBDA` branch, and only the surviving branch should count.
        _table = tokens.isNotEmpty ? unquote(tokens[0]) : null;
        _targetTable = tokens.length > 1 ? unquote(tokens[1]) : '';
        _measuredChannel = tokens.length > 2 ? unquote(tokens[2]) : '';
        _egoChannel = tokens.length > 3 ? unquote(tokens[3]) : '';
        _activeCondition = tokens.length > 4 && isBraceGroup(tokens[4])
            ? braceContents(tokens[4])
            : null;

      case 'lambdaTargetTables':
        _lambdaTargetTables = [
          for (final token in splitTopLevel(value))
            if (unquote(token).isNotEmpty) unquote(token),
        ];

      case 'filter':
        final filter = parseFilter(value);
        if (filter != null) _filters.add(filter);
    }
  }

  /// Parses `id[, "Label", channel, op, value[, value2], flag]`.
  ///
  /// The trailing arguments are read by shape rather than by position: the
  /// shipped definition writes both a six- and a seven-argument form, with
  /// `[VeAnalyze]` leaving an empty slot where `[WueAnalyze]` leaves none.
  /// Counting from the left would read the boolean as a threshold on half the
  /// lines in the file.
  static IniAnalyzeFilter? parseFilter(String value) {
    final tokens = splitTopLevel(value);
    if (tokens.isEmpty) return null;

    final id = unquote(tokens.first);
    if (id.isEmpty) return null;

    // A standard filter is a bare name; the host builds it from the table's
    // own axes and the sensor's plausible range.
    if (tokens.length == 1) {
      return IniAnalyzeFilter(id: id, label: '');
    }

    final label = tokens.length > 1 ? unquote(tokens[1]) : '';
    final channel = tokens.length > 2 ? unquote(tokens[2]) : '';
    final operator =
        tokens.length > 3 ? IniFilterOperator.tryParse(tokens[3]) : null;

    var flag = false;
    final numbers = <double>[];
    for (final token in tokens.skip(4)) {
      final text = unquote(token).trim().toLowerCase();
      if (text.isEmpty) continue;
      if (text == 'true' || text == 'false') {
        flag = text == 'true';
        continue;
      }
      final parsed = double.tryParse(text);
      if (parsed != null) numbers.add(parsed);
    }

    return IniAnalyzeFilter(
      id: id,
      label: label,
      channel: channel,
      operator: operator,
      value: numbers.isNotEmpty ? numbers[0] : null,
      value2: numbers.length > 1 ? numbers[1] : null,
      flag: flag,
    );
  }
}
