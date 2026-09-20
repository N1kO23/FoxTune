import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Colours marking a cell this session has changed.
///
/// A diverging pair - red for raised, blue for lowered, with no tint for
/// unchanged - because the useful question is which *way* a cell moved.
///
/// The red is a deeper shade than the status palette's critical, so an edit
/// does not read as an alarm; the outline and background wash carry the same
/// information, so nothing rests on telling the two reds apart.
abstract final class EditTint {
  static const Color raised = Color(0xFFC62828);
  static const Color lowered = Color(0xFF1565C0);

  static Color of(CellChange change) =>
      change == CellChange.raised ? raised : lowered;

  /// Outline for an edited cell, weighted towards the direction of change.
  ///
  /// The weight carries the direction - heavy along the top for a raised
  /// value, along the bottom for a lowered one - so the change survives a
  /// colour-blind reading without a glyph. A glyph beside the value shifts
  /// the number, and one in a corner crosses the outline at any inset.
  static Border borderFor(CellChange change) {
    const thin = 1.0;
    const heavy = 3.0;
    final colour = of(change);
    final isRaised = change == CellChange.raised;
    return Border(
      top: BorderSide(color: colour, width: isRaised ? heavy : thin),
      bottom: BorderSide(color: colour, width: isRaised ? thin : heavy),
      left: BorderSide(color: colour, width: thin),
      right: BorderSide(color: colour, width: thin),
    );
  }
}

/// Cell geometry.
///
/// An axis label must occupy the same footprint as a cell - the cell's width
/// *plus its margins* - or the columns drift apart by the margin on every
/// column, which is only obvious by the far edge of a 16-wide table.
const double _cellWidth = 54;
const double _cellMargin = 1;
const double _columnWidth = _cellWidth + _cellMargin * 2;
const double _rowLabelWidth = 56;
const double _cellHeight = 30;
const double _rowHeight = _cellHeight + _cellMargin * 2;

/// Pixel position of a continuous grid coordinate, relative to the grid's
/// top-left corner.
///
/// Shared by the overlay painter and its tests so the geometry is asserted
/// against the real layout rather than restated in two places. Row 0 is the
/// lowest Y but is painted last, hence the inverted vertical axis.
@visibleForTesting
Offset gridPointFor({
  required double row,
  required double column,
  required int rows,
}) => Offset(
  _rowLabelWidth + (column + 0.5) * _columnWidth,
  (rows - 1 - row + 0.5) * _rowHeight,
);

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
    this.preciseCursor,
    this.contributing = const {},
    this.changes = const {},
    this.onEditAxis,
    this.editable = false,
  });

  final TableView view;
  final CellSelection selection;
  final ValueChanged<CellSelection> onSelectionChanged;

  /// Called with a delta or replacement to apply to the current selection.
  final void Function(void Function(TableView view) edit) onEdit;

  /// Called when an axis bin should be changed.
  ///
  /// Separate from [onEdit] because the axes are not part of the selection:
  /// editing a bin moves where the whole column or row sits, rather than
  /// changing a value inside it.
  final void Function(void Function(TableView view) edit)? onEditAxis;

  /// The cell the engine is operating in, snapped to the nearest bins.
  final ({int row, int column})? cursor;

  /// Cells bracketing the operating point, faintly ringed.
  ///
  /// The ECU interpolates between these four, so they are what an edit must
  /// change to alter behaviour at the current operating point - the single
  /// nearest cell only tells half the story.
  final Set<({int row, int column})> contributing;

  /// Cells changed since the tune was last synchronised with the ECU.
  final Map<({int row, int column}), CellChange> changes;

  /// The engine's exact position as continuous indices, for the overlay.
  ///
  /// The snapped cell says which cell is in play; this says whereabouts inside
  /// it - the difference between "you are in this cell" and "you are at its
  /// top-left corner, about to cross into the next one".
  final ({double row, double column})? preciseCursor;

  /// Whether cells may be changed.
  final bool editable;

  @override
  State<TableGrid> createState() => _TableGridState();
}

