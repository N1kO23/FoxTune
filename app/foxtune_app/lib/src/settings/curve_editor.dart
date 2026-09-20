import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../tune/table_grid.dart' show EditTint;

/// The plot window a curve is drawn in.
///
/// The definition declares one (`xAxis = 0, 1200, 6`), which is deliberately
/// wider than the bins usually span: holding the window still while a bin is
/// dragged is what stops the whole plot jumping under the tuner's finger.
@immutable
class CurveWindow {
  const CurveWindow({
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
  });

  /// Reads the window from a curve, falling back to the range of its own data.
  factory CurveWindow.of(CurveView view) {
    final declaredX = view.xAxisRange;
    final declaredY = view.yAxisRange;

    var xMin = declaredX.length >= 2 ? declaredX[0] : double.nan;
    var xMax = declaredX.length >= 2 ? declaredX[1] : double.nan;
    var yMin = declaredY.length >= 2 ? declaredY[0] : double.nan;
    var yMax = declaredY.length >= 2 ? declaredY[1] : double.nan;

    if (xMin.isNaN || xMax <= xMin) {
      final xs = [for (var i = 0; i < view.length; i++) ?view.xAt(i)];
      xMin = xs.isEmpty ? 0 : xs.reduce((a, b) => a < b ? a : b);
      xMax = xs.isEmpty ? 1 : xs.reduce((a, b) => a > b ? a : b);
    }
    if (yMin.isNaN || yMax <= yMin) {
      final ys = [for (var i = 0; i < view.length; i++) ?view.yAt(i)];
      yMin = ys.isEmpty ? 0 : ys.reduce((a, b) => a < b ? a : b);
      yMax = ys.isEmpty ? 1 : ys.reduce((a, b) => a > b ? a : b);
    }

    // A window with no height cannot be drawn in; give it one.
    if (xMax <= xMin) xMax = xMin + 1;
    if (yMax <= yMin) yMax = yMin + 1;

    return CurveWindow(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax);
  }

  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
}

/// Where a curve point falls inside a plot of [size].
///
/// Y grows upwards on the plot and downwards in canvas coordinates, which is
/// the flip that is easy to get wrong and obvious once wrong.
@visibleForTesting
Offset curvePlotPointFor(CurveWindow window, Size size, double x, double y) {
  final fx = (x - window.xMin) / (window.xMax - window.xMin);
  final fy = (y - window.yMin) / (window.yMax - window.yMin);
  return Offset(fx * size.width, (1 - fy) * size.height);
}

/// A curve: a line plot above an editable row of points.
///
/// Warmup enrichment, afterstart enrichment, dwell correction and the idle
/// targets are all curves, so this is the second editor - after the table
/// grid - that most of a tune is actually adjusted through.
class CurveEditor extends StatelessWidget {
  const CurveEditor({
    super.key,
    required this.view,
    required this.editable,
    required this.onEdit,
    this.baseline,
    this.cursorX,
  });

  /// The curve being edited.
  final CurveView view;

  /// Whether the session may change it.
  final bool editable;

  /// Called after a point changes.
  final VoidCallback onEdit;

  /// The same curve as last synchronised with the ECU, for change marking.
  final CurveView? baseline;

  /// Where the engine is on the X axis right now, where the link is live.
  final double? cursorX;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final changes = baseline == null
        ? const <int, CellChange>{}
        : view.changesAgainst(baseline!);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(view.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SizedBox(
              height: 170,
              child: CustomPaint(
                painter: _CurvePainter(
                  view: view,
                  window: CurveWindow.of(view),
                  cursorX: cursorX,
                  line: scheme.primary,
                  grid: scheme.outlineVariant,
                  cursor: scheme.tertiary,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 10),
            if (!view.isAscending)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: scheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'The ${view.xLabel} axis no longer increases. The ECU '
                        'interpolates assuming it does.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _RowHeadings(view: view),
                  for (var i = 0; i < view.length; i++)
                    _CurvePointColumn(
                      view: view,
                      point: i,
                      editable: editable,
                      onEdit: onEdit,
                      change: changes[i],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowHeadings extends StatelessWidget {
  const _RowHeadings({required this.view});

  final CurveView view;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(height: 40, child: Text(view.xLabel, style: style)),
          SizedBox(height: 40, child: Text(view.yLabel, style: style)),
        ],
      ),
    );
  }
}

class _CurvePointColumn extends StatelessWidget {
  const _CurvePointColumn({
    required this.view,
    required this.point,
    required this.editable,
    required this.onEdit,
    this.change,
  });

