import 'dashboard_layout.dart';

/// Columns across every page.
///
/// Fixed, and the same on every screen: a page is a 12-column grid scaled to
/// fit, so a layout arranged on a laptop keeps its shape on a phone rather
/// than reflowing into something else.
const gridColumns = 12;

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

/// Keeps [rect] on the grid and no smaller than [style] allows.
///
/// Anything dragged past the right edge comes back to it; anything dragged
/// above the top comes down to row 0. There is no limit downwards - a page
/// scrolls.
GridRect clampToGrid(GridRect rect, GaugeStyle style) {
  final width = rect.width.clamp(style.minWidth, gridColumns);
  final height = rect.height < style.minHeight ? style.minHeight : rect.height;
  final x = rect.x.clamp(0, gridColumns - width);
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
  final w = width.clamp(1, gridColumns);
  for (var y = 0; ; y++) {
    for (var x = 0; x + w <= gridColumns; x++) {
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
  final rect = clampToGrid(target, placement.style);
  if (!isFree(page, rect, ignoring: placement.id)) return null;
  return placement.copyWith(
    x: rect.x,
    y: rect.y,
    width: rect.width,
    height: rect.height,
  );
}
