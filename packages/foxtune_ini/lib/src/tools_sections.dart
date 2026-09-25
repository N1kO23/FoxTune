import 'model/tools.dart';
import 'tokenizer.dart';

/// Reads `[LoggerDefinition]`: each `loggerDef` line starts a logger, and the
/// lines after it, up to the next, describe it.
List<IniLogger> parseLoggers(List<String> lines) {
  final loggers = <IniLogger>[];
  _Logger? current;

  for (final line in lines) {
    final assignment = splitAssignment(line);
    if (assignment == null) continue;
    final value = assignment.value;
    final args = splitTopLevel(value);

    if (assignment.key == 'loggerDef') {
      if (current != null) loggers.add(current.build());
      current = args.length < 2
          ? null
          : _Logger(
              args[0].trim(),
              unquote(args[1]),
              IniLoggerKind.parse(args.length > 2 ? args[2] : ''),
            );
      continue;
    }
    final logger = current;
    if (logger == null) continue;

    switch (assignment.key) {
      case 'startCommand':
        logger.start = unquote(value);
      case 'stopCommand':
        logger.stop = unquote(value);
      case 'dataReadCommand':
        logger.read = unquote(value);
      case 'dataReadTimeout':
        final ms = int.tryParse(value.trim());
        if (ms != null) logger.timeout = Duration(milliseconds: ms);
      case 'continuousRead':
        logger.continuous = value.trim().toLowerCase() == 'true';
      case 'dataReadyCondition':
        logger.ready = isBraceGroup(value) ? braceContents(value) : value;
      case 'dataLength':
        logger.length = int.tryParse(value.trim());
      case 'recordDef':
        final sizes = [for (final a in args) int.tryParse(a.trim())];
        if (sizes.length >= 3 && sizes.every((s) => s != null)) {
          logger
            ..header = sizes[0]!
            ..footer = sizes[1]!
            ..record = sizes[2]!;
        }
      case 'recordField':
        if (args.length < 6) continue;
        final start = int.tryParse(args[2].trim());
        final count = int.tryParse(args[3].trim());
        final scale = double.tryParse(args[4].trim());
        if (start == null || count == null || scale == null) continue;
        logger.fields.add(
          IniLoggerField(
            name: args[0].trim(),
            label: unquote(args[1]),
            startBit: start,
            bitCount: count,
            scale: scale,
            units: unquote(args[5]),
          ),
        );
      case 'calcField':
        if (args.length < 4 || !isBraceGroup(args[3])) continue;
        logger.calcs.add(
          IniLoggerCalc(
            name: args[0].trim(),
            label: unquote(args[1]),
            units: unquote(args[2]),
            expression: braceContents(args[3]),
            hidden: args.skip(4).any((a) => a.trim() == 'hidden'),
          ),
        );
    }
  }
  if (current != null) loggers.add(current.build());
  return loggers;
}

class _Logger {
  _Logger(this.id, this.label, this.kind);

  final String id;
  final String label;
  final IniLoggerKind kind;
  String? start;
  String? stop;
  String? read;
  Duration? timeout;
  bool continuous = false;
  String? ready;
  int? length;
  int header = 0;
  int footer = 0;
  int record = 0;
  final fields = <IniLoggerField>[];
  final calcs = <IniLoggerCalc>[];

  IniLogger build() => IniLogger(
        id: id,
        label: label,
        kind: kind,
        startCommand: start,
        stopCommand: stop,
        readCommand: read,
        readTimeout: timeout,
        continuousRead: continuous,
        readyCondition: ready,
        dataLength: length,
        headerLength: header,
        footerLength: footer,
        recordLength: record,
        fields: List.unmodifiable(fields),
        calcs: List.unmodifiable(calcs),
      );
}

