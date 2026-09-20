import 'package:xml/xml.dart';

import 'table_view.dart';

/// One table's axes and values, as held in a `.table` file.
class TableFileData {
  const TableFileData({
    required this.xBins,
    required this.yBins,
    required this.values,
    this.xName = '',
    this.yName = '',
  });

  /// X axis bins, in the order the file lists them.
  final List<double> xBins;

  /// Y axis bins, in the order the file lists them.
  final List<double> yBins;

  /// Rows of Z values, aligned to [yBins].
  final List<List<double>> values;

  /// Axis names recorded in the file, for display only.
  final String xName;
  final String yName;

  int get columns => xBins.length;
  int get rows => yBins.length;

  @override
  String toString() => 'TableFileData(${rows}x$columns)';
}

/// What happened when a `.table` file was applied to a table.
class TableImportResult {
  const TableImportResult({
    required this.cellsWritten,
    required this.resampled,
    required this.axesWritten,
    required this.sourceShape,
    required this.targetShape,
  });

  final int cellsWritten;

  /// Whether the values had to be interpolated onto the target's axes.
  final bool resampled;

  /// Whether the target's axis bins were overwritten from the file.
  final bool axesWritten;

  final String sourceShape;
  final String targetShape;

  @override
  String toString() => 'TableImportResult($cellsWritten cells, '
      'resampled: $resampled, axes: $axesWritten)';
}

/// Thrown when a `.table` file cannot be read.
class TableFileException implements Exception {
  TableFileException(this.message);

  final String message;

  @override
  String toString() => 'TableFileException: $message';
}

/// Reads and writes TunerStudio `.table` files - a single table's axes and
/// values, as opposed to `.msq`, which carries a whole tune.
///
/// The structure follows TunerStudio's: a `<tableData>` root holding
/// `<bibliography>`, `<versionInfo>` and a `<table>` of `<xAxis>`, `<yAxis>`
/// and `<zValues>`. Axis bins are one value per line; Z values are one row per
/// line, space separated.
///
/// Rows are written in the same order as `<yAxis>`, which this writer emits
/// ascending. On read the order is taken from the file's own axis rather than
/// assumed, so a file written the other way round still loads correctly.
abstract final class TableFileCodec {
  /// Namespace TunerStudio puts on the root element.
  static const String namespace = 'http://www.EFIAnalytics.com/:table';

  /// File format version written into `<versionInfo>`.
  static const String fileFormat = '1.0';

  /// Serialises [view] as a `.table` document.
  static String encode(
    TableView view, {
    String author = 'FoxTune',
    DateTime? writeDate,
  }) {
    final xBins = [
      for (var c = 0; c < view.columns; c++) view.xAt(c) ?? 0,
    ];
    final yBins = [
      for (var r = 0; r < view.rows; r++) view.yAt(r) ?? 0,
    ];

    final xDecimals = decimalsFor(digits: view.xDecimals, step: view.xStep);
    final yDecimals = decimalsFor(digits: view.yDecimals, step: view.yStep);
    final zDecimals = decimalsFor(digits: view.zDecimals, step: view.zStep);

    final out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8" standalone="no"?>')
      ..writeln('<tableData xmlns="$namespace">')
      ..writeln('    <bibliography author="${_attr(author)}" '
          'writeDate="${_attr((writeDate ?? DateTime.now()).toString())}"/>')
      ..writeln('    <versionInfo fileFormat="$fileFormat"/>')
      ..writeln('    <table cols="${view.columns}" rows="${view.rows}">');

    out.writeln('        <xAxis cols="${view.columns}" '
        'name="${_attr(view.table.xBins.constant)}">');
    for (final bin in xBins) {
      out.writeln('            ${_number(bin, xDecimals)}');
    }
    out.writeln('        </xAxis>');

    out.writeln('        <yAxis name="${_attr(view.table.yBins.constant)}" '
        'rows="${view.rows}">');
    for (final bin in yBins) {
      out.writeln('            ${_number(bin, yDecimals)}');
    }
    out.writeln('        </yAxis>');

    out.writeln('        <zValues cols="${view.columns}" '
        'rows="${view.rows}">');
    // Rows in the same order as <yAxis>, which is ascending.
    for (var r = 0; r < view.rows; r++) {
      final cells = [
        for (var c = 0; c < view.columns; c++)
          _number(view.valueAt(r, c) ?? 0, zDecimals),
      ];
      out.writeln('            ${cells.join(' ')}');
    }
    out.writeln('        </zValues>');

    out
      ..writeln('    </table>')
      ..writeln('</tableData>');
    return out.toString();
  }

