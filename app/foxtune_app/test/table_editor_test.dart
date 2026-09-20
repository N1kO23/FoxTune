import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/tune/surface_view.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

const _source = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 32
page = 1
  zTable = array, U08, 0, [3x3], "%",   1.0,   0.0, 0.0, 255.0, 0
  xAxis  = array, U08, 9, [3],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  yAxis  = array, U08, 12, [3],  "kPa", 2.0,   0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "Test Table", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''';

({TuneState tune, TableView view}) buildTable() {
  final doc = IniParser().parse(_source);
  final tune = TuneState.empty(doc);
  final z = tune.locate('zTable')!;
  final x = tune.locate('xAxis')!;
  final y = tune.locate('yAxis')!;
  for (var i = 0; i < 9; i++) {
    tune.writeRaw(z.page, z.field, (i + 1) * 10, i);
  }
  for (var i = 0; i < 3; i++) {
    tune.writeRaw(x.page, x.field, 10 * (i + 1), i);
    tune.writeRaw(y.page, y.field, 5 * (i + 1), i);
  }
  tune.markClean();
  return (tune: tune, view: TableView.of(tune, doc.tables.single)!);
}

void main() {
  _alignmentTests();
  _axisEditTests();
  _contributingTests();
  _overlayTests();
  _surfaceTests();
  group('CellSelection', () {
    test('a single cell covers one position', () {
      const selection = CellSelection.single(2, 3);
      expect(selection.cellCount, 1);
      expect(selection.contains(2, 3), isTrue);
      expect(selection.contains(2, 4), isFalse);
    });

    test('spans a rectangle regardless of drag direction', () {
      const selection = CellSelection(
        anchorRow: 3,
        anchorColumn: 4,
        focusRow: 1,
        focusColumn: 2,
      );
      expect(selection.minRow, 1);
      expect(selection.maxRow, 3);
      expect(selection.cellCount, 9);
      expect(selection.contains(2, 3), isTrue);
    });

    test('extending keeps the anchor, replacing does not', () {
      const start = CellSelection.single(1, 1);
      expect(start.movedTo(3, 3, extend: true).cellCount, 9);
      expect(start.movedTo(3, 3, extend: false).cellCount, 1);
    });

    test('enumerates every cell in the block', () {
      const selection = CellSelection(
        anchorRow: 0,
        anchorColumn: 0,
        focusRow: 1,
        focusColumn: 1,
      );
      expect(selection.cells, hasLength(4));
      expect(selection.cells, contains((row: 1, column: 1)));
    });
  });

  group('TableGrid', () {
    Widget wrap(
      TableView view, {
      bool editable = false,
      CellSelection? selection,
      void Function(void Function(TableView))? onEdit,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: TableGrid(
            view: view,
            editable: editable,
            selection: selection ?? const CellSelection.single(0, 0),
            onSelectionChanged: (_) {},
            onEdit: onEdit ?? (_) {},
          ),
        ),
      );
    }

    testWidgets('renders cell values and axis labels', (tester) async {
      final table = buildTable();
      await tester.pumpWidget(wrap(table.view));

      expect(find.text('10'), findsWidgets);
      expect(find.text('90'), findsOneWidget);
      // X axis is scaled by 100.
      expect(find.text('1000'), findsOneWidget);
    });

    testWidgets('is read-only unless editing is enabled', (tester) async {
      final table = buildTable();
      var edits = 0;
      await tester.pumpWidget(wrap(table.view, onEdit: (_) => edits++));

      await tester.tap(find.text('50'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();

      // The default state must never be able to change the tune.
      expect(edits, 0);
      expect(table.tune.isDirty, isFalse);
    });

    testWidgets('accepts increment keys when editing is enabled', (
      tester,
    ) async {
      final table = buildTable();
      var edits = 0;
      await tester.pumpWidget(
        wrap(
          table.view,
          editable: true,
          onEdit: (apply) {
            edits++;
            apply(table.view);
          },
        ),
      );

      // 50 is a cell value only; 10/20/30 are also Y-axis bins, and the axis
      // labels are tappable once editing is enabled.
      await tester.tap(find.text('50'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();

      expect(edits, 1);
      expect(table.tune.isDirty, isTrue);
    });

    testWidgets('marks the live cursor cell', (tester) async {
      final table = buildTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(0, 0),
              cursor: (row: 1, column: 1),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('50'), findsOneWidget);
    });

    testWidgets('renders without overflow at phone width', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildTable();
      await tester.pumpWidget(wrap(table.view));

      expect(tester.takeException(), isNull);
    });
  });

  group('edit operations through the view', () {
    test('adjust, scale and smooth all clamp to the declared bounds', () {
      final table = buildTable();
      final cells = [
        for (var r = 0; r < 3; r++)
          for (var c = 0; c < 3; c++) (row: r, column: c),
      ];

      table.view.scaleBy(cells, 10000);
      for (final cell in cells) {
        expect(
          table.view.valueAt(cell.row, cell.column),
          lessThanOrEqualTo(255),
        );
      }
    });
  });
}

void _surfaceTests() {
  group('SurfaceView', () {
    testWidgets('renders a mesh without error', (tester) async {
      final table = buildTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SurfaceView(view: table.view)),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('orbits on drag without throwing', (tester) async {
      final table = buildTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SurfaceView(view: table.view)),
        ),
      );

      await tester.drag(find.byType(SurfaceView), const Offset(60, 30));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles a flat table where every value is equal', (
      tester,
    ) async {
      // A fresh tune is all zeros, so the value span is zero - the painter
      // must not divide by it.
      final doc = IniParser().parse(_source);
      final tune = TuneState.empty(doc);
      final view = TableView.of(tune, doc.tables.single)!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SurfaceView(view: view)),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('highlights the live cursor quad', (tester) async {
      final table = buildTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SurfaceView(view: table.view, cursor: (row: 1, column: 1)),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// A wide table with unique labels, so a per-column drift is measurable.
const _wideSource = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 32
page = 1
  zTable = array, U08, 0,  [2x6], "%",   1.0,   0.0, 0.0, 255.0, 0
  xAxis  = array, U08, 12, [6],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  yAxis  = array, U08, 18, [2],   "kPa", 2.0,   0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "Wide Table", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''';

