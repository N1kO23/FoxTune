import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

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
    this.height = 320,
  });

  final TableView view;

  /// Where the engine is operating, highlighted on the mesh.
  final ({int row, int column})? cursor;

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
            lowColor: scheme.surfaceContainerHighest,
            highColor: scheme.primary,
            edgeColor: scheme.outlineVariant,
            cursorColor: scheme.tertiary,
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
    required this.lowColor,
    required this.highColor,
    required this.edgeColor,
    required this.cursorColor,
  });

  final List<List<double?>> grid;
  final double rotation;
  final double tilt;
  final ({int row, int column})? cursor;
  final Color lowColor;
  final Color highColor;
  final Color edgeColor;
  final Color cursorColor;

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

    Offset project(int row, int column, double value) {
      final x = (column - (columns - 1) / 2).toDouble();
      final y = (row - (rows - 1) / 2).toDouble();
      final rotatedX = x * math.cos(rotation) - y * math.sin(rotation);
      final rotatedY = x * math.sin(rotation) + y * math.cos(rotation);
      final height = (value - lo) / span;
      return centre +
          Offset(
            rotatedX * scale,
            rotatedY * scale * tilt - height * scale * 2.0,
          );
    }

    // Painter's algorithm: draw far quads first so near ones overlap them.
    final quads = <({double depth, Path path, double height, bool isCursor})>[];
    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < columns - 1; c++) {
        final corners = [(r, c), (r, c + 1), (r + 1, c + 1), (r + 1, c)];
        final values = [for (final (cr, cc) in corners) grid[cr][cc]];
        if (values.any((v) => v == null)) continue;

        final points = [
          for (var i = 0; i < corners.length; i++)
            project(corners[i].$1, corners[i].$2, values[i]!),
        ];
        final path = Path()..addPolygon(points, true);

        // Depth from the rotated position of the quad's centre.
        final x = (c + 0.5 - (columns - 1) / 2).toDouble();
        final y = (r + 0.5 - (rows - 1) / 2).toDouble();
        final depth = x * math.sin(rotation) + y * math.cos(rotation);

        final mean = values.reduce((a, b) => a! + b!)! / values.length;
        quads.add((
          depth: depth,
          path: path,
          height: (mean - lo) / span,
          isCursor:
              cursor != null &&
              cursor!.row >= r &&
              cursor!.row <= r + 1 &&
              cursor!.column >= c &&
              cursor!.column <= c + 1,
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
  }

  @override
  bool shouldRepaint(_SurfacePainter old) =>
      old.rotation != rotation ||
      old.tilt != tilt ||
      old.cursor != cursor ||
      !identical(old.grid, grid);
}