/// Reads `[ReferenceTables]`: the command tables are written with, and each
/// `referenceTable` with the lines after it.
IniReferenceTables? parseReferenceTables(List<String>? lines) {
  if (lines == null) return null;
  String? writeCommand;
  int? blockingFactor;
  final tables = <IniReferenceTable>[];
  _Reference? current;

  for (final line in lines) {
    final assignment = splitAssignment(line);
    if (assignment == null) continue;
    final value = assignment.value;
    final args = splitTopLevel(value);

    switch (assignment.key) {
      case 'tableWriteCommand':
        writeCommand = unquote(args.first);
        continue;
      case 'tableBlockingFactor':
        blockingFactor = int.tryParse(value.trim());
        continue;
      case 'referenceTable':
        if (current != null) tables.add(current.build());
        current = args.length < 2
            ? null
            : _Reference(args[0].trim(), unquote(args[1]));
        continue;
    }
    final table = current;
    if (table == null) continue;
    double? number(int i) =>
        i < args.length ? double.tryParse(args[i].trim()) : null;

    switch (assignment.key) {
      case 'topicHelp':
        table.help = unquote(value);
      case 'tableIdentifier':
        for (var i = 0; i + 1 < args.length; i += 2) {
          final id = int.tryParse(args[i].trim());
          if (id != null) {
            table.targets.add((id: id, label: unquote(args[i + 1])));
          }
        }
      case 'tableLimits':
        final id = int.tryParse(args.first.trim());
        final (min, max, fallback) = (number(1), number(2), number(3));
        if (id != null && min != null && max != null && fallback != null) {
          table.limits[id] = (min: min, max: max, fallback: fallback);
        }
      case 'adcCount':
        table.adcCount = int.tryParse(value.trim()) ?? table.adcCount;
      case 'bytesPerAdc':
        table.bytesPerAdc = int.tryParse(value.trim()) ?? table.bytesPerAdc;
      case 'scale':
        table.scale = double.tryParse(value.trim()) ?? table.scale;
      case 'tableGenerator':
        if (args.length < 2) continue;
        table.generators.add(
          IniTableGenerator(
            type: args[0].trim(),
            label: unquote(args[1]),
            xUnits: args.length > 2 ? unquote(args[2]) : null,
            yUnits: args.length > 3 ? unquote(args[3]) : null,
            xLow: number(4),
            xHigh: number(5),
            yLow: number(6),
            yHigh: number(7),
          ),
        );
      case 'thermOption':
        final values = [for (var i = 1; i < 8; i++) number(i)];
        if (args.length < 8 || values.any((v) => v == null)) continue;
        table.thermistors.add(
          IniThermistor(
            name: unquote(args[0]),
            biasOhms: values[0]!,
            points: [
              for (var i = 1; i < 7; i += 2)
                (celsius: values[i]!, ohms: values[i + 1]!),
            ],
          ),
        );
      case 'solutionsLabel':
        table.solutionsLabel = unquote(value);
      case 'solution':
        if (args.length < 2) continue;
        final how = args[1].trim();
        table.solutions.add(
          isBraceGroup(how)
              ? IniCalibrationSolution(
                  label: unquote(args[0]),
                  expression: braceContents(how),
                )
              : IniCalibrationSolution(
                  label: unquote(args[0]),
                  generator: how,
                ),
        );
    }
  }
  if (current != null) tables.add(current.build());
  return IniReferenceTables(
    writeCommand: writeCommand,
    blockingFactor: blockingFactor,
    tables: tables,
  );
}

class _Reference {
  _Reference(this.id, this.label);

  final String id;
  final String label;
  String? help;
  final targets = <({int id, String label})>[];
  final limits = <int, ({double min, double max, double fallback})>{};
  int adcCount = 0;
  int bytesPerAdc = 1;
  double scale = 1;
  final generators = <IniTableGenerator>[];
  final thermistors = <IniThermistor>[];
  String? solutionsLabel;
  final solutions = <IniCalibrationSolution>[];

  IniReferenceTable build() => IniReferenceTable(
        id: id,
        label: label,
        helpUrl: help,
        targets: List.unmodifiable(targets),
        limits: Map.unmodifiable(limits),
        adcCount: adcCount,
        bytesPerAdc: bytesPerAdc,
        scale: scale,
        generators: List.unmodifiable(generators),
        thermistors: List.unmodifiable(thermistors),
        solutionsLabel: solutionsLabel,
        solutions: List.unmodifiable(solutions),
      );
}
