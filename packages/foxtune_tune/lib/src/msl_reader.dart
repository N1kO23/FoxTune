import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

/// A MegaLogViewer `.msl` log, read back.
///
/// The layout is the one [MslLogWriter] writes and TunerStudio's text logs
/// share: quoted banner lines, a tab-separated row of column headings, usually
/// a row of units, then one row per sample. TunerStudio also writes `MARK`
/// lines where the tuner pressed the marker button; those, and any other line
/// that is not a row of numbers, are counted in [skippedLines] and passed over.
///
/// Columns are parsed when first asked for rather than up front. A rusEFI log
/// carries around a thousand of them and a replay reads perhaps twenty:
/// parsing them all would hold hundreds of megabytes for nothing.
class MslLog {
  MslLog._({
    required this.banner,
    required this.labels,
    required this.units,
    required this.skippedLines,
    required String text,
    required Int32List rowStarts,
    required Int32List rowEnds,
  })  : _text = text,
        _rowStarts = rowStarts,
        _rowEnds = rowEnds;

  /// Reads [text] as a log.
  ///
  /// Throws [FormatException] when there is no row of column headings.
  factory MslLog.parse(String text) {
    final banner = <String>[];
    List<String>? labels;
    List<String>? units;
    final starts = <int>[];
    final ends = <int>[];
    var skipped = 0;

    var start = 0;
    while (start < text.length) {
      var end = text.indexOf('\n', start);
      if (end < 0) end = text.length;
      final next = end + 1;
      if (end > start && text.codeUnitAt(end - 1) == 0x0D) end--;

      if (end > start) {
        final line = text.substring(start, end);
        if (labels == null) {
          if (!line.startsWith('"') && line.contains('\t')) {
            labels = _cells(line);
          } else {
            banner.add(_unquote(line));
          }
        } else if (_startsWithNumber(line)) {
          starts.add(start);
          ends.add(end);
        } else if (units == null && starts.isEmpty) {
          units = _cells(line);
        } else {
          skipped++;
        }
      }
      start = next;
    }

    if (labels == null) {
      throw const FormatException(
        'No row of column headings was found, so this is not a MegaLogViewer '
        'log.',
      );
    }
    return MslLog._(
      banner: banner,
      labels: labels,
      units: [
        for (var i = 0; i < labels.length; i++)
          units != null && i < units.length ? units[i] : '',
      ],
      skippedLines: skipped,
      text: text,
      rowStarts: Int32List.fromList(starts),
      rowEnds: Int32List.fromList(ends),
    );
  }

  /// Lines before the headings, quotes removed: the signature and capture
  /// date, as FoxTune and TunerStudio write them.
  final List<String> banner;

  /// Column headings, in order.
  final List<String> labels;

  /// Each column's units, `''` where the log gives none.
  final List<String> units;

  /// Lines among the rows that were not rows - `MARK` lines, mostly.
  final int skippedLines;

  final String _text;
  final Int32List _rowStarts;
  final Int32List _rowEnds;
  final Map<int, Float64List> _columns = {};

  /// Rows of data.
  int get rowCount => _rowStarts.length;

  /// The first column headed [label], or `null`.
  int? indexOf(String label) {
    final index = labels.indexOf(label);
    return index < 0 ? null : index;
  }

  /// The value in [column] at [row], or `null` where the cell is blank.
  double? valueAt(int row, int column) {
    final value = this.column(column)[row];
    return value.isNaN ? null : value;
  }

  /// Every value in [index], `NaN` where a cell is blank or not a number.
  Float64List column(int index) {
    final cached = _columns[index];
    if (cached != null) return cached;
    load([index]);
    return _columns[index]!;
  }

  /// Parses [indexes] in one pass over the rows, rather than one pass each.
  void load(Iterable<int> indexes) {
    final wanted = {
      for (final index in indexes)
        if (index >= 0 && index < labels.length && !_columns.containsKey(index))
          index,
    };
    if (wanted.isEmpty) return;

    final last = wanted.reduce((a, b) => a > b ? a : b);
    final parsed = {
      for (final index in wanted)
        index: Float64List(rowCount)..fillRange(0, rowCount, double.nan),
    };

    for (var row = 0; row < rowCount; row++) {
      final end = _rowEnds[row];
      var start = _rowStarts[row];
      for (var cell = 0; cell <= last; cell++) {
        var tab = _text.indexOf('\t', start);
        if (tab < 0 || tab > end) tab = end;
        final values = parsed[cell];
        if (values != null) {
          values[row] =
              double.tryParse(_text.substring(start, tab).trim()) ?? double.nan;
        }
        if (tab == end) break;
        start = tab + 1;
      }
    }
    _columns.addAll(parsed);
  }

