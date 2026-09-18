import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/tune/surface_view.dart';

const _centre = Offset(200, 200);

Offset point(
  double row,
  double column, {
  double height = 0,
  double rotation = 0,
}) => surfacePointFor(
  row: row,
  column: column,
  heightFraction: height,
  rows: 4,
  columns: 4,
  rotation: rotation,
  tilt: 0.5,
  scale: 40,
  centre: _centre,
);

void main() {
  group('orientation', () {
    test('row 0 renders in front of the last row', () {
      // The 2D grid puts the lowest load at the bottom. The surface must agree,
      // or the two views of the same table disagree about which way is up.
      // Screen y grows downward, so "in front" means a larger y.
      expect(point(0, 0).dy, greaterThan(point(3, 0).dy));
    });

    test('column 0 renders left of the last column', () {
      expect(point(0, 0).dx, lessThan(point(0, 3).dx));
    });

    test('height raises a point on screen', () {
      expect(point(1, 1, height: 1).dy, lessThan(point(1, 1, height: 0).dy));
    });

    test('the mesh centre sits at the view centre', () {
      // With a 4x4 mesh the midpoint is (1.5, 1.5).
      final middle = point(1.5, 1.5);
      expect(middle.dx, closeTo(_centre.dx, 1e-9));
      expect(middle.dy, closeTo(_centre.dy, 1e-9));
    });

    test('rotation keeps the front row in front at the default angle', () {
      // The view opens rotated; the orientation must hold there too.
      expect(
        point(0, 0, rotation: -0.6).dy,
        greaterThan(point(3, 0, rotation: -0.6).dy),
      );
    });

    test('depth orders the front row nearer than the back', () {
      double depth(double row) => surfaceDepthFor(
        row: row,
        column: 0,
        rows: 4,
        columns: 4,
        rotation: 0,
      );
      // Painter's algorithm draws ascending depth, so the front must sort last.
      expect(depth(0), greaterThan(depth(3)));
    });
  });

  group('cursor quad', () {
    bool holds(int quadRow, int quadColumn, int cellRow, int cellColumn) =>
        surfaceQuadHoldsCell(
          quadRow: quadRow,
          quadColumn: quadColumn,
          cellRow: cellRow,
          cellColumn: cellColumn,
          rows: 4,
          columns: 4,
        );

    test('exactly one quad holds any given cell', () {
      for (final (cellRow, cellColumn) in const [
        (0, 0),
        (1, 2),
        (2, 1),
        (3, 3),
      ]) {
        var matches = 0;
        for (var r = 0; r < 3; r++) {
          for (var c = 0; c < 3; c++) {
            if (holds(r, c, cellRow, cellColumn)) matches++;
          }
        }
        // The regression: an inclusive range on both ends lit a 2x2 block.
        expect(matches, 1, reason: 'cell ($cellRow, $cellColumn)');
      }
    });

    test('an interior cell picks its own quad', () {
      expect(holds(1, 2, 1, 2), isTrue);
      expect(holds(0, 1, 1, 2), isFalse);
      expect(holds(1, 1, 1, 2), isFalse);
    });

    test('edge cells fall back to the last quad', () {
      // There is no quad beyond the final row or column.
      expect(holds(2, 2, 3, 3), isTrue);
    });
  });

  group('marker depth', () {
    double quadDepth(double row, double column, double rotation) =>
        surfaceDepthFor(
          row: row,
          column: column,
          rows: 4,
          columns: 4,
          rotation: rotation,
        );

    double markerDepth(double row, double column, double rotation) =>
        surfaceMarkerDepth(
          row: row,
          column: column,
          rows: 4,
          columns: 4,
          rotation: rotation,
        );

    test('draws just after the quad it sits on', () {
      // Sorting the marker by its own depth would bury it under its own quad
      // whenever it fell in that quad's back half.
      for (final (row, column) in const [(1.1, 1.1), (1.5, 1.5), (1.9, 1.9)]) {
        expect(
          markerDepth(row, column, 0),
          greaterThan(quadDepth(1.5, 1.5, 0)),
          reason: 'marker at ($row, $column)',
        );
      }
    });

    test('is hidden by a quad nearer the viewer', () {
      // Row 0 is the front, so a quad in front of the marker must sort later
      // and paint over it.
      final marker = markerDepth(2.5, 1.5, 0);
      expect(quadDepth(0.5, 1.5, 0), greaterThan(marker));
    });

    test('paints over a quad further away', () {
      final marker = markerDepth(0.5, 1.5, 0);
      expect(quadDepth(2.5, 1.5, 0), lessThan(marker));
    });

    test('holds through a full rotation', () {
      // Orbiting is exactly when incorrect sorting shows, so the ordering has
      // to survive every viewing angle, not just the default one.
      for (var i = 0; i < 16; i++) {
        final rotation = i * math.pi / 8;
        final marker = markerDepth(1.5, 1.5, rotation);
        expect(
          marker,
          greaterThan(quadDepth(1.5, 1.5, rotation)),
          reason: 'own quad at rotation $rotation',
        );

        // Whichever neighbour is nearer must still occlude it.
        for (final (row, column) in const [
          (0.5, 1.5),
          (2.5, 1.5),
          (1.5, 0.5),
          (1.5, 2.5),
        ]) {
          final neighbour = quadDepth(row, column, rotation);
          if (neighbour > quadDepth(1.5, 1.5, rotation) + 0.01) {
            expect(
              neighbour,
              greaterThan(marker),
              reason: 'nearer neighbour ($row, $column) at $rotation',
            );
          }
        }
      }
    });

    test('clamps at the far edges where no quad follows', () {
      expect(() => markerDepth(3, 3, 0), returnsNormally);
      expect(markerDepth(3, 3, 0), greaterThan(quadDepth(2.5, 2.5, 0)));
    });
  });

  group('surface value', () {
    final grid = <List<double?>>[
      [0, 10],
      [20, 30],
    ];

    test('returns the corner values exactly', () {
      expect(surfaceValueAt(grid, 0, 0), 0);
      expect(surfaceValueAt(grid, 0, 1), 10);
      expect(surfaceValueAt(grid, 1, 0), 20);
      expect(surfaceValueAt(grid, 1, 1), 30);
    });

    test('interpolates between corners', () {
      expect(surfaceValueAt(grid, 0, 0.5), 5);
      expect(surfaceValueAt(grid, 0.5, 0), 10);
      // Centre of the quad: the mean of all four corners.
      expect(surfaceValueAt(grid, 0.5, 0.5), 15);
    });

    test('clamps outside the mesh', () {
      expect(surfaceValueAt(grid, -1, -1), 0);
      expect(surfaceValueAt(grid, 9, 9), 30);
    });

    test('yields null when a corner is unavailable', () {
      // A marker must not be placed on a surface that is not there.
      expect(
        surfaceValueAt(
          <List<double?>>[
            [0, null],
            [20, 30],
          ],
          0.5,
          0.5,
        ),
        isNull,
      );
    });

    test('handles an empty grid', () {
      expect(surfaceValueAt(const <List<double?>>[], 0, 0), isNull);
    });
  });
}
