import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Projects a point on the table onto the isometric view.
///
/// [row] 0 is the LOWEST Y and must render at the front, matching the 2D grid
/// where the lowest load is the bottom row. Screen y grows downward, so the row
/// axis is negated here; without that the surface reads mirrored against the
/// table beneath it.
@visibleForTesting
Offset surfacePointFor({
  required double row,
  required double column,
  required double heightFraction,
  required int rows,
  required int columns,
  required double rotation,
  required double tilt,
  required double scale,
  required Offset centre,
}) {
  final x = column - (columns - 1) / 2;
  final y = (rows - 1) / 2 - row;
  final rotatedX = x * math.cos(rotation) - y * math.sin(rotation);
  final rotatedY = x * math.sin(rotation) + y * math.cos(rotation);
  return centre +
      Offset(
        rotatedX * scale,
        rotatedY * scale * tilt - heightFraction * scale * 2.0,
      );
}

/// Depth of a point for the painter's-algorithm sort.
@visibleForTesting
double surfaceDepthFor({
  required double row,
  required double column,
  required int rows,
  required int columns,
  required double rotation,
}) {
  final x = column - (columns - 1) / 2;
  final y = (rows - 1) / 2 - row;
  return x * math.sin(rotation) + y * math.cos(rotation);
}

/// Whether the quad spanning ([quadRow], [quadColumn]) to (+1, +1) holds the
/// given cell.
///
/// Exactly one quad matches any cell. An earlier version tested the cell
/// against both ends of the quad's range inclusively, so an interior cell lit
/// a 2x2 block of quads instead of the one it was in. Edge cells belong to the
/// last quad, since there is none beyond them.
@visibleForTesting
bool surfaceQuadHoldsCell({
  required int quadRow,
  required int quadColumn,
  required int cellRow,
  required int cellColumn,
  required int rows,
  required int columns,
}) =>
    math.min(cellRow, rows - 2) == quadRow &&
    math.min(cellColumn, columns - 2) == quadColumn;

/// Bilinearly interpolates the surface value at a fractional position, so a
/// marker sits on the surface rather than snapping to the nearest corner.
@visibleForTesting
double? surfaceValueAt(List<List<double?>> grid, double row, double column) {
  if (grid.isEmpty || grid.first.isEmpty) return null;
  final rows = grid.length;
  final columns = grid.first.length;

  final r0 = row.floor().clamp(0, rows - 1);
  final c0 = column.floor().clamp(0, columns - 1);
  final r1 = math.min(r0 + 1, rows - 1);
  final c1 = math.min(c0 + 1, columns - 1);

  final v00 = grid[r0][c0];
  final v01 = grid[r0][c1];
  final v10 = grid[r1][c0];
  final v11 = grid[r1][c1];
  if (v00 == null || v01 == null || v10 == null || v11 == null) return null;

  final fr = (row - r0).clamp(0.0, 1.0);
  final fc = (column - c0).clamp(0.0, 1.0);
  final lower = v00 + (v01 - v00) * fc;
  final upper = v10 + (v11 - v10) * fc;
  return lower + (upper - lower) * fr;
}

/// An isometric surface plot of a table.
///
/// Drawn with a plain [CustomPainter] and a painter's-algorithm depth sort
/// rather than a GL dependency: the mesh is at most 16x16, so the cost is
/// trivial and it keeps the build identical on every platform.
class SurfaceView extends StatefulWidget {
  const SurfaceView({
    super.key,
    required this.view,
    this.cursor,
    this.preciseCursor,
    this.height = 320,
  });

  final TableView view;

  /// The cell the engine is operating in, highlighted on the mesh.
  final ({int row, int column})? cursor;

  /// The engine's exact position, drawn as a marker on the surface.
  final ({double row, double column})? preciseCursor;

  final double height;

  @override
  State<SurfaceView> createState() => _SurfaceViewState();
}