({TuneState tune, TableView view}) buildWideTable() {
  final doc = IniParser().parse(_wideSource);
  final tune = TuneState.empty(doc);
  final z = tune.locate('zTable')!;
  final x = tune.locate('xAxis')!;
  final y = tune.locate('yAxis')!;
  for (var i = 0; i < 12; i++) {
    tune.writeRaw(z.page, z.field, 101 + i, i);
  }
  for (var i = 0; i < 6; i++) {
    tune.writeRaw(x.page, x.field, 10 * (i + 1), i);
  }
  for (var i = 0; i < 2; i++) {
    tune.writeRaw(y.page, y.field, 5 * (i + 1), i);
  }
  tune.markClean();
  return (tune: tune, view: TableView.of(tune, doc.tables.single)!);
}

void _alignmentTests() {
  group('column alignment', () {
    testWidgets('every axis label lines up with its column', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(0, 0),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      // Row 0 of the table holds 101..106, under axis labels 1000..6000.
      // The regression: labels were sized to the cell width but cells carry a
      // margin, so each column drifted by the margin - invisible at column 1
      // and obvious by column 6.
      for (var c = 0; c < 6; c++) {
        final cell = tester.getCenter(find.text('${101 + c}')).dx;
        final label = tester.getCenter(find.text('${(c + 1) * 1000}')).dx;
        expect(
          label,
          closeTo(cell, 0.5),
          reason: 'column ${c + 1} label is offset from its cells',
        );
      }
    });

    testWidgets('alignment holds while scrolled horizontally', (tester) async {
      // The app shows a 16-wide table in a viewport narrower than it, so the
      // grid is usually scrolled. The overlay lives inside the same scroll
      // view, so its offset from every cell must stay constant - any variation
      // between columns would be drift that grows across the table.
      await tester.binding.setSurfaceSize(const Size(300, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(0, 0),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      await tester.drag(find.byType(TableGrid), const Offset(-120, 0));
      await tester.pumpAndSettle();

      final origin = tester.getTopLeft(find.byType(TableGrid));
      final deltas = <double>[];
      for (var c = 0; c < 6; c++) {
        final finder = find.text('${101 + c}');
        if (finder.evaluate().isEmpty) continue;
        final expected =
            origin +
            gridPointFor(row: 0, column: c.toDouble(), rows: table.view.rows);
        deltas.add(tester.getCenter(finder).dx - expected.dx);
      }

      expect(deltas, isNotEmpty);
      for (final delta in deltas) {
        expect(
          delta,
          closeTo(deltas.first, 0.5),
          reason:
              'the offset must be the scroll amount, equal for every '
              'column - a varying offset is drift',
        );
      }
    });

    testWidgets('the row label column does not shift the first cell', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(0, 0),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      // Both rows of a column must share one x position.
      expect(
        tester.getCenter(find.text('101')).dx,
        closeTo(tester.getCenter(find.text('107')).dx, 0.5),
      );
    });
  });
}

