import 'package:foxtune_ini/foxtune_ini.dart';

import 'label_expressions.dart';
import 'tune_state.dart';
import 'value_resolver.dart';

/// How a cell has changed against a reference tune.
enum CellChange { raised, lowered }

/// An editable view of a 3D table, in engineering units.
///
/// ## Axis orientation
///
/// The firmware stores both axis arrays descending - `x[0]` is the highest RPM,
/// `y[0]` the highest load - so which end is which is **derived from the
/// data**: axis bins must increase, and an axis that reads back descending is
/// stored reversed.
///
/// The value grid does not simply mirror both axes. Rows follow the Y array,
/// but columns are stored in ascending-X order, opposite to the X array. That
/// asymmetry is the firmware's, confirmed both by its own worked example and
/// by comparing our output against a TunerStudio-written tune.
///
/// This view always presents the canonical orientation: column 0 is the lowest
/// X, row 0 is the lowest Y.
class TableView {
  TableView._({
    required this.table,
    required this.tune,
    required this.resolver,
    required this.page,
    required this.zField,
    required this.xField,
    required this.yField,
    required this.xReversed,
    required this.yReversed,
  });

  /// Builds a view of [table], or `null` if its fields cannot be resolved.
  static TableView? of(
    TuneState tune,
    IniTable table, {
    TuneValueResolver? resolver,
  }) {
    final page = table.page;
    if (page == null) return null;

    final z = tune.definition.constants.findField(table.zBins)?.field;
    final x = tune.definition.constants.findField(table.xBins.constant)?.field;
    final y = tune.definition.constants.findField(table.yBins.constant)?.field;
    if (z is! IniArrayField || x is! IniArrayField || y is! IniArrayField) {
      return null;
    }
    if (z.shape.length != 2) return null;

    final view = TableView._(
      table: table,
      tune: tune,
      resolver: resolver ?? TuneValueResolver(tune),
      page: page,
      zField: z,
      xField: x,
      yField: y,
      xReversed: false,
      yReversed: false,
    );

    // Axes are defined to be increasing, so a descending read means the axis
    // is stored in reverse.
    return TableView._(
      table: table,
      tune: tune,
      resolver: view.resolver,
      page: page,
      zField: z,
      xField: x,
      yField: y,
      xReversed: view._storedDescending(x, z.shape[1]),
      yReversed: view._storedDescending(y, z.shape[0]),
    );
  }

  final IniTable table;
  final TuneState tune;
  final TuneValueResolver resolver;
  final int page;
  final IniArrayField zField;
  final IniArrayField xField;
  final IniArrayField yField;

  /// Whether the X axis *array* is stored high-to-low.
  ///
  /// Applies to the bin values only. The table's value columns are stored in
  /// ascending-X order regardless - see [_cellIndex].
  final bool xReversed;

  /// Whether the Y axis array is stored high-to-low.
  ///
  /// Unlike X, the value rows do follow this.
  final bool yReversed;

  /// Number of columns (X positions).
  int get columns => zField.shape[1];

  /// Number of rows (Y positions).
  int get rows => zField.shape[0];

  /// Human-readable title.
  String get title => table.title;

  bool _storedDescending(IniArrayField axis, int length) {
    num? first;
    num? last;
    for (var i = 0; i < length; i++) {
      final value = tune.readRaw(page, axis, i);
      if (value == null) continue;
      first ??= value;
      last = value;
    }
    if (first == null || last == null) return false;
    return last < first;
  }

  int _storageIndex(int logical, int length, bool reversed) =>
      reversed ? length - 1 - logical : logical;

  // --- Axis access ---------------------------------------------------------

  /// X axis value at [column], in engineering units.
  double? xAt(int column) =>
      _axisValue(xField, _storageIndex(column, columns, xReversed));

  /// Y axis value at [row], in engineering units.
  double? yAt(int row) =>
      _axisValue(yField, _storageIndex(row, rows, yReversed));

  double? _axisValue(IniArrayField axis, int index) {
    final raw = tune.readRaw(page, axis, index);
    if (raw == null) return null;
    final scale = resolver.valueOf(axis.scale) ?? 1;
    final translate = resolver.valueOf(axis.translate) ?? 0;
    return raw * scale + translate;
  }

