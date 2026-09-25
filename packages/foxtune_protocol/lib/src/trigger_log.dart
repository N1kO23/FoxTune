import 'package:foxtune_ini/foxtune_ini.dart';

/// One capture from a high-speed logger, decoded as the definition lays its
/// records out.
///
/// A tooth log is the time from each trigger tooth to the next; a composite
/// log is every edge on the trigger inputs, each with the time it happened
/// and the level of every input just after it. Either shows what the ECU
/// sees of the trigger wheel, which is what finding a missing tooth, a noisy
/// input or a cam in the wrong place comes down to.
class TriggerLog {
  TriggerLog._(this.logger, this.records, this.captured);

  /// Decodes [data], a logger's reply, as [logger] describes it.
  ///
  /// Records an ECU pads a short capture out with are left off. Speeduino
  /// answers with its whole buffer whether or not it filled: zeroes after the
  /// last tooth of a tooth log, and for a composite log copies of the last
  /// time with no inputs set.
  factory TriggerLog.decode(
    IniLogger logger,
    List<int> data, {
    DateTime? captured,
  }) {
    final size = logger.recordLength;
    final records = <TriggerLogRecord>[];
    if (size > 0) {
      final end = data.length - logger.footerLength;
      for (var at = logger.headerLength; at + size <= end; at += size) {
        final record = data.sublist(at, at + size);
        records.add(
          TriggerLogRecord({
            for (final field in logger.fields)
              field.name:
                  _bits(record, field.startBit, field.bitCount) * field.scale,
          }),
        );
      }
    }
    _trimPadding(logger, records);
    return TriggerLog._(logger, records, captured ?? DateTime.now());
  }

  /// The logger this came from.
  final IniLogger logger;

  final List<TriggerLogRecord> records;

  /// When it was read.
  final DateTime captured;

  /// Whether nothing was captured - no teeth, from an engine not turning.
  bool get isEmpty => records.isEmpty;

  /// The on-or-off fields - trigger input levels, and whether sync is held -
  /// in the definition's order.
  List<IniLoggerField> get flagFields => [
        for (final field in logger.fields)
          if (field.isFlag) field,
      ];

  /// The flags that change during this capture: the traces worth drawing.
  ///
  /// One that never changes is an input with nothing wired to it, or one
  /// this trigger pattern does not use - rusEFI's record has room for eight
  /// coils and eight injectors whether or not the engine has them.
  List<IniLoggerField> get changingFlags => [
        for (final field in flagFields)
          if (records.any((r) => r.isSet(field.name)) &&
              records.any((r) => !r.isSet(field.name)))
            field,
      ];

  /// The time from each tooth to the next, in milliseconds.
  ///
  /// A tooth logger's own `toothTime` where the record carries one, as
  /// Speeduino's does; otherwise the time between one record and the next,
  /// which is how TunerStudio's `toothTime` is defined for a composite log.
  List<double> get toothTimes {
    final tooth = logger.fieldNamed('toothTime');
    if (tooth != null) {
      final unit = _millisecondsPer(tooth.units);
      return [for (final r in records) r[tooth.name]! * unit];
    }
    final times = this.times;
    if (times == null) return const [];
    return [for (var i = 1; i < times.length; i++) times[i] - times[i - 1]];
  }

  /// Each record's time, in milliseconds from the first, or `null` for a
  /// record with no time in it.
  ///
  /// A composite log's `refTime`, or a tooth log's tooth times added up.
  List<double>? get times {
    final ref = logger.fieldNamed('refTime');
    if (ref != null) {
      if (records.isEmpty) return const [];
      final unit = _millisecondsPer(ref.units);
      final start = records.first[ref.name]!;
      return [for (final r in records) (r[ref.name]! - start) * unit];
    }
    if (logger.fieldNamed('toothTime') == null) return null;
    var total = 0.0;
    return [
      for (final tooth in toothTimes) total += tooth,
    ];
  }

  /// The capture as comma-separated values: a header of the definition's
  /// field labels, then one row per record.
  String toCsv() {
    final fields = logger.fields;
    final buffer = StringBuffer()
      ..writeln(fields.map((f) => _csvCell(f.label)).join(','));
    for (final record in records) {
      buffer.writeln(
        fields.map((f) => _number(record[f.name] ?? 0)).join(','),
      );
    }
    return buffer.toString();
  }

  /// Bits [start] to [start] + [count] of [record] read as one big-endian
  /// number, bit 0 being the lowest bit of its last byte.
  ///
  /// Built up by multiplying rather than shifting, so a 32-bit field is
  /// still exact where integers are doubles.
  static int _bits(List<int> record, int start, int count) {
    var value = 0;
    for (var i = count - 1; i >= 0; i--) {
      final bit = start + i;
      final byte = record.length - 1 - bit ~/ 8;
      final set = byte >= 0 && (record[byte] >> (bit % 8)) & 1 == 1;
      value = value * 2 + (set ? 1 : 0);
    }
    return value;
  }

  static void _trimPadding(IniLogger logger, List<TriggerLogRecord> records) {
    final tooth = logger.fieldNamed('toothTime');
    if (tooth != null) {
      while (records.isNotEmpty && records.last[tooth.name] == 0) {
        records.removeLast();
      }
      return;
    }
    final ref = logger.fieldNamed('refTime');
    if (ref == null) return;
    final flags = [
      for (final field in logger.fields)
        if (field.isFlag) field.name,
    ];
    while (records.isNotEmpty) {
      final last = records.last;
      final before = records.length > 1 ? records[records.length - 2] : null;
      final repeated = before == null
          ? last[ref.name] == 0
          : last[ref.name] == before[ref.name];
      if (!repeated || flags.any(last.isSet)) break;
      records.removeLast();
    }
  }

  static double _millisecondsPer(String units) =>
      switch (units.trim().toLowerCase()) {
        'us' || 'µs' || 'usec' => 0.001,
        's' || 'sec' => 1000,
        _ => 1,
      };

  static String _number(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(3);

  static String _csvCell(String text) => text.contains(RegExp('[",\n]'))
      ? '"${text.replaceAll('"', '""')}"'
      : text;
}

/// One record of a capture: each of the logger's fields, scaled.
class TriggerLogRecord {
  const TriggerLogRecord(this.values);

  final Map<String, double> values;

  double? operator [](String field) => values[field];

  /// Whether the on-or-off field [flag] is on.
  bool isSet(String flag) => (values[flag] ?? 0) != 0;

  @override
  String toString() => 'TriggerLogRecord($values)';
}
