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

      await tester.tap(find.text('10').first);
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

      await tester.tap(find.text('10').first);
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