  /// Parses a `.table` document.
  static TableFileData decode(String xml) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw TableFileException('Not a valid XML document: ${e.message}');
    }

    final root = document.rootElement;
    if (root.name.local != 'tableData') {
      throw TableFileException(
          'Root element is <${root.name.local}>, expected <tableData>');
    }

    final table = root.findAllElements('table').firstOrNull;
    if (table == null) throw TableFileException('No <table> element');

    final xAxis = table.findAllElements('xAxis').firstOrNull;
    final yAxis = table.findAllElements('yAxis').firstOrNull;
    final zValues = table.findAllElements('zValues').firstOrNull;
    if (xAxis == null || yAxis == null || zValues == null) {
      throw TableFileException('A table needs <xAxis>, <yAxis> and <zValues>');
    }

    final xBins = _numbers(xAxis.innerText, 'xAxis');
    final yBins = _numbers(yAxis.innerText, 'yAxis');
    if (xBins.isEmpty || yBins.isEmpty) {
      throw TableFileException('The axes are empty');
    }

    final rows = <List<double>>[];
    for (final line in zValues.innerText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      rows.add(_numbers(trimmed, 'zValues'));
    }

    if (rows.length != yBins.length) {
      throw TableFileException(
          'The file has ${rows.length} value rows but ${yBins.length} Y bins');
    }
    for (final row in rows) {
      if (row.length != xBins.length) {
        throw TableFileException(
            'A value row has ${row.length} entries but there are '
            '${xBins.length} X bins');
      }
    }

    // The file's own axis order decides how its rows and columns are read, so
    // a file written high-to-low still lands the right way up.
    var orderedX = xBins;
    var orderedY = yBins;
    var orderedRows = rows;

    if (xBins.length > 1 && xBins.first > xBins.last) {
      orderedX = xBins.reversed.toList();
      orderedRows = [
        for (final row in orderedRows) row.reversed.toList(),
      ];
    }
    if (yBins.length > 1 && yBins.first > yBins.last) {
      orderedY = yBins.reversed.toList();
      orderedRows = orderedRows.reversed.toList();
    }

    return TableFileData(
      xBins: orderedX,
      yBins: orderedY,
      values: orderedRows,
      xName: xAxis.getAttribute('name') ?? '',
      yName: yAxis.getAttribute('name') ?? '',
    );
  }

  /// Writes [data] into [view].
  ///
  /// When the shapes match, values are copied cell for cell. When they differ,
  /// the source is **resampled** onto the destination's axes by bilinear
  /// interpolation - importing a 12x12 table into a 16x16 one is a normal
  /// thing to want, and refusing would be less useful than interpolating.
  ///
  /// Set [importAxes] to take the file's axis bins as well. That is only
  /// possible when the shapes match; otherwise the destination's own axes are
  /// what the values are resampled onto.
  static TableImportResult applyTo(
    TableView view,
    TableFileData data, {
    bool importAxes = false,
  }) {
    final sameShape = data.rows == view.rows && data.columns == view.columns;

    if (sameShape && importAxes) {
      for (var c = 0; c < view.columns; c++) {
        view.setXAt(c, data.xBins[c]);
      }
      for (var r = 0; r < view.rows; r++) {
        view.setYAt(r, data.yBins[r]);
      }
    }

    var written = 0;
    if (sameShape) {
      for (var r = 0; r < view.rows; r++) {
        for (var c = 0; c < view.columns; c++) {
          view.setValueAt(r, c, data.values[r][c]);
          written++;
        }
      }
    } else {
      for (var r = 0; r < view.rows; r++) {
        final y = view.yAt(r);
        for (var c = 0; c < view.columns; c++) {
          final x = view.xAt(c);
          if (x == null || y == null) continue;
          view.setValueAt(r, c, sampleAt(data, x, y));
          written++;
        }
      }
    }

    return TableImportResult(
      cellsWritten: written,
      resampled: !sameShape,
      axesWritten: sameShape && importAxes,
      sourceShape: '${data.rows}x${data.columns}',
      targetShape: '${view.rows}x${view.columns}',
    );
  }

  /// Bilinearly samples [data] at ([x], [y]) in axis units.
  ///
  /// Outside the source's axes the edge values are held rather than
  /// extrapolated: inventing fuel beyond the range someone actually tuned is
  /// not a safe guess.
  static double sampleAt(TableFileData data, double x, double y) {
    final (c0, c1, fc) = _bracket(data.xBins, x);
    final (r0, r1, fr) = _bracket(data.yBins, y);

    final lower =
        data.values[r0][c0] + (data.values[r0][c1] - data.values[r0][c0]) * fc;
    final upper =
        data.values[r1][c0] + (data.values[r1][c1] - data.values[r1][c0]) * fc;
    return lower + (upper - lower) * fr;
  }

  /// Indices bracketing [target] in ascending [bins], plus the fraction.
  static (int, int, double) _bracket(List<double> bins, double target) {
    if (bins.length == 1) return (0, 0, 0);
    if (target <= bins.first) return (0, 0, 0);
    if (target >= bins.last) return (bins.length - 1, bins.length - 1, 0);

    for (var i = 0; i < bins.length - 1; i++) {
      if (target >= bins[i] && target <= bins[i + 1]) {
        final span = bins[i + 1] - bins[i];
        return (i, i + 1, span == 0 ? 0.0 : (target - bins[i]) / span);
      }
    }
    return (bins.length - 1, bins.length - 1, 0);
  }

  static List<double> _numbers(String text, String where) {
    final values = <double>[];
    for (final token in text.split(RegExp(r'\s+'))) {
      if (token.isEmpty) continue;
      final value = double.tryParse(token);
      if (value == null) {
        throw TableFileException('"$token" in <$where> is not a number');
      }
      values.add(value);
    }
    return values;
  }

  static String _number(double value, int decimals) =>
      value.toStringAsFixed(decimals);

  /// Decimal places needed to write a value without losing precision.
  ///
  /// The definition's `digits` is a *display* hint and can be coarser than the
  /// storage step: a field scaled by 0.5 but declared with 0 digits would have
  /// every half count rounded away on export, so a round trip would silently
  /// alter the tune. Writing more decimals than TunerStudio does costs
  /// nothing - the values are plain numbers either way.
  static int decimalsFor({required int digits, required double step}) {
    var needed = 0;
    var scaled = step.abs();
    while (needed < 6 && scaled != scaled.roundToDouble()) {
      scaled *= 10;
      needed++;
    }
    return needed > digits ? needed : digits;
  }

  static String _attr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