  static List<String> _cells(String line) =>
      [for (final cell in line.split('\t')) _unquote(cell.trim())];

  static String _unquote(String text) {
    final trimmed = text.trim();
    return trimmed.length >= 2 &&
            trimmed.startsWith('"') &&
            trimmed.endsWith('"')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }

  static bool _startsWithNumber(String line) {
    final tab = line.indexOf('\t');
    final first = tab < 0 ? line : line.substring(0, tab);
    return double.tryParse(first.trim()) != null;
  }
}

/// A log's columns, read as the definition's channels.
///
/// A column is matched to its channel by the heading `[Datalog]` gives it,
/// which is what both FoxTune and TunerStudio write. A channel the log did not
/// record is computed from ones it did, where the definition says how -
/// rusEFI's `veAnalyzeAfrLambda1` is
/// `{ useLambdaOnInterface ? lambdaValue : afrGasolineScale }` - and a tune
/// constant in such an expression comes from [constantResolver].
class MslChannels {
  MslChannels(this.log, this.definition, {this.constantResolver}) {
    final byLabel = <String, List<String>>{};
    for (final entry in definition.datalog) {
      byLabel.putIfAbsent(entry.label, () => []).add(entry.channel);
    }
    final names = definition.outputChannels.allNames;

    // Two entries can share a heading; the log then has it twice, in the
    // same order.
    final taken = <String, int>{};
    for (var i = 0; i < log.labels.length; i++) {
      final label = log.labels[i];
      final candidates = byLabel[label] ?? const [];
      final n = taken[label] ?? 0;
      taken[label] = n + 1;

      final channel = n < candidates.length
          ? candidates[n]
          // A heading that is a channel's own name: an entry whose label is an
          // expression is written under its channel's name.
          : names.contains(label)
              ? label
              : null;
      if (channel == null || columns.containsKey(channel)) {
        unmatched.add(label);
        continue;
      }
      columns[channel] = i;
    }
  }

  final MslLog log;
  final IniDocument definition;

  /// Supplies tune constants that computed channels refer to.
  final double? Function(String name)? constantResolver;

  /// The column each recorded channel is in.
  final Map<String, int> columns = {};

  /// Headings that match no channel of the definition.
  final List<String> unmatched = [];

  final Map<String, CompiledExpression?> _compiled = {};

  /// The units the log gives [channel], `''` where it gives none or did not
  /// record it.
  String unitsOf(String channel) {
    final column = columns[channel];
    return column == null ? '' : log.units[column];
  }

  /// Parses, in one pass, every column reading [names] will need - including
  /// those a computed channel among them is worked out from.
  ///
  /// Only an optimisation: a column not prepared is parsed when first read.
  void prepare(Iterable<String> names) {
    final wanted = <int>{};
    final seen = <String>{};
    void visit(String name) {
      if (!seen.add(name)) return;
      final column = columns[name];
      if (column != null) {
        wanted.add(column);
        return;
      }
      _expression(name)?.references.forEach(visit);
    }

    names.forEach(visit);
    log.load(wanted);
  }

  /// Reads channels at [row], in engineering units.
  ///
  /// A recorded channel is read from its cell, blank as `null`: the log saying
  /// nothing is not a reason to work the value out some other way.
  double? Function(String name) row(int row) {
    final cache = <String, double?>{};
    final resolving = <String>{};

    double? read(String name) {
      if (cache.containsKey(name)) return cache[name];
      // A definition could define channels in terms of each other circularly;
      // refuse rather than recurse forever.
      if (!resolving.add(name)) return null;
      try {
        final column = columns[name];
        final double? value;
        if (column != null) {
          value = log.valueAt(row, column);
        } else if (definition.outputChannels.computedNamed(name) != null) {
          value = _expression(name)?.evaluate(read);
        } else {
          value = constantResolver?.call(name);
        }
        cache[name] = value;
        return value;
      } finally {
        resolving.remove(name);
      }
    }

    return read;
  }

  CompiledExpression? _expression(String name) => _compiled.putIfAbsent(
        name,
        () {
          final computed = definition.outputChannels.computedNamed(name);
          return computed == null
              ? null
              : CompiledExpression.tryCompile(computed.expression);
        },
      );
}
