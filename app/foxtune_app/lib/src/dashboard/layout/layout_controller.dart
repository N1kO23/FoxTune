import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import '../../connection/connection_controller.dart';
import '../../connection/connection_state.dart';
import '../../storage/json_store.dart';
import 'dashboard_layout.dart';
import 'default_layout.dart';
import 'grid.dart';

/// The dashboard's pages, for the connected ECU.
final dashboardLayoutProvider =
    AsyncNotifierProvider<DashboardLayoutController, DashboardLayout>(
      DashboardLayoutController.new,
    );

/// Loads, edits and saves the dashboard layout.
///
/// One layout per ECU family, so a firmware update keeps it. Every edit is
/// saved as it is made: there is no "save layout" step to forget.
class DashboardLayoutController extends AsyncNotifier<DashboardLayout> {
  IniDocument? _definition;

  @override
  Future<DashboardLayout> build() async {
    final connection = ref.watch(connectionProvider);
    final definition = connection is EcuConnected
        ? connection.definition
        : null;
    _definition = definition;
    if (definition == null) return const DashboardLayout(pages: []);

    final saved = DashboardLayout.fromJson(
      await ref.read(jsonStoreProvider).read(_path(definition)),
    );
    return saved ?? defaultLayout(definition);
  }

  static String _path(IniDocument definition) =>
      'dashboards/${ecuFamily(definition.identity.signature)}.json';

  DashboardLayout get _layout =>
      state.valueOrNull ?? const DashboardLayout(pages: []);

  void _commit(DashboardLayout layout) {
    state = AsyncValue.data(layout);
    final definition = _definition;
    if (definition != null) {
      unawaited(
        ref.read(jsonStoreProvider).write(_path(definition), layout.toJson()),
      );
    }
  }

  void _updatePage(String pageId, DashboardPage Function(DashboardPage) edit) {
    _commit(
      _layout.copyWith(
        pages: [
          for (final page in _layout.pages)
            if (page.id == pageId) edit(page) else page,
        ],
      ),
    );
  }

  // --- Pages ---------------------------------------------------------------

  /// Adds an empty page at the end, and returns its id.
  ///
  /// It takes the width and grid of [like], where given: a page added on a
  /// laptop, from a laptop-wide page, is wanted laptop-wide.
  String addPage(String name, {String? like}) {
    final model = like == null ? null : _layout.pageById(like);
    final page = DashboardPage(
      id: newLayoutId(),
      name: name,
      density: model?.density ?? defaultGridDensity,
      width: model?.width ?? PageWidth.phone,
    );
    _commit(_layout.copyWith(pages: [..._layout.pages, page]));
    return page.id;
  }

  void renamePage(String pageId, String name) =>
      _updatePage(pageId, (page) => page.copyWith(name: name));

  /// Removes a page. The last one cannot go: a dashboard with no pages has
  /// nowhere to put a gauge.
  void deletePage(String pageId) {
    if (_layout.pages.length <= 1) return;
    _commit(
      _layout.copyWith(
        pages: [
          for (final page in _layout.pages)
            if (page.id != pageId) page,
        ],
      ),
    );
  }

  /// Moves a page [delta] places along the tabs.
  void movePage(String pageId, int delta) {
    final pages = [..._layout.pages];
    final from = pages.indexWhere((p) => p.id == pageId);
    if (from < 0) return;
    final to = (from + delta).clamp(0, pages.length - 1);
    if (to == from) return;
    pages.insert(to, pages.removeAt(from));
    _commit(_layout.copyWith(pages: pages));
  }

  /// Puts a page back to the definition's default content, keeping its name,
  /// width and grid.
  void resetPage(String pageId) {
    final definition = _definition;
    if (definition == null) return;
    _updatePage(pageId, (page) {
      final fresh = defaultPage(
        definition,
        density: page.density,
        width: page.width,
      );
      return page.copyWith(items: fresh.items);
    });
  }

  /// Moves a page onto a grid [density] squares across a phone's width,
  /// keeping its look.
  void setDensity(String pageId, int density) {
    if (!gridDensityChoices.contains(density)) return;
    _updatePage(pageId, (page) => regridPage(page, density));
  }

  /// Lays a page out [width] wide, keeping every gauge's size.
  void setWidth(String pageId, PageWidth width) =>
      _updatePage(pageId, (page) => widenPage(page, width));

  // --- Limits --------------------------------------------------------------

  /// Sets the limits for the gauge [ref] names, or with `null` hands them back
  /// to the definition.
  void setLimits(String ref, GaugeLimits? limits) {
    if (limits != null && limits.problem != null) return;
    _commit(
      _layout.copyWith(
        limits: {
          for (final entry in _layout.limits.entries)
            if (entry.key != ref) entry.key: entry.value,
          ref: ?limits,
        },
      ),
    );
  }

  // --- Gauges --------------------------------------------------------------

  /// Adds a gauge at the first free spot, and returns it.
  GaugePlacement addGauge(
    String pageId, {
    required GaugeStyle style,
    List<String> gauges = const [],
    String? indicator,
  }) {
    final page = _layout.pageById(pageId);
    final size = style.sizeIn(page?.density ?? defaultGridDensity);
    final spot = page == null
        ? GridRect(0, 0, size.width, size.height)
        : firstFreeSpot(page, size.width, size.height);
    final placement = GaugePlacement(
      id: newLayoutId(),
      style: style,
      x: spot.x,
      y: spot.y,
      width: spot.width,
      height: spot.height,
      gauges: gauges,
      indicator: indicator,
    );
    _updatePage(pageId, (p) => p.copyWith(items: [...p.items, placement]));
    return placement;
  }

  /// Moves or resizes a gauge. Returns whether it fitted; if not, nothing
  /// changes and the gauge springs back.
  bool place(String pageId, String placementId, GridRect target) {
    final page = _layout.pageById(pageId);
    final placement = page?.items.where((i) => i.id == placementId).firstOrNull;
    if (page == null || placement == null) return false;

    final moved = tryPlace(page, placement, target);
    if (moved == null) return false;
    replaceGauge(pageId, moved);
    return true;
  }

  /// Swaps a gauge for an edited copy of itself.
  ///
  /// A style change can make it too small for its new style, so it is grown
  /// to fit where there is room, and otherwise moved to the first spot that
  /// takes it.
  void replaceGauge(String pageId, GaugePlacement updated) {
    final page = _layout.pageById(pageId);
    if (page == null) return;

    var next = updated;
    final grown = clampToGrid(GridRect.of(updated), updated.style, page);
    if (grown != GridRect.of(updated)) {
      final spot = isFree(page, grown, ignoring: updated.id)
          ? grown
          : firstFreeSpot(
              page.copyWith(
                items: page.items.where((i) => i.id != updated.id).toList(),
              ),
              grown.width,
              grown.height,
            );
      next = updated.copyWith(
        x: spot.x,
        y: spot.y,
        width: spot.width,
        height: spot.height,
      );
    }

    _updatePage(
      pageId,
      (p) => p.copyWith(
        items: [
          for (final item in p.items)
            if (item.id == next.id) next else item,
        ],
      ),
    );
  }

  void removeGauge(String pageId, String placementId) => _updatePage(
    pageId,
    (p) =>
        p.copyWith(items: p.items.where((i) => i.id != placementId).toList()),
  );
}
