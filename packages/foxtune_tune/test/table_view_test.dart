import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// A 3x3 table so orientation is easy to reason about by hand.
const _source = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 16
page = 1
  zTable = array, U08, 0, [3x3], "%",   1.0, 0.0, 0.0, 255.0, 0
  xAxis  = array, U08, 9, [3],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  yAxis  = array, U08, 12, [3],  "kPa", 2.0, 0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "Test Table", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''';

IniDocument get definition => IniParser().parse(_source);

/// Builds a tune with the given stored (raw) bytes.
TuneState tuneWith({
  required List<int> z,
  required List<int> x,
  required List<int> y,
}) {
  final tune = TuneState.empty(definition);
  final zf = tune.locate('zTable')!;
  final xf = tune.locate('xAxis')!;
  final yf = tune.locate('yAxis')!;
  for (var i = 0; i < z.length; i++) {
    tune.writeRaw(zf.page, zf.field, z[i], i);
  }
  for (var i = 0; i < x.length; i++) {
    tune.writeRaw(xf.page, xf.field, x[i], i);
  }
  for (var i = 0; i < y.length; i++) {
    tune.writeRaw(yf.page, yf.field, y[i], i);
  }
  tune.markClean();
  return tune;
}

TableView viewOf(TuneState tune) =>
    TableView.of(tune, tune.definition.tables.single)!;

void main() {
  group('axis orientation', () {
    test('ascending axes are presented as stored', () {
      final tune = tuneWith(
        // Row-major, row 0 first.
        z: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        x: [10, 20, 30],
        y: [5, 10, 15],
      );
      final view = viewOf(tune);

      expect(view.xReversed, isFalse);
      expect(view.yReversed, isFalse);
      expect(view.xAt(0), 1000);
      expect(view.xAt(2), 3000);
      expect(view.valueAt(0, 0), 1);
      expect(view.valueAt(2, 2), 9);
    });

    test('a descending X axis is detected and flipped', () {
      // The firmware stores axes reversed; rather than assume which way, the
      // view infers it from the fact that axis bins must increase.
      final tune = tuneWith(
        z: [3, 2, 1, 6, 5, 4, 9, 8, 7],
        x: [30, 20, 10],
        y: [5, 10, 15],
      );
      final view = viewOf(tune);

      expect(view.xReversed, isTrue);
      expect(view.xAt(0), 1000, reason: 'column 0 must be the lowest X');
      expect(view.xAt(2), 3000);
      // Values follow the axes, so the flip applies to them too.
      expect(view.valueAt(0, 0), 1);
      expect(view.valueAt(0, 2), 3);
    });

    test('a descending Y axis is detected and flipped', () {
      final tune = tuneWith(
        z: [7, 8, 9, 4, 5, 6, 1, 2, 3],
        x: [10, 20, 30],
        y: [15, 10, 5],
      );
      final view = viewOf(tune);

      expect(view.yReversed, isTrue);
      expect(view.yAt(0), 10, reason: 'row 0 must be the lowest Y');
      expect(view.yAt(2), 30);
      expect(view.valueAt(0, 0), 1);
      expect(view.valueAt(2, 0), 7);
    });

    test('both axes reversed still presents canonically', () {
      final tune = tuneWith(
        z: [9, 8, 7, 6, 5, 4, 3, 2, 1],
        x: [30, 20, 10],
        y: [15, 10, 5],
      );
      final view = viewOf(tune);

      expect(view.xReversed, isTrue);
      expect(view.yReversed, isTrue);
      expect(view.valueAt(0, 0), 1);
      expect(view.valueAt(2, 2), 9);
    });

    test('writes go back to the right stored cell when reversed', () {
      final tune = tuneWith(
        z: [3, 2, 1, 6, 5, 4, 9, 8, 7],
        x: [30, 20, 10],
        y: [5, 10, 15],
      );
      final view = viewOf(tune);

      view.setValueAt(0, 0, 42);

      // Logical (0,0) is the lowest X, which is stored last in the row.
      expect(view.valueAt(0, 0), 42);
      final z = tune.locate('zTable')!;
      expect(tune.readRaw(z.page, z.field, 2), 42);
      expect(tune.readRaw(z.page, z.field, 0), 3, reason: 'other cells intact');
    });
  });

  group('scaling', () {
    late TableView view;

    setUp(() {
      view = viewOf(tuneWith(
        z: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        x: [10, 20, 30],
        y: [5, 10, 15],
      ));
    });

    test('applies axis scale factors', () {
      expect(view.xAt(1), 2000, reason: 'RPM scale is 100');
      expect(view.yAt(1), 20, reason: 'kPa scale is 2');
    });

    test('reports the definition bounds', () {
      expect(view.low, 0);
      expect(view.high, 255);
    });

    test('exposes units and dimensions', () {
      expect(view.xUnits, 'RPM');
      expect(view.yUnits, 'kPa');
      expect(view.zUnits, '%');
      expect(view.rows, 3);
      expect(view.columns, 3);
      expect(view.title, 'Test Table');
    });
  });

  group('editing', () {
    late TuneState tune;
    late TableView view;

    setUp(() {
      tune = tuneWith(
        z: [10, 20, 30, 40, 50, 60, 70, 80, 90],
        x: [10, 20, 30],
        y: [5, 10, 15],
      );
      view = viewOf(tune);
    });

    test('setting a value marks the page dirty', () {
      expect(tune.isDirty, isFalse);
      view.setValueAt(1, 1, 55);
      expect(view.valueAt(1, 1), 55);
      expect(tune.dirtyPages, {1});
    });

    test('clamps to the declared bounds, not just the storage type', () {
      // The definition's high is 255 here; a request beyond it must be pinned
      // rather than silently wrapped or rejected.
      view.setValueAt(0, 0, 9999);
      expect(view.valueAt(0, 0), 255);
      view.setValueAt(0, 0, -50);
      expect(view.valueAt(0, 0), 0);
    });

    test('rejects a cell outside the table', () {
      expect(() => view.setValueAt(5, 0, 1), throwsRangeError);
      expect(view.valueAt(5, 0), isNull);
    });

    test('adjusts a selection by a delta', () {
      view.adjustBy([(row: 0, column: 0), (row: 0, column: 1)], 5);
      expect(view.valueAt(0, 0), 15);
      expect(view.valueAt(0, 1), 25);
      expect(view.valueAt(0, 2), 30, reason: 'unselected cells untouched');
    });

    test('scales a selection by a percentage', () {
      view.scaleBy([(row: 1, column: 0)], 110);
      expect(view.valueAt(1, 0), 44);
    });

    test('fills a selection', () {
      view.fill([(row: 0, column: 0), (row: 2, column: 2)], 99);
      expect(view.valueAt(0, 0), 99);
      expect(view.valueAt(2, 2), 99);
      expect(view.valueAt(1, 1), 50);
    });

    test('interpolates a region from its corners', () {
      view
        ..setValueAt(0, 0, 0)
        ..setValueAt(0, 2, 20)
        ..setValueAt(2, 0, 40)
        ..setValueAt(2, 2, 60)
        ..interpolateRegion([
          (row: 0, column: 0),
          (row: 2, column: 2),
        ]);

      expect(view.valueAt(0, 1), 10);
      expect(view.valueAt(1, 0), 20);
      expect(view.valueAt(1, 1), 30);
      expect(view.valueAt(2, 1), 50);
    });

    test('smooths from a snapshot, not from partially smoothed values', () {
      // If smoothing read its own output, the result would depend on the order
      // cells happen to be visited.
      final cells = [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 3; c++) (row: r, column: c),
      ];
      view.smooth(cells);

      // Centre averages with its four orthogonal neighbours: 50 stays 50.
      expect(view.valueAt(1, 1), 50);
      // Corner (0,0): (10 + 40 + 20) / 3 = 23.33 -> rounds to 23.
      expect(view.valueAt(0, 0), 23);
    });
  });

  group('live cursor', () {
    test('finds the cell nearest an operating point', () {
      final view = viewOf(tuneWith(
        z: List.filled(9, 0),
        x: [10, 20, 30],
        y: [5, 10, 15],
      ));

      // x bins are 1000/2000/3000 rpm, y bins 10/20/30 kPa.
      expect(view.cellFor(2100, 21), (row: 1, column: 1));
      expect(view.cellFor(900, 9), (row: 0, column: 0));
      expect(view.cellFor(99999, 99999), (row: 2, column: 2));
    });
  });

  group('construction failures', () {
    test('returns null when the table fields cannot be resolved', () {
      const broken = '''
[Constants]
nPages   = 1
pageSize = 16
page = 1
  zTable = array, U08, 0, [3x3], "%", 1.0, 0.0, 0.0, 255.0, 0
[TableEditor]
  table = t, tMap, "Broken", 1
    xBins = missingAxis, rpm
    yBins = alsoMissing, map
    zBins = zTable
''';
      final doc = IniParser().parse(broken);
      final tune = TuneState.empty(doc);
      expect(TableView.of(tune, doc.tables.single), isNull);
    });
  });
}
