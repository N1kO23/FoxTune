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

    test('a descending X axis flips the bins but not the columns', () {
      // The firmware stores the X array descending while laying the value
      // columns out ascending - `x[0]` is X-Max but `value[..][0]` is X-Min.
      // Mirroring the columns to match the array transposes the table, which
      // on a VE map means fuelling the top of the rev range with idle numbers.
      final tune = tuneWith(
        z: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        x: [30, 20, 10],
        y: [5, 10, 15],
      );
      final view = viewOf(tune);

      expect(view.xReversed, isTrue);
      expect(view.xAt(0), 1000, reason: 'column 0 must be the lowest X');
      expect(view.xAt(2), 3000);
      // Columns are read straight through, unlike the axis array.
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
      // Rows follow the Y array; columns do not follow the X array.
      final tune = tuneWith(
        z: [7, 8, 9, 4, 5, 6, 1, 2, 3],
        x: [30, 20, 10],
        y: [15, 10, 5],
      );
      final view = viewOf(tune);

      expect(view.xReversed, isTrue);
      expect(view.yReversed, isTrue);
      expect(view.valueAt(0, 0), 1, reason: 'lowest X, lowest Y');
      expect(view.valueAt(2, 2), 9, reason: 'highest X, highest Y');
    });

    test('writes go back to the right stored cell when reversed', () {
      final tune = tuneWith(
        z: [1, 2, 3, 4, 5, 6, 7, 8, 9],
        x: [30, 20, 10],
        y: [5, 10, 15],
      );
      final view = viewOf(tune);

      view.setValueAt(0, 0, 42);

      // Column 0 is the lowest X and is stored first, despite the X array
      // running the other way.
      expect(view.valueAt(0, 0), 42);
      final z = tune.locate('zTable')!;
      expect(tune.readRaw(z.page, z.field, 0), 42);
      expect(tune.readRaw(z.page, z.field, 2), 3, reason: 'other cells intact');
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

  group('axis editing', () {
    late TuneState tune;
    late TableView view;

    setUp(() {
      tune = tuneWith(
        z: List.filled(9, 0),
        x: [10, 20, 30],
        y: [5, 10, 15],
      );
      view = viewOf(tune);
    });

    test('writes a bin back through its scale', () {
      // rpmBins scales by 100, so 2500 must store as raw 25.
      view.setXAt(1, 2500);
      expect(view.xAt(1), 2500);

      final field = tune.locate('xAxis')!;
      expect(tune.readRaw(field.page, field.field, 1), 25);
      expect(tune.dirtyPages, {1});
    });

    test('edits the Y axis too', () {
      // yAxis scales by 2.
      view.setYAt(2, 40);
      expect(view.yAt(2), 40);
    });

    test('clamps to the bounds the definition declares', () {
      // xAxis declares 100..25500.
      view.setXAt(0, 999999);
      expect(view.xAt(0), view.xBounds.high);

      view.setXAt(0, -500);
      expect(view.xAt(0), view.xBounds.low);
    });

    test('rounds to what the storage type can hold', () {
      // Raw is U08 with scale 100, so 2540 cannot be represented exactly.
      view.setXAt(1, 2540);
      expect(view.xAt(1), 2500);
    });

    test('rejects a bin outside the table', () {
      expect(() => view.setXAt(9, 1000), throwsRangeError);
      expect(() => view.setYAt(-1, 10), throwsRangeError);
    });

    test('writes to the right stored slot when the axis is reversed', () {
      final reversed = viewOf(tuneWith(
        z: List.filled(9, 0),
        x: [30, 20, 10],
        y: [5, 10, 15],
      ));
      expect(reversed.xReversed, isTrue);

      // Logical column 0 is the lowest X, stored last.
      reversed.setXAt(0, 500);
      expect(reversed.xAt(0), 500);
      expect(reversed.xAt(2), 3000, reason: 'other bins untouched');
    });

    test('reports an axis that has stopped ascending', () {
      expect(view.isXAxisAscending, isTrue);
      // Editing passes through inconsistent states, so this is reported
      // rather than prevented.
      view.setXAt(0, 2500);
      expect(view.isXAxisAscending, isFalse);

      view.setXAt(0, 500);
      expect(view.isXAxisAscending, isTrue);
    });

    test('exposes display precision from the definition', () {
      expect(view.xDecimals, 0);
      expect(view.yDecimals, 0);
    });
  });

  group('precise position', () {
    late TableView view;

    setUp(() {
      // x bins 1000/2000/3000, y bins 10/20/30.
      view = viewOf(tuneWith(
        z: List.filled(9, 0),
        x: [10, 20, 30],
        y: [5, 10, 15],
      ));
    });

    test('lands exactly on a bin', () {
      final p = view.preciseCellFor(2000, 20)!;
      expect(p.column, closeTo(1, 1e-9));
      expect(p.row, closeTo(1, 1e-9));
    });

    test('interpolates between bins', () {
      // Halfway between the 1000 and 2000 columns.
      final p = view.preciseCellFor(1500, 15)!;
      expect(p.column, closeTo(0.5, 1e-9));
      expect(p.row, closeTo(0.5, 1e-9));
    });

    test('interpolates proportionally, not just to the midpoint', () {
      final p = view.preciseCellFor(1250, 28)!;
      expect(p.column, closeTo(0.25, 1e-9));
      expect(p.row, closeTo(1.8, 1e-9));
    });

    test('clamps beyond the ends of the axes', () {
      // An engine can run past the top of a table; there is nowhere further
      // to point at.
      final low = view.preciseCellFor(0, 0)!;
      expect(low.column, 0);
      expect(low.row, 0);

      final high = view.preciseCellFor(99999, 99999)!;
      expect(high.column, 2);
      expect(high.row, 2);
    });

    test('agrees with the snapped cell after rounding', () {
      // Away from exact midpoints. On a tie the two deliberately differ:
      // cellFor keeps the lower bin while rounding goes up. That is not a
      // disagreement worth forcing - a point exactly on a boundary is
      // exactly on a boundary, and the overlay draws it there.
      for (final (x, y) in const [
        (1200.0, 12.0),
        (2600.0, 26.0),
        (2900.0, 29.0)
      ]) {
        final precise = view.preciseCellFor(x, y)!;
        final snapped = view.cellFor(x, y)!;
        expect(precise.column.round(), snapped.column,
            reason: 'precise and snapped must not disagree at $x');
        expect(precise.row.round(), snapped.row);
      }
    });
  });

  group('contributing cells', () {
    late TableView view;

    setUp(() {
      view = viewOf(tuneWith(
        z: List.filled(9, 0),
        x: [10, 20, 30],
        y: [5, 10, 15],
      ));
    });

    test('brackets an interior point with four cells', () {
      final cells = view.contributingCells(0.5, 1.5);
      expect(cells, hasLength(4));
      expect(
          cells,
          containsAll(const [
            (row: 0, column: 1),
            (row: 0, column: 2),
            (row: 1, column: 1),
            (row: 1, column: 2),
          ]));
    });

    test('still returns four when exactly on a bin', () {
      // Sitting on a bin, the bracket runs from that bin to the next.
      expect(view.contributingCells(1, 1), hasLength(4));
    });

    test('collapses at the far edges', () {
      // There is no cell beyond the last row or column to interpolate toward.
      expect(view.contributingCells(2, 2), [(row: 2, column: 2)]);
      expect(view.contributingCells(2, 0.5), hasLength(2));
    });

    test('never returns a cell outside the table', () {
      for (final (row, column) in const [(-5.0, -5.0), (99.0, 99.0)]) {
        for (final cell in view.contributingCells(row, column)) {
          expect(cell.row, inInclusiveRange(0, view.rows - 1));
          expect(cell.column, inInclusiveRange(0, view.columns - 1));
        }
      }
    });

    test('contains the snapped cell', () {
      // Whatever the editor rings as nearest must be among the cells that
      // actually affect the reading.
      for (final (x, y) in const [(1200.0, 12.0), (2600.0, 26.0)]) {
        final precise = view.preciseCellFor(x, y)!;
        final snapped = view.cellFor(x, y)!;
        expect(view.contributingCells(precise.row, precise.column),
            contains(snapped));
      }
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
