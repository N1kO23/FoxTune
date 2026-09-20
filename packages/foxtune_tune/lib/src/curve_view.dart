import 'package:foxtune_ini/foxtune_ini.dart';

import 'table_view.dart' show CellChange;
import 'tune_state.dart';
import 'value_resolver.dart';

/// An editable view of a 2D curve, in engineering units.
///
/// The 2D counterpart of a [TableView]: a list of X bins and the Y value at
/// each. Warmup enrichment, afterstart enrichment, dwell correction and the
/// idle targets are all curves, so this is what makes those screens editable
/// rather than merely visible.
///
/// As with tables, the axis is presented ascending whatever order the bytes
/// are in: a bin array that reads back descending is stored reversed, and both
/// reads and writes go through the same mapping so a round trip is exact.
class CurveView {
  CurveView._({
    required this.curve,
    required this.tune,
    required this.resolver,
    required this.xPage,
    required this.yPage,
    required this.xField,
    required this.yField,
    required this.length,
    required this.reversed,
  });

  /// Builds a view of [curve], or `null` if its bins cannot be resolved.
  ///
  /// Some curves take their axis from a `[PcVariables]` entry, which has no
  /// bytes on any page; those are not editable and yield `null` rather than a
  /// view that silently reads nothing.
  static CurveView? of(
    TuneState tune,
    IniCurve curve, {
    TuneValueResolver? resolver,
  }) {
    final x = tune.locate(curve.xBins.constant);
    final y = tune.locate(curve.yBins.constant);
    if (x == null || y == null) return null;

    final xField = x.field;
    final yField = y.field;
    if (xField is! IniArrayField || yField is! IniArrayField) return null;
    if (xField.offset == null || yField.offset == null) return null;

    // The two arrays should be the same length. Where a definition disagrees,
    // the shorter one bounds what can be shown without reading past its end.
    final length =
        xField.length < yField.length ? xField.length : yField.length;
    if (length == 0) return null;

    final view = CurveView._(
      curve: curve,
      tune: tune,
      resolver: resolver ?? TuneValueResolver(tune),
      xPage: x.page,
      yPage: y.page,
      xField: xField,
      yField: yField,
      length: length,
      reversed: false,
    );

    return CurveView._(
      curve: curve,
      tune: tune,
      resolver: view.resolver,
      xPage: x.page,
      yPage: y.page,
      xField: xField,
      yField: yField,
      length: length,
      reversed: view._storedDescending(),
    );
  }

  final IniCurve curve;
  final TuneState tune;
  final TuneValueResolver resolver;

  /// 1-based page holding the X bins.
  final int xPage;

  /// 1-based page holding the Y values. Usually the same as [xPage].
  final int yPage;

  final IniArrayField xField;
  final IniArrayField yField;

  /// Number of points.
  final int length;

  /// Whether the bins are stored high-to-low.
  final bool reversed;

  /// Human-readable title.
  String get title => curve.title;

  /// Column headings the definition supplies, e.g. `["Voltage", "Dwell"]`.
  List<String> get columnLabels => curve.columnLabels;

  /// Heading for the X column, falling back to the axis units.
  String get xLabel => columnLabels.isNotEmpty ? columnLabels[0] : xUnits;

  /// Heading for the Y column, falling back to the axis units.
  String get yLabel => columnLabels.length > 1 ? columnLabels[1] : yUnits;

  /// The realtime channel that drives the live cursor, where one is declared.
  String? get xChannel => curve.xBins.channel;

  bool _storedDescending() {
    final first = tune.readRaw(xPage, xField, 0);
    final last = tune.readRaw(xPage, xField, length - 1);
    if (first == null || last == null) return false;
    return last < first;
  }

  int _storageIndex(int logical) => reversed ? length - 1 - logical : logical;

  // --- Reading -------------------------------------------------------------

  /// X bin at [point], in engineering units.
  double? xAt(int point) =>
      _inBounds(point) ? _read(xPage, xField, _storageIndex(point)) : null;

  /// Y value at [point], in engineering units.
  double? yAt(int point) =>
      _inBounds(point) ? _read(yPage, yField, _storageIndex(point)) : null;

  double? _read(int page, IniArrayField field, int at) {
    final raw = tune.readRaw(page, field, at);
    if (raw == null) return null;
    return raw * _scaleOf(field) + _translateOf(field);
  }

  bool _inBounds(int point) => point >= 0 && point < length;

  double _scaleOf(IniArrayField field) {
    final scale = resolver.valueOf(field.scale) ?? 1;
    return scale == 0 ? 1 : scale;
  }

  double _translateOf(IniArrayField field) =>
      resolver.valueOf(field.translate) ?? 0;

  // --- Writing -------------------------------------------------------------

  /// Sets the X bin at [point], clamped to the definition's bounds.
  void setXAt(int point, double value) =>
      _write(xPage, xField, point, value, xBounds);