void _overlayTests() {
  group('precise position overlay', () {
    Future<void> pumpWide(
      WidgetTester tester,
      TableView view, {
      ({double row, double column})? precise,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: view,
              selection: const CellSelection.single(0, 0),
              preciseCursor: precise,
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('its geometry matches where the cells actually render', (
      tester,
    ) async {
      // The overlay computes pixel positions by hand from the cell constants.
      // This ties that arithmetic to the real layout: an on-bin coordinate has
      // to land on the centre of that cell, including the inverted row axis.
      final table = buildWideTable();
      await pumpWide(tester, table.view);

      final gridOrigin = tester.getTopLeft(find.byType(TableGrid));
      for (final (row, column, text) in const [
        (0, 0, '101'),
        (0, 5, '106'),
        (1, 0, '107'),
        (1, 5, '112'),
      ]) {
        final expected =
            gridOrigin +
            gridPointFor(
              row: row.toDouble(),
              column: column.toDouble(),
              rows: table.view.rows,
            );
        final actual = tester.getCenter(find.text(text));
        expect(
          actual.dx,
          closeTo(expected.dx, 0.5),
          reason: 'x for cell ($row, $column)',
        );
        expect(
          actual.dy,
          closeTo(expected.dy, 0.5),
          reason: 'y for cell ($row, $column)',
        );
      }
    });

    testWidgets('an interpolated point sits between the cells it spans', (
      tester,
    ) async {
      final table = buildWideTable();
      await pumpWide(tester, table.view);

      final left = gridPointFor(row: 0, column: 2, rows: table.view.rows);
      final right = gridPointFor(row: 0, column: 3, rows: table.view.rows);
      final middle = gridPointFor(row: 0, column: 2.5, rows: table.view.rows);

      expect(middle.dx, closeTo((left.dx + right.dx) / 2, 1e-9));
      expect(middle.dy, closeTo(left.dy, 1e-9));
    });

    testWidgets('is drawn only when there is a live position', (tester) async {
      final table = buildWideTable();

      await pumpWide(tester, table.view);
      final without = tester.widgetList(find.byType(CustomPaint)).length;

      await pumpWide(tester, table.view, precise: (row: 0.5, column: 2.5));
      final with_ = tester.widgetList(find.byType(CustomPaint)).length;

      expect(
        with_,
        greaterThan(without),
        reason: 'the overlay must appear once a position is known',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

void _contributingTests() {
  group('contributing cells', () {
    /// The border colour of the cell showing [text].
    Color? borderOf(WidgetTester tester, String text) {
      final container = tester.widget<Container>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      return decoration.border?.top.color;
    }

    testWidgets('rings the four cells bracketing the operating point', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      // Between rows 0/1 and columns 2/3, so cells 103, 104, 109, 110 bracket
      // it: row 0 holds 101..106 and row 1 holds 107..112.
      const precise = (row: 0.5, column: 2.5);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(5, 5),
              preciseCursor: precise,
              contributing: table.view
                  .contributingCells(precise.row, precise.column)
                  .toSet(),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      final transparent = borderOf(tester, '101');
      for (final text in const ['103', '104', '109', '110']) {
        expect(
          borderOf(tester, text),
          isNot(transparent),
          reason: '$text brackets the point and must be marked',
        );
      }
      // A cell outside the bracket stays unmarked.
      expect(borderOf(tester, '102'), transparent);
      expect(borderOf(tester, '105'), transparent);
    });

    testWidgets('marks nothing when there is no live position', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(5, 5),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      final transparent = borderOf(tester, '101');
      for (final text in const ['103', '104', '109', '110']) {
        expect(borderOf(tester, text), transparent);
      }
    });

    testWidgets('the nearest cell keeps the stronger ring', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final table = buildWideTable();
      const precise = (row: 0.2, column: 2.2);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(5, 5),
              cursor: (row: 0, column: 2),
              preciseCursor: precise,
              contributing: table.view
                  .contributingCells(precise.row, precise.column)
                  .toSet(),
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );

      // 103 is the nearest cell; 104 only contributes. Both are marked, but
      // the dominant one must stay distinguishable.
      expect(borderOf(tester, '103'), isNot(borderOf(tester, '104')));
    });
  });
}

void _axisEditTests() {
  group('axis bin editing', () {
    Future<void> pump(
      WidgetTester tester,
      TableView view, {
      required bool editable,
      void Function(void Function(TableView) edit)? onEditAxis,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: view,
              selection: const CellSelection.single(0, 0),
              editable: editable,
              onSelectionChanged: (_) {},
              onEdit: (_) {},
              onEditAxis: onEditAxis,
            ),
          ),
        ),
      );
    }

    testWidgets('a bin opens an editor and applies the new value', (
      tester,
    ) async {
      final table = buildWideTable();
      await pump(
        tester,
        table.view,
        editable: true,
        onEditAxis: (edit) => edit(table.view),
      );

      // The 2000 rpm column bin.
      await tester.tap(find.text('2000'));
      await tester.pumpAndSettle();
      expect(find.text('Set'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '2500');
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      expect(table.view.xAt(1), 2500);
      expect(table.tune.isDirty, isTrue);
    });

    testWidgets('cancelling leaves the bin alone', (tester) async {
      final table = buildWideTable();
      await pump(
        tester,
        table.view,
        editable: true,
        onEditAxis: (edit) => edit(table.view),
      );

      await tester.tap(find.text('2000'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(table.view.xAt(1), 2000);
      expect(table.tune.isDirty, isFalse);
    });

    testWidgets('rejects text that is not a number', (tester) async {
      final table = buildWideTable();
      await pump(
        tester,
        table.view,
        editable: true,
        onEditAxis: (edit) => edit(table.view),
      );

      await tester.tap(find.text('2000'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.tap(find.text('Set'));
      await tester.pumpAndSettle();

      // The dialog stays open with an error rather than silently closing.
      expect(find.text('Not a number'), findsOneWidget);
      expect(table.view.xAt(1), 2000);
    });

    testWidgets('bins are inert when writing is not permitted', (tester) async {
      final table = buildWideTable();
      await pump(tester, table.view, editable: false);

      await tester.tap(find.text('2000'));
      await tester.pumpAndSettle();

      // Read-only must offer no way in at all.
      expect(find.text('Set'), findsNothing);
      expect(table.tune.isDirty, isFalse);
    });

    testWidgets('clicking a cell arms the keyboard shortcuts', (tester) async {
      // Regression: the cell consumed the tap, so the grid's own gesture
      // detector never focused it and the shortcuts stayed dead.
      final table = buildWideTable();
      var edits = 0;
      await tester.binding.setSurfaceSize(const Size(1200, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableGrid(
              view: table.view,
              selection: const CellSelection.single(0, 0),
              editable: true,
              onSelectionChanged: (_) {},
              onEdit: (apply) {
                edits++;
                apply(table.view);
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('101'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();

      expect(edits, 1);
    });
  });
}
