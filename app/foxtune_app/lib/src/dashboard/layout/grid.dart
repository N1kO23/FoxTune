import 'dart:math' as math;

import 'dashboard_layout.dart';

/// A rectangle of grid cells.
class GridRect {
  const GridRect(this.x, this.y, this.width, this.height);

  GridRect.of(GaugePlacement p) : this(p.x, p.y, p.width, p.height);

  final int x;
  final int y;
  final int width;
  final int height;

  int get right => x + width;
  int get bottom => y + height;

  bool overlaps(GridRect other) =>
      x < other.right &&
      other.x < right &&
      y < other.bottom &&
      other.y < bottom;

  @override
  bool operator ==(Object other) =>
      other is GridRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'GridRect($x, $y, ${width}x$height)';
}

/// Keeps [rect] on [page]'s grid and no smaller than [style] allows there.
///
/// Anything dragged past the right edge comes back to it; anything dragged
/// above the top comes down to row 0. There is no limit downwards - a page
/// scrolls.
GridRect clampToGrid(GridRect rect, GaugeStyle style, DashboardPage page) {
  final columns = page.columns;
  final minimum = style.minimumIn(page.density);
  final width = rect.width
      .clamp(math.min(minimum.width, columns), columns)
      .toInt();
  final height = math.max(rect.height, minimum.height);
  final x = rect.x.clamp(0, columns - width).toInt();
  final y = rect.y < 0 ? 0 : rect.y;
  return GridRect(x, y, width, height);
}

/// Whether [rect] is clear of every gauge on [page] but [ignoring].
bool isFree(DashboardPage page, GridRect rect, {String? ignoring}) {
  for (final item in page.items) {
    if (item.id == ignoring) continue;
    if (GridRect.of(item).overlaps(rect)) return false;
  }
  return true;
}

/// The first clear spot for a [width] x [height] gauge, reading left to right
/// and top to bottom.
///
/// Always finds one: below the last gauge there is nothing in the way.
GridRect firstFreeSpot(DashboardPage page, int width, int height) {
  final w = width.clamp(1, page.columns);
  for (var y = 0; ; y++) {
    for (var x = 0; x + w <= page.columns; x++) {
      final candidate = GridRect(x, y, w, height);
      if (isFree(page, candidate)) return candidate;
    }
  }
}

/// [placement] moved or resized to [target], if that lands somewhere legal.
///
/// Returns `null` when the target overlaps another gauge, which is the cue for
/// the drag to spring back rather than shove its neighbours about.
GaugePlacement? tryPlace(
  DashboardPage page,
  GaugePlacement placement,
  GridRect target,
) {
  final rect = clampToGrid(target, placement.style, page);
  if (!isFree(page, rect, ignoring: placement.id)) return null;
  return placement.copyWith(
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
  );
}

/// [page] moved onto a grid [density] squares across a phone's width, looking
/// as it did.
///
/// Every edge is scaled and rounded on its own, rather than position and size
/// separately, so two gauges that touched still touch and never overlap. Only
/// growing a gauge to its style's minimum on a coarser grid can make it bump
/// into a neighbour; that one moves to the first spot that takes it rather
/// than covering anything.
DashboardPage regridPage(DashboardPage page, int density) {
  if (density == page.density) return page;
  final factor = density / page.density;
  int scaled(int edge) => (edge * factor).round();

  return _settle(page, page.copyWith(density: density), (item) {
    final x = scaled(item.x);
    final y = scaled(item.y);
    return GridRect(
      x,
      y,
      scaled(item.x + item.width) - x,
      scaled(item.y + item.height) - y,
    );
  });
}

/// [page] laid out [width] wide, every gauge where it was.
///
/// The squares stay the same size, so widening only adds room on the right.
/// Narrowing leaves anything that still fits alone and pulls what now hangs
/// off the edge back onto the page - against the edge if that is clear, and
/// otherwise into the first space that takes it.
DashboardPage widenPage(DashboardPage page, PageWidth width) {
  if (width == page.width) return page;
  return _settle(page, page.copyWith(width: width), GridRect.of);
}

/// Places [page]'s gauges on [target], each where [wanted] asks if that is
/// clear, and otherwise at the first spot that takes it.
DashboardPage _settle(
  DashboardPage page,
  DashboardPage target,
  GridRect Function(GaugePlacement) wanted,
) {
  // Reading order, so a gauge that has to move gives way to the ones above
  // and to the left of it rather than the other way round.
  final ordered = [...page.items]
    ..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));

  var placed = target.copyWith(items: const []);
  for (final item in ordered) {
    final asked = wanted(item);
    var rect = clampToGrid(asked, item.style, target);
    // Clamping pulls a gauge that hangs off the edge back onto the page, but
    // into whatever is there: only take it if it is clear.
    if (!isFree(placed, rect)) {
      rect = firstFreeSpot(placed, rect.width, rect.height);
    }
    placed = placed.copyWith(
      items: [
        ...placed.items,
        item.copyWith(
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height,
        ),
      ],
    );
  }

  // Back in the order they were saved in, which is the order they are drawn.
  final byId = {for (final item in placed.items) item.id: item};
  return placed.copyWith(items: [for (final i in page.items) byId[i.id]!]);
}