class _TableGridState extends State<TableGrid> {
  final _focusNode = FocusNode();

  /// Digits typed so far, before they are committed.
  ///
  /// Typing over a selection replaces it outright, the way a spreadsheet
  /// behaves - the alternative, nudging with +/-, is far too slow for entering
  /// a known number into a block of cells.
  String? _entry;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Applies the typed value to every selected cell.
  void _commitEntry() {
    final text = _entry;
    setState(() => _entry = null);
    if (text == null || text.isEmpty || text == '-' || text == '.') return;

    final value = double.tryParse(text);
    if (value == null) return;
    final cells = widget.selection.cells;
    widget.onEdit((view) => view.fill(cells, value));
  }

  /// Handles a printable character as numeric entry.
  ///
  /// Returns false when the character is not part of a number, so the key can
  /// fall through to the shortcuts.
  bool _handleCharacter(String character) {
    if (!RegExp(r'[0-9.\-]').hasMatch(character)) return false;
    setState(() => _entry = (_entry ?? '') + character);
    return true;
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

  static bool _isArrow(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final extend = keys.isShiftPressed;

    if (widget.editable) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        setState(() => _entry = null);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        _commitEntry();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.backspace) {
        final current = _entry;
        if (current != null) {
          setState(
            () => _entry = current.isEmpty
                ? null
                : current.substring(0, current.length - 1),
          );
          return KeyEventResult.handled;
        }
      }
      final character = event.character;
      if (character != null && _handleCharacter(character)) {
        return KeyEventResult.handled;
      }
      // Moving away commits, as a spreadsheet does.
      if (_entry != null && _isArrow(event.logicalKey)) _commitEntry();
    }

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