  final CurveView view;
  final int point;
  final bool editable;
  final VoidCallback onEdit;
  final CellChange? change;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Column(
        children: [
          _CurveValueField(
            read: () => view.xAt(point),
            decimals: view.xDecimals,
            editable: editable,
            onCommit: (v) {
              view.setXAt(point, v);
              onEdit();
            },
          ),
          const SizedBox(height: 4),
          _CurveValueField(
            read: () => view.yAt(point),
            decimals: view.yDecimals,
            editable: editable,
            change: change,
            onCommit: (v) {
              view.setYAt(point, v);
              onEdit();
            },
          ),
        ],
      ),
    );
  }
}

/// One editable number in a curve.
///
/// The value is read back through [read] rather than captured, because a
/// commit has to compare against what is stored *now*. Reading it from the
/// widget built before the edit reports the old number, and resetting the box
/// to that undoes the edit on the way out of the field.
class _CurveValueField extends StatefulWidget {
  const _CurveValueField({
    required this.read,
    required this.decimals,
    required this.editable,
    required this.onCommit,
    this.change,
  });

  final double? Function() read;
  final int decimals;
  final bool editable;
  final ValueChanged<double> onCommit;
  final CellChange? change;

  @override
  State<_CurveValueField> createState() => _CurveValueFieldState();
}

class _CurveValueFieldState extends State<_CurveValueField> {
  late final TextEditingController _controller = TextEditingController(
    text: _text,
  );
  final FocusNode _focus = FocusNode();

  String get _text => widget.read()?.toStringAsFixed(widget.decimals) ?? '';

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final typed = double.tryParse(_controller.text.trim());
    // Writing a value that is already stored would mark the page as changed
    // for nothing, and tabbing across a curve would then ask for a burn.
    if (typed != null && typed != widget.read()) widget.onCommit(typed);
    // Whatever was typed, the box now shows what is actually stored: the
    // clamped value, at the precision the storage can hold.
    if (_controller.text != _text) _controller.text = _text;
  }

  @override
  Widget build(BuildContext context) {
    if (!_focus.hasFocus && _controller.text != _text) {
      _controller.text = _text;
    }

    final scheme = Theme.of(context).colorScheme;
    final tint = switch (widget.change) {
      CellChange.raised => EditTint.raised,
      CellChange.lowered => EditTint.lowered,
      null => null,
    };

    return SizedBox(
      width: 68,
      height: 40,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        enabled: widget.editable,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: tint ?? scheme.onSurface,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 10,
          ),
          border: const OutlineInputBorder(),
          enabledBorder: tint == null
              ? null
              : OutlineInputBorder(borderSide: BorderSide(color: tint)),
        ),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.view,
    required this.window,
    required this.line,
    required this.grid,
    required this.cursor,
    this.cursorX,
  });

  final CurveView view;
  final CurveWindow window;
  final double? cursorX;
  final Color line;
  final Color grid;
  final Color cursor;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;

    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    final points = <Offset>[];
    for (var i = 0; i < view.length; i++) {
      final x = view.xAt(i);
      final y = view.yAt(i);
      if (x == null || y == null) continue;
      points.add(curvePlotPointFor(window, size, x, y));
    }

    if (points.length > 1) {
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    final dot = Paint()..color = line;
    for (final point in points) {
      canvas.drawCircle(point, 3.5, dot);
    }

    // Where the engine is on this axis right now.
    final at = cursorX;
    if (at != null) {
      final x = curvePlotPointFor(window, size, at, window.yMin).dx;
      if (x >= 0 && x <= size.width) {
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = cursor
            ..strokeWidth = 2,
        );
        final y = view.valueAt(at);
        if (y != null) {
          canvas.drawCircle(
            curvePlotPointFor(window, size, at, y),
            5,
            Paint()
              ..color = cursor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CurvePainter old) => true;
}