class _SurfaceViewState extends State<SurfaceView> {
  double _rotation = -0.6;
  double _tilt = 0.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SizedBox(
      height: widget.height,
      child: GestureDetector(
        // Drag to orbit: the only way to read a surface is from several angles.
        onPanUpdate: (details) => setState(() {
          _rotation += details.delta.dx * 0.01;
          _tilt = (_tilt + details.delta.dy * 0.005).clamp(0.05, 1.4);
        }),
        child: CustomPaint(
          painter: _SurfacePainter(
            grid: widget.view.toGrid(),
            rotation: _rotation,
            tilt: _tilt,
            cursor: widget.cursor,
            precise: widget.preciseCursor,
            lowColor: scheme.surfaceContainerHighest,
            highColor: scheme.primary,
            edgeColor: scheme.outlineVariant,
            cursorColor: scheme.tertiary,
            markerHalo: scheme.surface,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _SurfacePainter extends CustomPainter {
  _SurfacePainter({
    required this.grid,
    required this.rotation,
    required this.tilt,
    required this.cursor,
    required this.precise,
    required this.lowColor,
    required this.highColor,
    required this.edgeColor,
    required this.cursorColor,
    required this.markerHalo,
  });

  final List<List<double?>> grid;
  final double rotation;
  final double tilt;
  final ({int row, int column})? cursor;
  final ({double row, double column})? precise;
  final Color lowColor;
  final Color highColor;
  final Color edgeColor;
  final Color cursorColor;
  final Color markerHalo;

  @override
  void paint(Canvas canvas, Size size) {
    if (grid.isEmpty || grid.first.isEmpty) return;

    final rows = grid.length;
    final columns = grid.first.length;

    var lo = double.infinity;
    var hi = double.negativeInfinity;
    for (final row in grid) {
      for (final value in row) {
        if (value == null) continue;
        if (value < lo) lo = value;
        if (value > hi) hi = value;
      }
    }
    if (!lo.isFinite || !hi.isFinite) return;
    final span = hi - lo == 0 ? 1.0 : hi - lo;

    final scale = math.min(size.width / (columns + rows), size.height / 3.2);
    final centre = Offset(size.width / 2, size.height * 0.62);

    Offset project(double row, double column, double value) => surfacePointFor(
      row: row,
      column: column,
      heightFraction: (value - lo) / span,
      rows: rows,
      columns: columns,
      rotation: rotation,
      tilt: tilt,
      scale: scale,
      centre: centre,
    );

    double depthOf(double row, double column) => surfaceDepthFor(
      row: row,
      column: column,
      rows: rows,
      columns: columns,
      rotation: rotation,
    );

    // Painter's algorithm: draw far quads first so near ones overlap them.
    final quads = <({double depth, Path path, double height, bool isCursor})>[];
    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < columns - 1; c++) {
        final corners = [(r, c), (r, c + 1), (r + 1, c + 1), (r + 1, c)];
        final values = [for (final (cr, cc) in corners) grid[cr][cc]];
        if (values.any((v) => v == null)) continue;

        final points = [
          for (var i = 0; i < corners.length; i++)
            project(
              corners[i].$1.toDouble(),
              corners[i].$2.toDouble(),
              values[i]!,
            ),
        ];
        final mean = values.reduce((a, b) => a! + b!)! / values.length;

        quads.add((
          depth: depthOf(r + 0.5, c + 0.5),
          path: Path()..addPolygon(points, true),
          height: (mean - lo) / span,
          // Exactly one quad, the one containing the cell. The previous test
          // was inclusive at both ends, so a cursor on an interior cell lit a
          // 2x2 block of quads rather than the cell it was in.
          isCursor:
              cursor != null &&
              surfaceQuadHoldsCell(
                quadRow: r,
                quadColumn: c,
                cellRow: cursor!.row,
                cellColumn: cursor!.column,
                rows: rows,
                columns: columns,
              ),
        ));
      }
    }

    quads.sort((a, b) => a.depth.compareTo(b.depth));

    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = edgeColor;

    for (final quad in quads) {
      // Magnitude is sequential: one hue, light to dark.
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = Color.lerp(
          lowColor,
          highColor,
          quad.height,
        )!.withValues(alpha: 0.92);
      canvas
        ..drawPath(quad.path, fill)
        ..drawPath(quad.path, edge);

      if (quad.isCursor) {
        canvas.drawPath(
          quad.path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..color = cursorColor,
        );
      }
    }

    _paintMarker(canvas, rows, columns, lo, span, project);
  }

  /// Draws the engine's exact position on the surface.
  void _paintMarker(
    Canvas canvas,
    int rows,
    int columns,
    double lo,
    double span,
    Offset Function(double, double, double) project,
  ) {
    final point = precise;
    if (point == null) return;

    final value = surfaceValueAt(grid, point.row, point.column);
    if (value == null) return;

    final top = project(point.row, point.column, value);
    // A stem down to the table's floor: on a surface, a floating dot gives no
    // sense of where it sits, so anchor it.
    final base = project(point.row, point.column, lo);

    canvas
      ..drawLine(
        base,
        top,
        Paint()
          ..strokeWidth = 3
          ..color = markerHalo.withValues(alpha: 0.85),
      )
      ..drawLine(
        base,
        top,
        Paint()
          ..strokeWidth = 1.4
          ..color = cursorColor.withValues(alpha: 0.85),
      )
      ..drawCircle(top, 6.5, Paint()..color = markerHalo.withValues(alpha: 0.9))
      ..drawCircle(top, 5, Paint()..color = cursorColor)
      ..drawCircle(
        top,
        5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = markerHalo,
      );
  }

  @override
  bool shouldRepaint(_SurfacePainter old) =>
      old.rotation != rotation ||
      old.tilt != tilt ||
      old.cursor != cursor ||
      old.precise != precise ||
      !identical(old.grid, grid);
}