  /// Sets the X axis bin at [column], in engineering units.
  ///
  /// Clamped to the bounds the definition declares for the axis field, then
  /// stored through its scale and translate exactly as a cell value is.
  void setXAt(int column, double value) {
    if (column < 0 || column >= columns) {
      throw RangeError('Column $column is outside 0..${columns - 1}');
    }
    _setAxisValue(
      xField,
      _storageIndex(column, columns, xReversed),
      value,
    );
  }

  /// Sets the Y axis bin at [row], in engineering units.
  void setYAt(int row, double value) {
    if (row < 0 || row >= rows) {
      throw RangeError('Row $row is outside 0..${rows - 1}');
    }
    _setAxisValue(yField, _storageIndex(row, rows, yReversed), value);
  }

  void _setAxisValue(IniArrayField axis, int index, double value) {
    final scale = resolver.valueOf(axis.scale) ?? 1;
    final translate = resolver.valueOf(axis.translate) ?? 0;
    final effective = scale == 0 ? 1.0 : scale;

    var clamped = value;
    final low = resolver.valueOf(axis.low);
    final high = resolver.valueOf(axis.high);
    if (low != null && clamped < low) clamped = low;
    if (high != null && clamped > high) clamped = high;

    tune.writeRaw(page, axis, (clamped - translate) / effective, index);
  }

  /// Smallest change a table value can represent, in engineering units.
  ///
  /// The storage step, as opposed to the display precision - used when a value
  /// has to be written out without losing anything.
  double get zStep => TuneState.stepOf(zField, _zScale);

  /// Smallest change an X axis bin can represent.
  double get xStep =>
      TuneState.stepOf(xField, resolver.valueOf(xField.scale) ?? 1);

  /// Smallest change a Y axis bin can represent.
  double get yStep =>
      TuneState.stepOf(yField, resolver.valueOf(yField.scale) ?? 1);

  /// Decimal places for displaying X axis bins.
  int get xDecimals => xField.digits ?? 0;

  /// Decimal places for displaying Y axis bins.
  int get yDecimals => yField.digits ?? 0;

  /// Bounds the definition permits for X axis bins.
  ({double? low, double? high}) get xBounds =>
      (low: resolver.valueOf(xField.low), high: resolver.valueOf(xField.high));

  /// Bounds the definition permits for Y axis bins.
  ({double? low, double? high}) get yBounds =>
      (low: resolver.valueOf(yField.low), high: resolver.valueOf(yField.high));

  /// Whether the X axis still increases from left to right.
  ///
  /// The ECU interpolates on the assumption that bins ascend, and so does
  /// [preciseCellFor]. Editing is not blocked when an axis stops ascending -
  /// that would make it impossible to spread bins out, since every edit passes
  /// through an inconsistent intermediate state - but callers should surface
  /// it, because a tune in that state will not behave.
  bool get isXAxisAscending => _isAscending(columns, xAt);

  /// Whether the Y axis still increases from bottom to top.
  bool get isYAxisAscending => _isAscending(rows, yAt);

  bool _isAscending(int count, double? Function(int) axis) {
    double? previous;
    for (var i = 0; i < count; i++) {
      final value = axis(i);
      if (value == null) continue;
      if (previous != null && value < previous) return false;
      previous = value;
    }
    return true;
  }

  /// Units label for the X axis.
  String get xUnits => _unitsOf(xField);

  /// Units label for the Y axis.
  String get yUnits => _unitsOf(yField);

  /// Units label for the table values.
  String get zUnits => _unitsOf(zField);

  /// Resolves an axis's units label.
  ///
  /// Units are not always a literal. A load axis declares
  /// `{ bitStringValue(algorithmUnits, algorithm) }`, meaning "the option of
  /// `algorithmUnits` selected by the `algorithm` setting" - so the axis reads
  /// kPa, % TPS or % depending on how the engine is configured. Rendering the
  /// expression source verbatim, as a bare `{ bitStringValue(al...`, is worse
  /// than showing nothing, so an unresolvable expression yields an empty label.
  String _unitsOf(IniArrayField field) {
    final units = field.units.trim();
    if (!units.startsWith('{') || !units.endsWith('}')) return units;
    return evaluateLabel(
          units.substring(1, units.length - 1),
          definition: tune.definition,
          resolve: resolver.resolve,
        ) ??
        '';
  }

