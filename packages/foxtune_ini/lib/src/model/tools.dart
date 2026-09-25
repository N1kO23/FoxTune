/// What a high-speed logger records.
enum IniLoggerKind {
  /// The time between one trigger tooth and the next.
  tooth,

  /// Trigger input levels and events, each with the time it happened.
  composite,

  /// A trigger logger, as TunerStudio names some.
  trigger,

  /// Rows of any values.
  csv,

  /// A kind the definition names that is none of these.
  unknown;

  static IniLoggerKind parse(String name) =>
      values.asNameMap()[name.trim()] ?? unknown;
}

/// One field of a logger record, from a `recordField` line.
class IniLoggerField {
  const IniLoggerField({
    required this.name,
    required this.label,
    required this.startBit,
    required this.bitCount,
    required this.scale,
    required this.units,
  });

  final String name;
  final String label;

  /// Where the field lies in a record read as one big-endian number, bit 0
  /// being the lowest bit of the record's last byte.
  ///
  /// That is how both firmwares lay their records out for TunerStudio:
  /// Speeduino sends a composite record as a big-endian time followed by a
  /// byte of flags, and the definition puts the flags at bits 0 to 7 and the
  /// time from bit 8.
  final int startBit;

  final int bitCount;
  final double scale;
  final String units;

  /// Whether this is a single on-or-off bit - a trigger input's level, or
  /// whether sync is held.
  bool get isFlag => bitCount == 1;

  @override
  String toString() => 'recordField $name @$startBit+$bitCount';
}

/// A value worked out from each record, from a `calcField` line.
class IniLoggerCalc {
  const IniLoggerCalc({
    required this.name,
    required this.label,
    required this.units,
    required this.expression,
    this.hidden = false,
  });

  final String name;
  final String label;
  final String units;

  /// The expression's source, braces removed.
  final String expression;

  /// Worked out only for other fields to use, not to show.
  final bool hidden;
}

/// A high-speed logger the ECU offers, from `[LoggerDefinition]`: the tooth
/// and composite loggers TunerStudio shows for diagnosing a trigger.
class IniLogger {
  const IniLogger({
    required this.id,
    required this.label,
    required this.kind,
    this.startCommand,
    this.stopCommand,
    this.readCommand,
    this.readTimeout,
    this.continuousRead = false,
    this.readyCondition,
    this.dataLength,
    this.headerLength = 0,
    this.footerLength = 0,
    this.recordLength = 0,
    this.fields = const [],
    this.calcs = const [],
  });

  final String id;
  final String label;
  final IniLoggerKind kind;

  /// Command templates, as the page commands are written.
  final String? startCommand;
  final String? stopCommand;
  final String? readCommand;

  /// How long to wait for the ECU to have a log ready.
  final Duration? readTimeout;

  /// Whether the log is read again and again until stopped, rather than once.
  final bool continuousRead;

  /// The expression, over the live channels, that says a log is ready to be
  /// read; braces removed.
  final String? readyCondition;

  /// What the definition gives as the log's length. Speeduino's gives bytes
  /// for one logger and records for another, so the reply's own length is
  /// what counts.
  final int? dataLength;

  /// Bytes before the first record, and after the last.
  final int headerLength;
  final int footerLength;

  /// Bytes in each record.
  final int recordLength;

  final List<IniLoggerField> fields;
  final List<IniLoggerCalc> calcs;

  IniLoggerField? fieldNamed(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }

  @override
  String toString() => 'loggerDef $id ($kind, $recordLength-byte records)';
}

/// A sensor's calibration, from a `thermOption` line: the bias resistor it is
/// read through, and three temperatures with its resistance at each.
class IniThermistor {
  const IniThermistor({
    required this.name,
    required this.biasOhms,
    required this.points,
  });

  final String name;
  final double biasOhms;

  /// Three temperatures in degrees Celsius, each with the sensor's
  /// resistance at it in ohms.
  final List<({double celsius, double ohms})> points;
}

/// One way a calibration table can be made, from a `tableGenerator` line.
class IniTableGenerator {
  const IniTableGenerator({
    required this.type,
    required this.label,
    this.xUnits,
    this.yUnits,
    this.xLow,
    this.xHigh,
    this.yLow,
    this.yHigh,
  });

  /// `thermGenerator`, `linearGenerator` or `fileBrowseGenerator`, as
  /// Speeduino's definition names them.
  final String type;
  final String label;

  /// For a linear generator: its units, and the two points it starts from.
  final String? xUnits;
  final String? yUnits;
  final double? xLow;
  final double? xHigh;
  final double? yLow;
  final double? yHigh;
}

/// One way to fill a calibration table, from a `solution` line: an
/// expression over the ADC reading, or one of the table's generators.
class IniCalibrationSolution {
  const IniCalibrationSolution({
    required this.label,
    this.expression,
    this.generator,
  });

  final String label;

  /// The expression over `adcValue`, from 0 to 1023, braces removed; empty
  /// for the blank row a definition puts first.
  final String? expression;

  /// The [IniTableGenerator.type] that fills the table instead.
  final String? generator;
}

/// A table the ECU keeps outside its pages, from a `referenceTable` line: a
/// sensor calibration, made by the tuning software rather than edited cell
/// by cell.
class IniReferenceTable {
  const IniReferenceTable({
    required this.id,
    required this.label,
    this.helpUrl,
    this.targets = const [],
    this.limits = const {},
    required this.adcCount,
    required this.bytesPerAdc,
    required this.scale,
    this.generators = const [],
    this.thermistors = const [],
    this.solutionsLabel,
    this.solutions = const [],
  });

  /// The menu target that opens it, such as `std_ms2gentherm`.
  final String id;
  final String label;
  final String? helpUrl;

  /// The tables it can write, by the identifier the ECU knows each by.
  final List<({int id, String label})> targets;

  /// Per identifier, the range a value must fall in, and what stands in for
  /// one outside it - in the units the table is sent in.
  final Map<int, ({double min, double max, double fallback})> limits;

  /// Values in the table: one per ADC step, from 0 to 1023.
  final int adcCount;

  /// Bytes per value, as sent.
  final int bytesPerAdc;

  /// What each value is multiplied by before it is sent.
  final double scale;

  final List<IniTableGenerator> generators;
  final List<IniThermistor> thermistors;

  /// What the [solutions] are a choice of, such as "EGO Sensor".
  final String? solutionsLabel;
  final List<IniCalibrationSolution> solutions;

  IniTableGenerator? generatorOf(String type) {
    for (final generator in generators) {
      if (generator.type == type) return generator;
    }
    return null;
  }
}

/// `[ReferenceTables]`: the sensor calibrations, and how they are sent.
class IniReferenceTables {
  const IniReferenceTables({
    this.writeCommand,
    this.blockingFactor,
    this.tables = const [],
  });

  /// The command template a table is written with.
  final String? writeCommand;

  /// The most bytes of a table sent at once.
  final int? blockingFactor;

  final List<IniReferenceTable> tables;

  IniReferenceTable? tableNamed(String id) {
    for (final table in tables) {
      if (table.id == id) return table;
    }
    return null;
  }
}
