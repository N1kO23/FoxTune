@TestOn('vm')
library;

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

/// A table definition of the given shape, with generous bounds so imports are
/// not silently clamped in tests that are not about clamping.
String source({
  required int rows,
  required int columns,
  double zHigh = 255,
}) {
  final z = rows * columns;
  return '''
[MegaTune]
signature = "t"
[Constants]
endianness = little
nPages   = 1
pageSize = ${z + rows + columns + 8}
page = 1
  zTable = array, U08, 0, [${rows}x$columns], "%",   1.0,   0.0, 0.0, $zHigh, 0
  xAxis  = array, U08, $z, [$columns],        "RPM", 100.0, 0.0, 0.0, 25500.0, 0
  yAxis  = array, U08, ${z + columns}, [$rows], "kPa", 2.0, 0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "T", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''';
}

({TuneState tune, TableView view}) build({
  int rows = 3,
  int columns = 3,
  List<int>? z,
  List<int>? x,
  List<int>? y,
}) {
  final doc = IniParser().parse(source(rows: rows, columns: columns));
  final tune = TuneState.empty(doc);
  final zf = tune.locate('zTable')!;
  final xf = tune.locate('xAxis')!;
  final yf = tune.locate('yAxis')!;

  final zData = z ?? [for (var i = 0; i < rows * columns; i++) i + 1];
  final xData = x ?? [for (var i = 0; i < columns; i++) 10 * (i + 1)];
  final yData = y ?? [for (var i = 0; i < rows; i++) 5 * (i + 1)];

  for (var i = 0; i < zData.length; i++) {
    tune.writeRaw(zf.page, zf.field, zData[i], i);
  }
  for (var i = 0; i < xData.length; i++) {
    tune.writeRaw(xf.page, xf.field, xData[i], i);
  }
  for (var i = 0; i < yData.length; i++) {
    tune.writeRaw(yf.page, yf.field, yData[i], i);
  }
  tune.markClean();
  return (tune: tune, view: TableView.of(tune, doc.tables.single)!);
}

