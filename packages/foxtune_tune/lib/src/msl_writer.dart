import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

/// Formats realtime samples as a MegaLogViewer-compatible `.msl` log.
///
/// `.msl` is a tab-separated text file: two quoted banner lines, a row of
/// column headings, a row of units, then one row per sample.
///
/// Which columns appear, what they are called and how they are formatted all
/// come from the definition's `[Datalog]` section rather than from FoxTune,
/// because tools like MegaLogViewer key off specific column names.
class MslLogWriter {
  MslLogWriter._({
    required this.signature,
    required this.columns,
    required this.units,
    required this.dropped,
  });

  /// Builds a writer for [definition].
  ///
  /// Columns are decided once, up front:
  ///
  /// * an entry whose `[Datalog]` condition evaluates to false is left out, so
  ///   a log does not carry columns for hardware that is not fitted;
  /// * an entry that cannot produce a value from [probe] is also left out,
  ///   rather than writing a column that would be blank for the whole log.
  ///
  /// Everything excluded is listed in [dropped] so it is visible rather than
  /// quietly missing.
  factory MslLogWriter.forDefinition(
    IniDocument definition, {
    RealtimeSnapshot? probe,
    double? Function(String name)? constantResolver,
  }) {
    final columns = <IniDatalogEntry>[];
    final dropped = <String>[];

    for (final entry in definition.datalog) {
      final condition = entry.condition;
      if (condition != null) {
        final compiled = CompiledExpression.tryCompile(condition);
        // An unevaluable condition is kept: better an extra column than a
        // silently missing one.
        final result = compiled
            ?.evaluate((name) => probe?[name] ?? constantResolver?.call(name));
        if (result != null && result == 0) {
          dropped.add(entry.channel);
          continue;
        }
      }

      if (probe != null &&
          entry.channel != _timeChannel &&
          probe[entry.channel] == null) {
        dropped.add(entry.channel);
        continue;
      }
      columns.add(entry);
    }

    return MslLogWriter._(
      signature: definition.identity.signature ?? 'unknown',
      columns: columns,
      units: {
        for (final entry in columns)
          entry.channel: definition.outputChannels.channelNamed(entry.channel)
                  is IniScalarField
              ? (definition.outputChannels.channelNamed(entry.channel)!
                      as IniScalarField)
                  .units
              : _computedUnits(definition, entry.channel),
      },
      dropped: dropped,
    );
  }

  /// The `time` column is supplied by the recorder's own clock, not the ECU.
  static const String _timeChannel = 'time';

  /// Signature written into the log banner.
  final String signature;

  /// Columns actually written, in order.
  final List<IniDatalogEntry> columns;

  /// Units per channel, for the units row.
  final Map<String, String> units;

  /// Channels excluded, and why they would have been blank.
  final List<String> dropped;

  static String _computedUnits(IniDocument definition, String channel) =>
      definition.outputChannels.computedNamed(channel)?.units ?? '';

  /// The four header lines, newline-terminated.
  String header({DateTime? capturedAt}) {
    final when = capturedAt ?? DateTime.now();
    final buffer = StringBuffer()
      ..writeln('"$signature"')
      ..writeln('"Capture Date: ${when.toUtc().toIso8601String()}"')
      ..writeln([for (final c in columns) c.label].join('\t'))
      ..writeln([for (final c in columns) units[c.channel] ?? ''].join('\t'));
    return buffer.toString();
  }

  /// One data row for [snapshot], newline-terminated.
  ///
  /// [elapsed] is the time since recording began, which is what the `Time`
  /// column means in a log - the ECU's own clock is not a wall clock.
  String row(RealtimeSnapshot snapshot, Duration elapsed) {
    final cells = <String>[];
    for (final column in columns) {
      if (column.channel == _timeChannel) {
        cells.add((elapsed.inMicroseconds / 1000000)
            .toStringAsFixed(column.decimals));
        continue;
      }
      final value = snapshot[column.channel];
      if (value == null) {
        // Blank rather than a fabricated zero: an absent reading is not a
        // reading of zero, and a plot should show the gap.
        cells.add('');
        continue;
      }
      cells.add(column.type == IniDatalogType.integer
          ? value.round().toString()
          : value.toStringAsFixed(column.decimals));
    }
    return '${cells.join('\t')}\n';
  }
}
