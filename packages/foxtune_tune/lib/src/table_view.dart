import 'package:foxtune_ini/foxtune_ini.dart';

import 'tune_state.dart';
import 'value_resolver.dart';

/// An editable view of a 3D table, in engineering units.
///
/// ## Axis orientation
///
/// The firmware stores table rows and axes reversed relative to how a tuner
/// reads them, and its own documentation is ambiguous about the column order.
/// Rather than hardcode a guess - a transposed VE table written to a running
/// engine is exactly the kind of mistake that destroys hardware - orientation
/// is **derived from the data**: axis bins must increase, so an axis that reads
/// back descending tells us that axis is stored reversed, and the values are
/// flipped to match.
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

  /// Whether the X axis is stored high-to-low.
  final bool xReversed;

  /// Whether the Y axis is stored high-to-low.
  final bool yReversed;

  /// Number of columns (X positions).
  int get columns => zField.shape[1];

  /// Number of rows (Y positions).
  int get rows => zField.shape[0];

  /// Human-readable title.
  String get title => table.title;

  bool _storedDescending(IniArrayField axis, int length) {
    int? first;
    int? last;
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

    final source = units.substring(1, units.length - 1).trim();
    final call = RegExp(r'^bitStringValue\(\s*(\w+)\s*,\s*(\w+)\s*\)$')
        .firstMatch(source);
    if (call == null) return '';

    final options = tune.definition.findField(call.group(1)!);
    final index = resolver.resolve(call.group(2)!);
    if (options is! IniBitsField || index == null) return '';

    final label = options.labelFor(index.toInt());
    return label == null || label == 'INVALID' ? '' : label;
  }

  /// Decimal places for displaying table values.
  int get zDecimals => zField.digits ?? 0;

  // --- Cell access ---------------------------------------------------------

  int _cellIndex(int row, int column) {
    final storedRow = _storageIndex(row, rows, yReversed);
    final storedColumn = _storageIndex(column, columns, xReversed);
    // Values follow the axes, laid out row-major.
    return storedRow * columns + storedColumn;
  }

  /// Value at [row], [column] in engineering units.
  double? valueAt(int row, int column) {
    if (!_inBounds(row, column)) return null;
    final raw = tune.readRaw(page, zField, _cellIndex(row, column));
    if (raw == null) return null;
    return raw * _zScale + _zTranslate;
  }

  /// Raw stored value at [row], [column].
  int? rawAt(int row, int column) => _inBounds(row, column)
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
    final raw = ((clamped - _zTranslate) / _zScale).round();
    tune.writeRaw(page, zField, raw, _cellIndex(row, column));
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