  /// Decimal places for displaying table values.
  int get zDecimals => zField.digits ?? 0;

  // --- Cell access ---------------------------------------------------------

  int _cellIndex(int row, int column) {
    // Rows follow the Y axis array, but columns do NOT follow the X axis
    // array. The firmware stores both axis arrays descending, yet lays the
    // values out with row 0 at Y-Max and column 0 at X-Min - its own worked
    // example has `value[0][0]` holding the cell at (Y-Max, X-Min) while
    // `x[0]` holds X-Max. Mirroring the columns to match the axis array
    // transposes the table left-to-right, which on a VE table means fuelling
    // the top of the rev range with idle numbers.
    //
    // Confirmed against a TunerStudio-written tune: with the columns mirrored,
    // our display was the exact reverse of TunerStudio's for the same row.
    final storedRow = _storageIndex(row, rows, yReversed);
    return storedRow * columns + column;
  }

  /// Value at [row], [column] in engineering units.
  double? valueAt(int row, int column) {
    if (!_inBounds(row, column)) return null;
    final raw = tune.readRaw(page, zField, _cellIndex(row, column));
    if (raw == null) return null;
    return raw * _zScale + _zTranslate;
  }

  /// Raw stored value at [row], [column].
  num? rawAt(int row, int column) => _inBounds(row, column)
      ? tune.readRaw(page, zField, _cellIndex(row, column))
      : null;

  /// Writes [value] (engineering units) at [row], [column].
  ///
  /// The value is clamped to the definition's declared bounds before it is
  /// stored, so a fat-fingered entry cannot put an out-of-range number on the
  /// wire.
  void setValueAt(int row, int column, double value) {
    if (!_inBounds(row, column)) {
      throw RangeError('Cell ($row, $column) is outside '
          '${rows}x$columns');
    }
    final clamped = clampToBounds(value);
    tune.writeRaw(
      page,
      zField,
      (clamped - _zTranslate) / _zScale,
      _cellIndex(row, column),
    );
  }

  bool _inBounds(int row, int column) =>
      row >= 0 && row < rows && column >= 0 && column < columns;

  double get _zScale {
    final scale = resolver.valueOf(zField.scale) ?? 1;
    return scale == 0 ? 1 : scale;
  }

  double get _zTranslate => resolver.valueOf(zField.translate) ?? 0;

  /// Lowest value the definition permits, in engineering units.
  double? get low => resolver.valueOf(zField.low);

  /// Highest value the definition permits, in engineering units.
  double? get high => resolver.valueOf(zField.high);

  /// Clamps [value] into the definition's declared bounds.
  double clampToBounds(double value) {
    var result = value;
    final lo = low;
    final hi = high;
    if (lo != null && result < lo) result = lo;
    if (hi != null && result > hi) result = hi;
    return result;
  }

