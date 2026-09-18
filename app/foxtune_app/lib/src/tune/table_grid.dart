import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// A rectangular block of selected cells.
class CellSelection {
  const CellSelection({
    required this.anchorRow,
    required this.anchorColumn,
    required this.focusRow,
    required this.focusColumn,
  });

  const CellSelection.single(int row, int column)
    : anchorRow = row,
      anchorColumn = column,
      focusRow = row,
      focusColumn = column;

  final int anchorRow;
  final int anchorColumn;
  final int focusRow;
  final int focusColumn;

  int get minRow => anchorRow < focusRow ? anchorRow : focusRow;
  int get maxRow => anchorRow < focusRow ? focusRow : anchorRow;
  int get minColumn => anchorColumn < focusColumn ? anchorColumn : focusColumn;
  int get maxColumn => anchorColumn < focusColumn ? focusColumn : anchorColumn;

  bool contains(int row, int column) =>
      row >= minRow &&
      row <= maxRow &&
      column >= minColumn &&
      column <= maxColumn;

  int get cellCount => (maxRow - minRow + 1) * (maxColumn - minColumn + 1);

  /// Every selected cell.
  List<({int row, int column})> get cells => [
    for (var r = minRow; r <= maxRow; r++)
      for (var c = minColumn; c <= maxColumn; c++) (row: r, column: c),
  ];

  CellSelection movedTo(int row, int column, {required bool extend}) => extend
      ? CellSelection(
          anchorRow: anchorRow,
          anchorColumn: anchorColumn,
          focusRow: row,
          focusColumn: column,
        )
      : CellSelection.single(row, column);
}

/// An editable table grid.
///
/// Row 0 is the lowest Y, but tuners read a table with load increasing upward,
/// so rows are rendered bottom-up to match every other tool in this space.
class TableGrid extends StatefulWidget {
  const TableGrid({
    super.key,
    required this.view,
    required this.selection,
    required this.onSelectionChanged,
    required this.onEdit,
    this.cursor,
    this.editable = false,
  });

  final TableView view;
  final CellSelection selection;
  final ValueChanged<CellSelection> onSelectionChanged;

  /// Called with a delta or replacement to apply to the current selection.
  final void Function(void Function(TableView view) edit) onEdit;

  /// Where the engine is currently operating, if known.
  final ({int row, int column})? cursor;

  /// Whether cells may be changed.
  final bool editable;

  @override
  State<TableGrid> createState() => _TableGridState();
}

class _TableGridState extends State<TableGrid> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _move(int dRow, int dColumn, {required bool extend}) {
    final selection = widget.selection;
    final row = (selection.focusRow + dRow).clamp(0, widget.view.rows - 1);
    final column = (selection.focusColumn + dColumn).clamp(
      0,
      widget.view.columns - 1,
    );
    widget.onSelectionChanged(selection.movedTo(row, column, extend: extend));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final extend = keys.isShiftPressed;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _move(1, 0, extend: extend);
      case LogicalKeyboardKey.arrowDown:
        _move(-1, 0, extend: extend);
      case LogicalKeyboardKey.arrowLeft:
        _move(0, -1, extend: extend);
      case LogicalKeyboardKey.arrowRight:
        _move(0, 1, extend: extend);
      default:
        if (!widget.editable) return KeyEventResult.ignored;
        // Increment/decrement keys, the way every tuning tool works.
        switch (event.logicalKey) {
          case LogicalKeyboardKey.equal:
          case LogicalKeyboardKey.add:
            widget.onEdit((v) => v.adjustBy(widget.selection.cells, 1));
          case LogicalKeyboardKey.minus:
            widget.onEdit((v) => v.adjustBy(widget.selection.cells, -1));
          case LogicalKeyboardKey.bracketRight:
            widget.onEdit((v) => v.scaleBy(widget.selection.cells, 101));
          case LogicalKeyboardKey.bracketLeft:
            widget.onEdit((v) => v.scaleBy(widget.selection.cells, 99));
          default:
            return KeyEventResult.ignored;
        }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final theme = Theme.of(context);

    final values = view.toGrid();
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final row in values) {
      for (final value in row) {
        if (value == null) continue;
        if (value < lo) lo = value;
        if (value > hi) hi = value;
      }
    }
    if (!lo.isFinite || !hi.isFinite) {
      lo = 0;
      hi = 1;
    }

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: _focusNode.requestFocus,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Rows top-down are highest Y first.
              for (var r = view.rows - 1; r >= 0; r--)
                Row(
                  children: [
                    _AxisLabel(text: _format(view.yAt(r), 0), width: 56),
                    for (var c = 0; c < view.columns; c++)
                      _Cell(
                        value: values[r][c],
                        decimals: view.zDecimals,
                        fraction: _fraction(values[r][c], lo, hi),
                        selected: widget.selection.contains(r, c),
                        isFocus:
                            widget.selection.focusRow == r &&
                            widget.selection.focusColumn == c,
                        isCursor:
                            widget.cursor?.row == r &&
                            widget.cursor?.column == c,
                        onTap: () => widget.onSelectionChanged(
                          widget.selection.movedTo(
                            r,
                            c,
                            extend: HardwareKeyboard.instance.isShiftPressed,
                          ),
                        ),
                      ),
                  ],
                ),
              Row(
                children: [
                  SizedBox(
                    width: 56,
                    height: 26,
                    child: Center(
                      child: Text(
                        '${view.yUnits}\\${view.xUnits}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                  for (var c = 0; c < view.columns; c++)
                    _AxisLabel(text: _format(view.xAt(c), 0), width: 54),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static double _fraction(double? value, double lo, double hi) {
    if (value == null || hi <= lo) return 0;
    return ((value - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  static String _format(double? value, int decimals) =>
      value == null ? '--' : value.toStringAsFixed(decimals);
}

class _AxisLabel extends StatelessWidget {
  const _AxisLabel({required this.text, required this.width});
  final String text;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: 26,
    child: Center(
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.value,
    required this.decimals,
    required this.fraction,
    required this.selected,
    required this.isFocus,
    required this.isCursor,
    required this.onTap,
  });

  final double? value;
  final int decimals;
  final double fraction;
  final bool selected;
  final bool isFocus;
  final bool isCursor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Magnitude is a sequential encoding: one hue, light to dark. A rainbow
    // ramp would imply categories that are not there, and fails for
    // colour-blind readers.
    final heat = Color.lerp(
      scheme.surfaceContainerLowest,
      scheme.primary.withValues(alpha: 0.55),
      fraction,
    )!;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 30,
        margin: const EdgeInsets.all(1),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : heat,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            color: isCursor
                ? scheme.tertiary
                : isFocus
                ? scheme.primary
                : Colors.transparent,
            // The live cursor gets the heaviest ring: it is the one thing on
            // screen that moves on its own.
            width: isCursor ? 2.5 : (isFocus ? 2 : 1),
          ),
        ),
        child: Center(
          child: Text(
            value == null ? '--' : value!.toStringAsFixed(decimals),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              color: selected ? scheme.onPrimaryContainer : scheme.onSurface,
              fontWeight: isCursor ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}