    final overlay = widget.preciseCursor;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: _focusNode.requestFocus,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Rows top-down are highest Y first.
                  for (var r = view.rows - 1; r >= 0; r--)
                    Row(
                      children: [
                        _AxisLabel(
                          text: _format(view.yAt(r), view.yDecimals),
                          width: _rowLabelWidth,
                          highlighted: widget.cursor?.row == r,
                          onEdit: widget.editable
                              ? () => _editAxis(
                                  context,
                                  title: 'Load bin',
                                  units: view.yUnits,
                                  current: view.yAt(r),
                                  decimals: view.yDecimals,
                                  bounds: view.yBounds,
                                  apply: (value) => widget.onEditAxis?.call(
                                    (v) => v.setYAt(r, value),
                                  ),
                                )
                              : null,
                        ),
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
                            isContributing: widget.contributing.contains((
                              row: r,
                              column: c,
                            )),
                            // Only the focused cell shows what is being typed;
                            // the rest keep their values so the surrounding
                            // numbers stay readable while entering.
                            entry:
                                widget.selection.focusRow == r &&
                                    widget.selection.focusColumn == c
                                ? _entry
                                : null,
                            change: widget.changes[(row: r, column: c)],
                            onLongPress: () {
                              // The touch equivalent of shift-click: there is
                              // no modifier key on a phone, and a block
                              // selection is the whole point of the edit
                              // actions.
                              _focusNode.requestFocus();
                              _commitEntry();
                              widget.onSelectionChanged(
                                widget.selection.movedTo(r, c, extend: true),
                              );
                            },
                            onTap: () {
                              // The cell consumes the tap, so the grid's own
                              // gesture detector never sees it - without this
                              // the keyboard shortcuts stay dead after
                              // clicking a cell.
                              _focusNode.requestFocus();
                              // A pending entry belongs to the cells it was
                              // typed into. Carrying it to the new selection
                              // would silently retarget the edit.
                              _commitEntry();
                              widget.onSelectionChanged(
                                widget.selection.movedTo(
                                  r,
                                  c,
                                  extend:
                                      HardwareKeyboard.instance.isShiftPressed,
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  Row(
                    children: [
                      SizedBox(
                        width: _rowLabelWidth,
                        height: 26,
                        child: Center(
                          child: Text(
                            '${view.yUnits}\\${view.xUnits}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ),
                      for (var c = 0; c < view.columns; c++)
                        _AxisLabel(
                          text: _format(view.xAt(c), view.xDecimals),
                          width: _columnWidth,
                          highlighted: widget.cursor?.column == c,
                          onEdit: widget.editable
                              ? () => _editAxis(
                                  context,
                                  title: '${view.xUnits} bin',
                                  units: view.xUnits,
                                  current: view.xAt(c),
                                  decimals: view.xDecimals,
                                  bounds: view.xBounds,
                                  apply: (value) => widget.onEditAxis?.call(
                                    (v) => v.setXAt(c, value),
                                  ),
                                )
                              : null,
                        ),
                    ],
                  ),
                ],
              ),
              if (overlay != null)
                Positioned.fill(
                  // Purely decorative, and it sits over the cells - it must
                  // never intercept a tap meant for the cell underneath.
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _PrecisePositionPainter(
                        row: overlay.row,
                        column: overlay.column,
                        rows: view.rows,
                        color: theme.colorScheme.tertiary,
                        haloColor: theme.colorScheme.surface,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Prompts for a new axis bin value and applies it.
  Future<void> _editAxis(
    BuildContext context, {
    required String title,
    required String units,
    required double? current,
    required int decimals,
    required ({double? low, double? high}) bounds,
    required void Function(double value) apply,
  }) async {
    if (current == null) return;
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _AxisEditDialog(
        title: title,
        units: units,
        current: current,
        decimals: decimals,
        bounds: bounds,
      ),
    );
    if (value != null) apply(value);
  }

  static double _fraction(double? value, double lo, double hi) {
    if (value == null || hi <= lo) return 0;
    return ((value - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  static String _format(double? value, int decimals) =>
      value == null ? '--' : value.toStringAsFixed(decimals);
}

class _AxisLabel extends StatelessWidget {
  const _AxisLabel({
    required this.text,
    required this.width,
    this.highlighted = false,
    this.onEdit,
  });

  final String text;
  final double width;

  /// Whether this label sits on the live cursor's row or column.
  final bool highlighted;

  /// Opens the bin editor. Null when writing is not permitted.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      height: 26,
      child: InkWell(
        onTap: onEdit,
        child: Center(
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              // Marking the axes as well as the cell makes the operating point
              // readable at a glance on a 16x16 grid, where a single ringed
              // cell is easy to lose.
              color: highlighted ? scheme.tertiary : scheme.onSurfaceVariant,
              fontWeight: highlighted ? FontWeight.w700 : FontWeight.w400,
              fontFeatures: const [FontFeature.tabularFigures()],
              // An editable bin is underlined, so it is discoverable without
              // a tooltip and obviously inert when read-only.
              decoration: onEdit == null ? null : TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Prompts for a single axis bin value.
class _AxisEditDialog extends StatefulWidget {
  const _AxisEditDialog({
    required this.title,
    required this.units,
    required this.current,
    required this.decimals,
    required this.bounds,
  });

  final String title;
  final String units;
  final double current;
  final int decimals;
  final ({double? low, double? high}) bounds;

  @override
  State<_AxisEditDialog> createState() => _AxisEditDialogState();
}

class _AxisEditDialogState extends State<_AxisEditDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current.toStringAsFixed(widget.decimals),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = double.tryParse(_controller.text.trim());
    if (value == null) {
      setState(() => _error = 'Not a number');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final low = widget.bounds.low;
    final high = widget.bounds.high;
    final range = low == null || high == null
        ? null
        : '${low.toStringAsFixed(widget.decimals)} to '
              '${high.toStringAsFixed(widget.decimals)}';

    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          suffixText: widget.units,
          errorText: _error,
          helperText: range == null ? null : 'Permitted: $range',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.value,
    required this.decimals,
    required this.fraction,
    required this.selected,
    required this.isFocus,
    required this.isCursor,
    required this.isContributing,
    required this.onTap,
    this.entry,
    this.change,
    this.onLongPress,
  });

  final double? value;
  final int decimals;
  final double fraction;
  final bool selected;
  final bool isFocus;
  final bool isCursor;

  /// One of the four cells the ECU interpolates between right now.
  final bool isContributing;

  /// Digits being typed into this cell, shown in place of its value.
  final String? entry;

  /// How this cell differs from the last tune read from the ECU.
  final CellChange? change;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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

    final background = isCursor
        // A tint as well as a ring: the ring alone disappears against a dark
        // heat-map cell, and against the selection fill.
        ? Color.lerp(
            selected ? scheme.primaryContainer : heat,
            scheme.tertiaryContainer,
            0.55,
          )!
        : (selected ? scheme.primaryContainer : heat);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: _cellWidth,
        height: _cellHeight,
        margin: const EdgeInsets.all(_cellMargin),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
            // The live cursor gets the heaviest ring: it is the one thing on
            // screen that moves on its own. The other three cells feeding the
            // interpolation are marked more lightly - present, but not
            // competing with it or with the selection.
            color: isCursor
                ? scheme.tertiary
                : isFocus
                ? scheme.primary
                : isContributing
                ? scheme.tertiary.withValues(alpha: 0.45)
                : Colors.transparent,
            width: isCursor
                ? 2.5
                : isFocus
                ? 2
                : isContributing
                ? 1.5
                : 1,
          ),
        ),
        child: Stack(
          // Stack clips to its bounds by default, which would quietly shave
          // the corner off the marker. The cell has a margin to overhang into.
          clipBehavior: Clip.none,
          children: [
            if (change != null)
              // Inset, so it reads as a second, inner rectangle rather than
              // another ring. The outer border is spoken for: it carries the
              // live cursor, the interpolation neighbours and the keyboard
              // selection, and an edit has to stay legible on top of any of
              // them.
              Positioned.fill(
                child: Container(
                  margin: const EdgeInsets.all(1.5),
                  // A non-uniform border cannot carry a radius, and a crisp
                  // rectangle reads more distinctly against the rounded rings
                  // anyway.
                  decoration: BoxDecoration(
                    border: EditTint.borderFor(change!),
                  ),
                ),
              ),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  entry ??
                      (value == null ? '--' : value!.toStringAsFixed(decimals)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    // A pending entry wins, then the edit direction, then
                    // the ordinary text tokens.
                    color: entry != null
                        ? scheme.primary
                        : change != null
                        ? EditTint.of(change!)
                        : (selected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface),
                    fontWeight: entry != null || isCursor
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the engine's exact operating point over the grid.
///
/// The ringed cell says which cell is in play; this marks where inside it the
/// engine actually is. Watching the dot travel between cells is how you see a
/// transition coming, which a snapped highlight cannot show.
class _PrecisePositionPainter extends CustomPainter {
  _PrecisePositionPainter({
    required this.row,
    required this.column,
    required this.rows,
    required this.color,
    required this.haloColor,
  });

  /// Continuous indices; 1.5 means halfway between bins 1 and 2.
  final double row;
  final double column;

  /// Total rows, needed because the grid is drawn highest-Y first.
  final int rows;

  final Color color;

  /// Drawn under the marker so it stays visible on any heat-map colour.
  final Color haloColor;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = gridPointFor(row: row, column: column, rows: rows);
    final x = centre.dx;
    final y = centre.dy;

    final gridBottom = rows * _rowHeight;
    final gridRight = _rowLabelWidth + size.width;

    final halo = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = haloColor.withValues(alpha: 0.8);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color.withValues(alpha: 0.6);

    // Crosshair to the axes, so the position can be read off them directly.
    for (final paint in [halo, line]) {
      canvas
        ..drawLine(Offset(_rowLabelWidth, y), Offset(gridRight, y), paint)
        ..drawLine(Offset(x, 0), Offset(x, gridBottom), paint);
    }

    canvas
      ..drawCircle(centre, 6, Paint()..color = haloColor.withValues(alpha: 0.9))
      ..drawCircle(centre, 4.5, Paint()..color = color)
      ..drawCircle(
        centre,
        4.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = haloColor,
      );
  }

  @override
  bool shouldRepaint(_PrecisePositionPainter old) =>
      old.row != row || old.column != column || old.color != color;
}
