import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import 'cursor_readout.dart';
import 'surface_view.dart';
import 'table_editor_screen.dart';
import 'tune_controller.dart';

/// One table as a surface and nothing else.
///
/// The definition keeps two menus over the same data: the tuning menus point
/// at a table's grid, and "3D Tuning Maps" points at its `mapId`. That is a
/// real distinction rather than a duplicate - reading the shape of a map is a
/// different job from editing a cell, and it wants the whole window rather
/// than a strip above a grid.
///
/// Nothing is editable here. There is no sane way to drag a value on an
/// isometric mesh, and a surface that silently accepted an edit would be worse
/// than one that sends you to the grid for it.
class SurfaceScreen extends ConsumerWidget {
  const SurfaceScreen({
    super.key,
    required this.connection,
    required this.tableId,
  });

  final EcuConnected connection;

  /// Identifier of the table to show - its `[TableEditor]` id, not its map id.
  final String tableId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tune = ref.watch(tuneProvider).valueOrNull;
    final definition = connection.definition;
    final table = definition?.tableNamed(tableId);

    if (tune == null || table == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('That table is not available.'),
        ),
      );
    }

    final view = TableView.of(
      tune,
      table,
      resolver: ref.watch(tuneResolverProvider),
    );
    if (view == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('"${table.title}" could not be resolved.'),
        ),
      );
    }

    final live = ref.watch(realtimeProvider).valueOrNull;
    double? channel(String? name) => name == null ? null : live?[name];

    final x = channel(table.xBins.channel);
    final y = channel(table.yBins.channel);
    final cursor = x == null || y == null ? null : view.cellFor(x, y);
    final precise = x == null || y == null ? null : view.preciseCellFor(x, y);

    return Column(
      children: [
        CursorReadout(view: view, cursor: cursor, x: x, y: y),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SurfaceView(
                view: view,
                cursor: cursor,
                preciseCursor: precise,
                // The surface is the whole point of this screen, so it takes
                // the room rather than the fixed strip it gets beside a grid.
                height: constraints.maxHeight - 24,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () {
                  ref.read(selectedTableProvider.notifier).state = tableId;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        appBar: AppBar(title: Text(table.title)),
                        body: TableEditorScreen(connection: connection),
                      ),
                    ),
                  );
                },
                icon: const Icon(Icons.grid_on),
                label: const Text('Edit in grid'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
