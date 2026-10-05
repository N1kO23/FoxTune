import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show RealtimeSnapshot;
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/dashboard_controller.dart';

/// Where the engine is on a table, as far as a [TableGrid]'s cells need to
/// know: the cell it is in, and the lower corner of the four the ECU
/// interpolates between.
typedef LivePlace = ({
  ({int row, int column})? cell,
  ({int row, int column})? corner,
});

/// Follows the engine across a table for a screen showing it as a grid.
///
/// The grid's cells are rebuilt only when [followLive]'s place changes - as
/// the engine crosses from one cell to the next - however fast readings come.
/// Exactly where it is, which moves with every reading, goes to [precise]
/// instead, for the grid's marker to follow on its own.
mixin LivePosition<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The engine's exact place on the table: hand to `TableGrid.preciseCursor`.
  final precise = ValueNotifier<({double row, double column})?>(null);

  @override
  void dispose() {
    precise.dispose();
    super.dispose();
  }

  /// The live values on [view]'s axes, either `null` when unavailable.
  static (double?, double?) axesOf(TableView view, RealtimeSnapshot? live) {
    double? channel(String? name) => name == null ? null : live?[name];
    return (
      channel(view.table.xBins.channel),
      channel(view.table.yBins.channel),
    );
  }

  /// Where the engine is on [view]: called from build. Keeps [precise] up to
  /// date while this screen is shown.
  LivePlace? followLive(TableView view) {
    ({double row, double column})? preciseOf(RealtimeSnapshot? live) {
      final (x, y) = axesOf(view, live);
      return x == null || y == null ? null : view.preciseCellFor(x, y);
    }

    if (Visibility.of(context) && TickerMode.valuesOf(context).enabled) {
      ref.listen(liveProvider, (_, live) => precise.value = preciseOf(live));
    }
    precise.value = preciseOf(ref.read(liveProvider));

    return watchWhileVisible(
      ref,
      context,
      liveProvider.select((live) {
        final (x, y) = axesOf(view, live);
        if (x == null || y == null) return null;
        final at = view.preciseCellFor(x, y);
        return (
          cell: view.cellFor(x, y),
          corner: at == null
              ? null
              : (row: at.row.floor(), column: at.column.floor()),
        );
      }),
    );
  }

  /// The cells the ECU is interpolating between at [place].
  static Set<({int row, int column})> contributingAt(
    TableView view,
    LivePlace? place,
  ) {
    final corner = place?.corner;
    if (corner == null) return const {};
    return view
        .contributingCells(corner.row.toDouble(), corner.column.toDouble())
        .toSet();
  }
}