void main() {
  group('encode', () {
    late XmlDocument document;
    late TableView view;

    setUpAll(() {
      view = build().view;
      document = XmlDocument.parse(TableFileCodec.encode(view));
    });

    test('has the TunerStudio document shape', () {
      expect(document.rootElement.name.local, 'tableData');
      expect(
          document.rootElement.getAttribute('xmlns'), TableFileCodec.namespace);
      expect(document.findAllElements('bibliography'), hasLength(1));
      expect(
        document.findAllElements('versionInfo').single.getAttribute(
              'fileFormat',
            ),
        TableFileCodec.fileFormat,
      );
    });

    test('records the shape on the elements', () {
      final table = document.findAllElements('table').single;
      expect(table.getAttribute('cols'), '3');
      expect(table.getAttribute('rows'), '3');
      expect(
        document.findAllElements('zValues').single.getAttribute('cols'),
        '3',
      );
    });

    test('writes the axes in engineering units, ascending', () {
      List<double> axis(String name) => document
          .findAllElements(name)
          .single
          .innerText
          .trim()
          .split(RegExp(r'\s+'))
          .map(double.parse)
          .toList();

      expect(axis('xAxis'), [1000, 2000, 3000]);
      expect(axis('yAxis'), [10, 20, 30]);
    });

    test('writes one row of values per Y bin, matching the axis order', () {
      final rows = document
          .findAllElements('zValues')
          .single
          .innerText
          .trim()
          .split('\n')
          .map((l) => l.trim().split(RegExp(r'\s+')).map(double.parse).toList())
          .toList();

      expect(rows, hasLength(3));
      // Row 0 is the lowest Y, as <yAxis> lists it first.
      expect(rows.first, [
        view.valueAt(0, 0),
        view.valueAt(0, 1),
        view.valueAt(0, 2),
      ]);
      expect(rows.last, [
        view.valueAt(2, 0),
        view.valueAt(2, 1),
        view.valueAt(2, 2),
      ]);
    });

    test('names the axes from the definition', () {
      expect(document.findAllElements('xAxis').single.getAttribute('name'),
          'xAxis');
      expect(document.findAllElements('yAxis').single.getAttribute('name'),
          'yAxis');
    });
  });

  group('decode', () {
    test('round-trips a table exactly', () {
      final original = build();
      final data = TableFileCodec.decode(TableFileCodec.encode(original.view));

      expect(data.rows, 3);
      expect(data.columns, 3);
      expect(data.xBins, [1000, 2000, 3000]);
      expect(data.yBins, [10, 20, 30]);
      expect(data.values, original.view.toGrid());
    });

    test('reads a descending Y axis the right way up', () {
      // A writer that lists its axis high-to-low must still land correctly,
      // so orientation is taken from the file rather than assumed.
      const xml = '''
<tableData>
  <table cols="2" rows="2">
    <xAxis cols="2" name="rpm">1000 2000</xAxis>
    <yAxis rows="2" name="map">20 10</yAxis>
    <zValues cols="2" rows="2">
      7 8
      5 6
    </zValues>
  </table>
</tableData>
''';
      final data = TableFileCodec.decode(xml);
      expect(data.yBins, [10, 20], reason: 'presented ascending');
      expect(
          data.values,
          [
            [5, 6],
            [7, 8],
          ],
          reason: 'rows follow the axis they were written against');
    });

    test('reads a descending X axis the right way round', () {
      const xml = '''
<tableData>
  <table cols="2" rows="2">
    <xAxis cols="2" name="rpm">2000 1000</xAxis>
    <yAxis rows="2" name="map">10 20</yAxis>
    <zValues cols="2" rows="2">
      6 5
      8 7
    </zValues>
  </table>
</tableData>
''';
      final data = TableFileCodec.decode(xml);
      expect(data.xBins, [1000, 2000]);
      expect(data.values, [
        [5, 6],
        [7, 8],
      ]);
    });

    test('rejects a document that is not a table file', () {
      expect(() => TableFileCodec.decode('<msq/>'),
          throwsA(isA<TableFileException>()));
      expect(() => TableFileCodec.decode('not xml at all'),
          throwsA(isA<TableFileException>()));
    });

    test('rejects a file missing an axis', () {
      const xml = '''
<tableData><table cols="1" rows="1">
  <xAxis>1000</xAxis>
  <zValues>5</zValues>
</table></tableData>
''';
      expect(
          () => TableFileCodec.decode(xml), throwsA(isA<TableFileException>()));
    });

    test('rejects a value grid that does not match its axes', () {
      // Silently accepting a ragged grid would scatter values across the map.
      const xml = '''
<tableData><table cols="2" rows="2">
  <xAxis>1000 2000</xAxis>
  <yAxis>10 20</yAxis>
  <zValues>
    1 2
    3 4
    5 6
  </zValues>
</table></tableData>
''';
      expect(
          () => TableFileCodec.decode(xml), throwsA(isA<TableFileException>()));
    });

    test('rejects a row of the wrong width', () {
      const xml = '''
<tableData><table cols="2" rows="2">
  <xAxis>1000 2000</xAxis>
  <yAxis>10 20</yAxis>
  <zValues>
    1 2
    3 4 5
  </zValues>
</table></tableData>
''';
      expect(
          () => TableFileCodec.decode(xml), throwsA(isA<TableFileException>()));
    });

    test('rejects a non-numeric value', () {
      const xml = '''
<tableData><table cols="1" rows="1">
  <xAxis>1000</xAxis>
  <yAxis>10</yAxis>
  <zValues>banana</zValues>
</table></tableData>
''';
      expect(
          () => TableFileCodec.decode(xml), throwsA(isA<TableFileException>()));
    });
  });

  group('applyTo, matching shapes', () {
    test('copies every cell', () {
      final from = build(z: [for (var i = 0; i < 9; i++) 100 + i]);
      final into = build();
      final result = TableFileCodec.applyTo(
          into.view,
          TableFileCodec.decode(
            TableFileCodec.encode(from.view),
          ));

      expect(result.resampled, isFalse);
      expect(result.cellsWritten, 9);
      expect(into.view.toGrid(), from.view.toGrid());
      expect(into.tune.isDirty, isTrue);
    });

    test('leaves the axes alone by default', () {
      final from = build(x: [50, 60, 70], y: [40, 45, 50]);
      final into = build();
      final before = [for (var c = 0; c < 3; c++) into.view.xAt(c)];

      TableFileCodec.applyTo(
        into.view,
        TableFileCodec.decode(TableFileCodec.encode(from.view)),
      );

      expect([for (var c = 0; c < 3; c++) into.view.xAt(c)], before,
          reason: 'importing values must not silently move the axes');
    });

    test('imports the axes when asked', () {
      final from = build(x: [50, 60, 70], y: [40, 45, 50]);
      final into = build();

      final result = TableFileCodec.applyTo(
        into.view,
        TableFileCodec.decode(TableFileCodec.encode(from.view)),
        importAxes: true,
      );

      expect(result.axesWritten, isTrue);
      expect(into.view.xAt(0), 5000);
      expect(into.view.yAt(0), 80);
    });

    test('clamps values the definition does not permit', () {
      // The destination declares a ceiling; an import must respect it rather
      // than writing a value the ECU would reject or wrap.
      final into = build();
      final data = TableFileData(
        xBins: const [1000, 2000, 3000],
        yBins: const [10, 20, 30],
        values: List.generate(3, (_) => List.filled(3, 9999)),
      );
      TableFileCodec.applyTo(into.view, data);

      expect(into.view.valueAt(0, 0), into.view.high);
    });
  });

  group('applyTo, differing shapes', () {
    test('resamples a smaller table onto a larger one', () {
      // A 2x2 source spanning the same axis range as a 3x3 destination.
      final into = build();
      final data = TableFileData(
        xBins: const [1000, 3000],
        yBins: const [10, 30],
        values: const [
          [0, 20],
          [40, 60],
        ],
      );

      final result = TableFileCodec.applyTo(into.view, data);

      expect(result.resampled, isTrue);
      expect(result.sourceShape, '2x2');
      expect(result.targetShape, '3x3');
      expect(result.cellsWritten, 9);

      // Corners are preserved exactly.
      expect(into.view.valueAt(0, 0), 0);
      expect(into.view.valueAt(0, 2), 20);
      expect(into.view.valueAt(2, 0), 40);
      expect(into.view.valueAt(2, 2), 60);
      // The middle is the bilinear average.
      expect(into.view.valueAt(1, 1), 30);
      expect(into.view.valueAt(0, 1), 10);
      expect(into.view.valueAt(1, 0), 20);
    });

    test('holds the edge value outside the source range', () {
      // The destination's axes run past the source's. Extrapolating fuel
      // beyond what was actually tuned is not a safe guess.
      final into = build(x: [10, 20, 30], y: [5, 10, 15]);
      final data = TableFileData(
        xBins: const [1500, 2500],
        yBins: const [15, 25],
        values: const [
          [10, 20],
          [30, 40],
        ],
      );

      TableFileCodec.applyTo(into.view, data);

      // Below the source's range in both axes -> the nearest corner.
      expect(into.view.valueAt(0, 0), 10);
      // Above it in both -> the far corner.
      expect(into.view.valueAt(2, 2), 40);
    });

    test('never writes the axes when resampling', () {
      final into = build();
      final before = [for (var r = 0; r < 3; r++) into.view.yAt(r)];
      final data = TableFileData(
        xBins: const [1000, 3000],
        yBins: const [10, 30],
        values: const [
          [1, 2],
          [3, 4],
        ],
      );

      final result = TableFileCodec.applyTo(into.view, data, importAxes: true);

      expect(result.axesWritten, isFalse,
          reason: 'the values were fitted to these axes, so they must stand');
      expect([for (var r = 0; r < 3; r++) into.view.yAt(r)], before);
    });

    test('handles a single-row source', () {
      final into = build();
      final data = TableFileData(
        xBins: const [1000, 3000],
        yBins: const [20],
        values: const [
          [10, 30],
        ],
      );

      expect(() => TableFileCodec.applyTo(into.view, data), returnsNormally);
      // With one row, every destination row takes the same interpolation.
      expect(into.view.valueAt(0, 0), into.view.valueAt(2, 0));
      expect(into.view.valueAt(0, 0), 10);
      expect(into.view.valueAt(0, 2), 30);
    });

    test('resamples a larger table onto a smaller one', () {
      final into = build();
      final data = TableFileData(
        xBins: const [1000, 1500, 2000, 2500, 3000],
        yBins: const [10, 15, 20, 25, 30],
        values: List.generate(
          5,
          (r) => List.generate(5, (c) => (r * 10 + c).toDouble()),
        ),
      );

      final result = TableFileCodec.applyTo(into.view, data);

      expect(result.resampled, isTrue);
      expect(into.view.valueAt(0, 0), 0);
      expect(into.view.valueAt(2, 2), 44);
      expect(into.view.valueAt(1, 1), 22);
    });
  });

  group('sampleAt', () {
    final data = TableFileData(
      xBins: const [0, 10],
      yBins: const [0, 10],
      values: const [
        [0, 10],
        [20, 30],
      ],
    );

    test('returns corner values exactly', () {
      expect(TableFileCodec.sampleAt(data, 0, 0), 0);
      expect(TableFileCodec.sampleAt(data, 10, 0), 10);
      expect(TableFileCodec.sampleAt(data, 0, 10), 20);
      expect(TableFileCodec.sampleAt(data, 10, 10), 30);
    });

    test('interpolates inside', () {
      expect(TableFileCodec.sampleAt(data, 5, 0), 5);
      expect(TableFileCodec.sampleAt(data, 0, 5), 10);
      expect(TableFileCodec.sampleAt(data, 5, 5), 15);
    });

    test('clamps outside', () {
      expect(TableFileCodec.sampleAt(data, -100, -100), 0);
      expect(TableFileCodec.sampleAt(data, 999, 999), 30);
    });

    test('survives repeated bins without dividing by zero', () {
      final flat = TableFileData(
        xBins: const [5, 5],
        yBins: const [5, 5],
        values: const [
          [1, 2],
          [3, 4],
        ],
      );
      expect(() => TableFileCodec.sampleAt(flat, 5, 5), returnsNormally);
    });
  });
  group('precision', () {
    test('decimalsFor covers the storage step, not just the display hint', () {
      expect(TableFileCodec.decimalsFor(digits: 0, step: 1), 0);
      expect(TableFileCodec.decimalsFor(digits: 0, step: 0.5), 1);
      expect(TableFileCodec.decimalsFor(digits: 0, step: 0.1), 1);
      expect(TableFileCodec.decimalsFor(digits: 1, step: 0.001), 3);
      expect(TableFileCodec.decimalsFor(digits: 3, step: 1), 3,
          reason: 'never coarser than the definition asks for');
      expect(TableFileCodec.decimalsFor(digits: 0, step: 100), 0);
    });

    test('a step finer than the declared digits still round-trips', () {
      // digits 0 but a half-count step: writing at the display precision
      // would round every half away and silently alter the tune.
      const finer = '''
[MegaTune]
signature = "t"
[Constants]
nPages   = 1
pageSize = 32
page = 1
  zTable = array, U08, 0,  [2x2], "deg", 0.5,   0.0, 0.0, 100.0, 0
  xAxis  = array, U08, 4,  [2],   "RPM", 100.0, 0.0, 0.0, 25500.0, 0
  yAxis  = array, U08, 6,  [2],   "kPa", 2.0,   0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "T", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''';
      final doc = IniParser().parse(finer);
      final tune = TuneState.empty(doc);
      final view = TableView.of(tune, doc.tables.single)!;
      view
        ..setValueAt(0, 0, 12.5)
        ..setValueAt(0, 1, 13.5)
        ..setValueAt(1, 0, 0.5)
        ..setValueAt(1, 1, 99.5);
      final before = view.toGrid();

      final data = TableFileCodec.decode(TableFileCodec.encode(view));
      for (var r = 0; r < 2; r++) {
        for (var c = 0; c < 2; c++) {
          view.setValueAt(r, c, 0);
        }
      }
      TableFileCodec.applyTo(view, data);

      expect(view.toGrid(), before);
      expect(view.valueAt(0, 0), 12.5);
    });
  });
}