  /// Cells whose value differs from [baseline], and in which direction.
  ///
  /// Used to show what this session has touched but not yet burned. Direction
  /// matters more than the fact of a change: on a fuel table, leaner and
  /// richer carry very different risk, and a tuner scanning a map wants to see
  /// at a glance which way it was pushed.
  ///
  /// Returns empty when the tables are not comparable, rather than reporting
  /// every cell as changed.
  Map<({int row, int column}), CellChange> changesAgainst(TableView baseline) {
    if (baseline.rows != rows || baseline.columns != columns) return const {};

    final changes = <({int row, int column}), CellChange>{};
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < columns; c++) {
        final now = valueAt(r, c);
        final was = baseline.valueAt(r, c);
        if (now == null || was == null || now == was) continue;
        changes[(row: r, column: c)] =
            now > was ? CellChange.raised : CellChange.lowered;
      }
    }
    return changes;
  }

  /// The whole table as rows of engineering values, row 0 lowest Y.
  List<List<double?>> toGrid() => [
        for (var r = 0; r < rows; r++)
          [for (var c = 0; c < columns; c++) valueAt(r, c)],
      ];

  // --- Editing operations --------------------------------------------------

  /// Adds [delta] to every cell in [cells].
  void adjustBy(Iterable<({int row, int column})> cells, double delta) {
    for (final cell in cells) {
      final current = valueAt(cell.row, cell.column);
      if (current == null) continue;
      setValueAt(cell.row, cell.column, current + delta);
    }
  }

  /// Scales every cell in [cells] by [percent] (100 = unchanged).
  void scaleBy(Iterable<({int row, int column})> cells, double percent) {
    for (final cell in cells) {
      final current = valueAt(cell.row, cell.column);
      if (current == null) continue;
      setValueAt(cell.row, cell.column, current * percent / 100);
    }
  }

  /// Sets every cell in [cells] to [value].
  void fill(Iterable<({int row, int column})> cells, double value) {
    for (final cell in cells) {
      setValueAt(cell.row, cell.column, value);
    }
  }

  /// Linearly interpolates the interior of the rectangle spanned by [cells]
  /// from its corners.
  ///
  /// Used to smooth a region between hand-set corner values, which is the
  /// usual way a tuner fills in a block.
  void interpolateRegion(Iterable<({int row, int column})> cells) {
    if (cells.isEmpty) return;
    final rowsIn = cells.map((c) => c.row).toList()..sort();
    final colsIn = cells.map((c) => c.column).toList()..sort();
    final r0 = rowsIn.first;
    final r1 = rowsIn.last;
    final c0 = colsIn.first;
    final c1 = colsIn.last;
    if (r1 - r0 < 1 && c1 - c0 < 1) return;

    final tl = valueAt(r0, c0);
    final tr = valueAt(r0, c1);
    final bl = valueAt(r1, c0);
    final br = valueAt(r1, c1);
    if (tl == null || tr == null || bl == null || br == null) return;

    for (var r = r0; r <= r1; r++) {
      final fy = r1 == r0 ? 0.0 : (r - r0) / (r1 - r0);
      for (var c = c0; c <= c1; c++) {
        final fx = c1 == c0 ? 0.0 : (c - c0) / (c1 - c0);
        final top = tl + (tr - tl) * fx;
        final bottom = bl + (br - bl) * fx;
        setValueAt(r, c, top + (bottom - top) * fy);
      }
    }
  }

  /// Averages each cell in [cells] with its orthogonal neighbours.
  ///
  /// Reads come from a snapshot taken first, so smoothing a region does not
  /// feed partially-smoothed values back into its own later cells.
  void smooth(Iterable<({int row, int column})> cells) {
    final before = toGrid();
    for (final cell in cells) {
      final centre = before[cell.row][cell.column];
      if (centre == null) continue;

      var sum = centre;
      var count = 1;
      for (final (dr, dc) in const [(-1, 0), (1, 0), (0, -1), (0, 1)]) {
        final r = cell.row + dr;
        final c = cell.column + dc;
        if (r < 0 || r >= rows || c < 0 || c >= columns) continue;
        final neighbour = before[r][c];
        if (neighbour == null) continue;
        sum += neighbour;
        count++;
      }
      setValueAt(cell.row, cell.column, sum / count);
    }
  }

  /// The cell whose axis ranges contain ([x], [y]).
  ///
  /// Drives the live cursor that shows where the engine is operating.
  ({int row, int column})? cellFor(double x, double y) {
    final column = _nearestIndex(columns, xAt, x);
    final row = _nearestIndex(rows, yAt, y);
    if (column == null || row == null) return null;
    return (row: row, column: column);
  }

  /// The table's value at ([x], [y]), interpolated as the ECU would.
  ///
  /// Not the same as reading the nearest cell. A target table is consulted at
  /// the operating point, and its axis bins need not line up with the table
  /// being tuned against it - Speeduino's AFR target table has its own
  /// `rpmBinsAFR` and `loadBinsAFR`, at a different resolution from the VE
  /// table's. Reading it by cell index would compare against the wrong target.
  double? interpolatedAt(double x, double y) {
    final weights = weightsAt(x, y);
    if (weights.isEmpty) return null;

    var total = 0.0;
    var sum = 0.0;
    for (final entry in weights) {
      final value = valueAt(entry.row, entry.column);
      if (value == null) return null;
      sum += value * entry.weight;
      total += entry.weight;
    }
    return total == 0 ? null : sum / total;
  }

  /// How much each surrounding cell contributes at ([x], [y]).
  ///
  /// The bilinear weights the ECU interpolates with, summing to 1. At an edge
  /// the bracket collapses and the weights merge onto fewer cells rather than
  /// being lost, so the total still comes to 1.
  List<({int row, int column, double weight})> weightsAt(double x, double y) {
    final at = preciseCellFor(x, y);
    if (at == null) return const [];

    final r0 = at.row.floor().clamp(0, rows - 1);
    final c0 = at.column.floor().clamp(0, columns - 1);
    final r1 = (r0 + 1).clamp(0, rows - 1);
    final c1 = (c0 + 1).clamp(0, columns - 1);
    final fr = (at.row - r0).clamp(0.0, 1.0);
    final fc = (at.column - c0).clamp(0.0, 1.0);

    // Merged by cell, because at an edge r1 == r0 and two corners coincide.
    final merged = <({int row, int column}), double>{};
    void add(int row, int column, double weight) {
      if (weight <= 0) return;
      merged[(row: row, column: column)] =
          (merged[(row: row, column: column)] ?? 0) + weight;
    }

    add(r0, c0, (1 - fr) * (1 - fc));
    add(r0, c1, (1 - fr) * fc);
    add(r1, c0, fr * (1 - fc));
    add(r1, c1, fr * fc);

    return [
      for (final entry in merged.entries)
        (row: entry.key.row, column: entry.key.column, weight: entry.value),
    ];
  }

  /// The cells whose values determine the interpolated output at a position.
  ///
  /// The ECU interpolates between the four cells bracketing the operating
  /// point, so these - not the single nearest cell - are what an edit has to
  /// change to alter behaviour there. Fewer than four are returned at the
  /// edges of the table, where the bracket collapses.
  List<({int row, int column})> contributingCells(double row, double column) {
    if (rows == 0 || columns == 0) return const [];

    final r0 = row.floor().clamp(0, rows - 1);
    final c0 = column.floor().clamp(0, columns - 1);
    final r1 = (r0 + 1).clamp(0, rows - 1);
    final c1 = (c0 + 1).clamp(0, columns - 1);

    final cells = <({int row, int column})>[];
    for (final r in {r0, r1}) {
      for (final c in {c0, c1}) {
        cells.add((row: r, column: c));
      }
    }
    return cells;
  }

  /// The exact position of ([x], [y]) on the grid, as continuous indices.
  ///
  /// [cellFor] snaps to the nearest bin, which is what an editor needs to know
  /// which cell is in play. But the engine rarely sits on a bin: at 3250 rpm
  /// between bins at 3000 and 3500 the true position is halfway between two
  /// columns. This interpolates between the surrounding bins so an indicator
  /// can be drawn where the engine actually is, rather than snapped.
  ///
  /// Values outside the axis range clamp to the end bins - the engine can run
  /// past the top of a table, but there is nowhere beyond it to point at.
  ({double row, double column})? preciseCellFor(double x, double y) {
    final column = _fractionalIndex(columns, xAt, x);
    final row = _fractionalIndex(rows, yAt, y);
    if (column == null || row == null) return null;
    return (row: row, column: column);
  }

  double? _fractionalIndex(
      int count, double? Function(int) axis, double target) {
    final points = <({int index, double value})>[];
    for (var i = 0; i < count; i++) {
      final value = axis(i);
      if (value != null) points.add((index: i, value: value));
    }
    if (points.isEmpty) return null;
    if (points.length == 1) return points.first.index.toDouble();

    if (target <= points.first.value) return points.first.index.toDouble();
    if (target >= points.last.value) return points.last.index.toDouble();

    for (var i = 0; i < points.length - 1; i++) {
      final low = points[i];
      final high = points[i + 1];
      if (target >= low.value && target <= high.value) {
        final span = high.value - low.value;
        // Repeated bins would divide by zero; fall back to the lower one.
        if (span == 0) return low.index.toDouble();
        final fraction = (target - low.value) / span;
        return low.index + (high.index - low.index) * fraction;
      }
    }
    return points.last.index.toDouble();
  }

  int? _nearestIndex(int count, double? Function(int) axis, double target) {
    int? best;
    double? bestDistance;
    for (var i = 0; i < count; i++) {
      final value = axis(i);
      if (value == null) continue;
      final distance = (value - target).abs();
      if (bestDistance == null || distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }
}