  /// Sets the Y value at [point], clamped to the definition's bounds.
  void setYAt(int point, double value) =>
      _write(yPage, yField, point, value, yBounds);

  void _write(
    int page,
    IniArrayField field,
    int point,
    double value,
    ({double? low, double? high}) bounds,
  ) {
    if (!_inBounds(point)) {
      throw RangeError('Point $point is outside 0..${length - 1}');
    }
    var clamped = value;
    if (bounds.low != null && clamped < bounds.low!) clamped = bounds.low!;
    if (bounds.high != null && clamped > bounds.high!) clamped = bounds.high!;

    tune.writeRaw(
      page,
      field,
      ((clamped - _translateOf(field)) / _scaleOf(field)).round(),
      _storageIndex(point),
    );
  }

  // --- Presentation --------------------------------------------------------

  /// Units label for the X axis.
  String get xUnits => xField.units;

  /// Units label for the Y axis.
  String get yUnits => yField.units;

  /// Decimal places for displaying X bins.
  int get xDecimals => xField.digits ?? 0;

  /// Decimal places for displaying Y values.
  int get yDecimals => yField.digits ?? 0;

  /// Smallest change an X bin can represent.
  double get xStep => _scaleOf(xField).abs();

  /// Smallest change a Y value can represent.
  double get yStep => _scaleOf(yField).abs();

  /// Bounds the definition permits for X bins.
  ({double? low, double? high}) get xBounds =>
      (low: resolver.valueOf(xField.low), high: resolver.valueOf(xField.high));

  /// Bounds the definition permits for Y values.
  ({double? low, double? high}) get yBounds =>
      (low: resolver.valueOf(yField.low), high: resolver.valueOf(yField.high));

  /// Plot range for the X axis as `min, max, divisions`, where declared.
  ///
  /// This is the window the definition wants the curve drawn in, which is not
  /// the same as the range the bins happen to span - it keeps the plot stable
  /// while a bin is being dragged.
  List<double> get xAxisRange => curve.xAxis;

  /// Plot range for the Y axis as `min, max, divisions`, where declared.
  List<double> get yAxisRange => curve.yAxis;

  /// Whether the X bins still increase from left to right.
  ///
  /// The ECU interpolates on the assumption that they do. Editing is not
  /// blocked when they stop ascending - spreading bins out passes through
  /// inconsistent intermediate states - but a caller should surface it.
  bool get isAscending {
    double? previous;
    for (var i = 0; i < length; i++) {
      final value = xAt(i);
      if (value == null) continue;
      if (previous != null && value < previous) return false;
      previous = value;
    }
    return true;
  }

  /// The curve's value at [x], interpolated between the bracketing bins.
  ///
  /// Positions beyond either end hold at the end value, which is what the
  /// firmware does.
  double? valueAt(double x) {
    final points = <({double x, double y})>[];
    for (var i = 0; i < length; i++) {
      final bin = xAt(i);
      final value = yAt(i);
      if (bin != null && value != null) points.add((x: bin, y: value));
    }
    if (points.isEmpty) return null;
    if (x <= points.first.x) return points.first.y;
    if (x >= points.last.x) return points.last.y;

    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      if (x > b.x) continue;
      final span = b.x - a.x;
      if (span == 0) return b.y;
      return a.y + (b.y - a.y) * (x - a.x) / span;
    }
    return points.last.y;
  }

  /// The position of [x] on the curve as a continuous index.
  ///
  /// Used to draw the live cursor where the engine actually is rather than
  /// snapped to the nearest bin.
  double? fractionalIndexFor(double x) {
    final bins = <({int index, double value})>[];
    for (var i = 0; i < length; i++) {
      final value = xAt(i);
      if (value != null) bins.add((index: i, value: value));
    }
    if (bins.isEmpty) return null;
    if (bins.length == 1) return bins.first.index.toDouble();
    if (x <= bins.first.value) return bins.first.index.toDouble();
    if (x >= bins.last.value) return bins.last.index.toDouble();

    for (var i = 1; i < bins.length; i++) {
      final a = bins[i - 1];
      final b = bins[i];
      if (x > b.value) continue;
      final span = b.value - a.value;
      if (span == 0) return b.index.toDouble();
      return a.index + (b.index - a.index) * (x - a.value) / span;
    }
    return bins.last.index.toDouble();
  }

  /// Points whose Y value differs from [baseline], and in which direction.
  ///
  /// Returns empty when the curves are not comparable, rather than reporting
  /// every point as changed.
  Map<int, CellChange> changesAgainst(CurveView baseline) {
    if (baseline.length != length) return const {};
    final changes = <int, CellChange>{};
    for (var i = 0; i < length; i++) {
      final now = yAt(i);
      final was = baseline.yAt(i);
      if (now == null || was == null || now == was) continue;
      changes[i] = now > was ? CellChange.raised : CellChange.lowered;
    }
    return changes;
  }

  @override
  String toString() => 'CurveView(${curve.id}, $length points)';
}
