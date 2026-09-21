import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import 'dashboard_editor.dart';
import 'gauge_catalog.dart';
import 'gauge_view.dart';
import 'layout/dashboard_layout.dart';
import 'layout/grid.dart';
import 'layout/layout_controller.dart';
import 'sample_history.dart';

/// Largest a grid cell is drawn, in logical pixels.
///
/// The grid scales with the window, but not without limit: past this a wide
/// monitor would blow the gauges up to poster size. The page centres instead.
const maxCellSize = 60.0;

/// One dashboard page: its gauges on a 12-column grid scaled to fit.
class DashboardPageView extends StatelessWidget {
  const DashboardPageView({
    super.key,
    required this.page,
    required this.editing,
    required this.definition,
    required this.catalog,
    required this.history,
  });

  final DashboardPage page;
  final bool editing;
  final IniDocument definition;
  final GaugeCatalog catalog;
  final SampleHistory history;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = math.min(constraints.maxWidth / gridColumns, maxCellSize);
        // While editing, leave room below the last gauge to drag one into.
        final contentRows = page.rows + (editing ? 3 : 0);
        final visibleRows = constraints.hasBoundedHeight
            ? (constraints.maxHeight / cell).floor()
            : 0;
        final rows = math.max(contentRows, visibleRows);

        return SingleChildScrollView(
          child: Center(
            child: SizedBox(
              width: cell * gridColumns,
              height: rows * cell,
              child: Stack(
                children: [
                  if (editing)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _GridPainter(
                          cell: cell,
                          color: Theme.of(context).colorScheme.outlineVariant
                              .withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  for (final item in page.items)
                    if (editing)
                      _EditableGauge(
                        key: ValueKey(item.id),
                        page: page,
                        placement: item,
                        cell: cell,
                        definition: definition,
                        child: _view(item),
                      )
                    else
                      Positioned(
                        left: item.x * cell,
                        top: item.y * cell,
                        width: item.width * cell,
                        height: item.height * cell,
                        child: _view(item),
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _view(GaugePlacement item) => GaugeView(
    placement: item,
    definition: definition,
    catalog: catalog,
    history: history,
  );
}

enum _Drag { move, resize }

/// A gauge that can be dragged, resized from its corner, or tapped for its
/// options.
///
/// While a drag is under way the gauge follows the finger cell by cell, and an
/// outline shows where it would land - in the accent colour if there is room,
/// in the danger colour if another gauge is in the way. Let go on a clash and
/// it springs back rather than shoving its neighbours around.
class _EditableGauge extends ConsumerStatefulWidget {
  const _EditableGauge({
    super.key,
    required this.page,
    required this.placement,
    required this.cell,
    required this.definition,
    required this.child,
  });

  final DashboardPage page;
  final GaugePlacement placement;
  final double cell;
  final IniDocument definition;
  final Widget child;

  @override
  ConsumerState<_EditableGauge> createState() => _EditableGaugeState();
}

class _EditableGaugeState extends ConsumerState<_EditableGauge> {
  _Drag? _drag;
  Offset _delta = Offset.zero;

  GridRect get _original => GridRect.of(widget.placement);

  /// Where the gauge would land if let go now.
  GridRect get _target {
    final drag = _drag;
    if (drag == null) return _original;
    final dx = (_delta.dx / widget.cell).round();
    final dy = (_delta.dy / widget.cell).round();
    final r = _original;
    final moved = drag == _Drag.move
        ? GridRect(r.x + dx, r.y + dy, r.width, r.height)
        : GridRect(r.x, r.y, r.width + dx, r.height + dy);
    return clampToGrid(moved, widget.placement.style);
  }

  void _start(_Drag drag) => setState(() {
    _drag = drag;
    _delta = Offset.zero;
  });

  void _update(DragUpdateDetails details) =>
      setState(() => _delta += details.delta);

  void _end() {
    final target = _target;
    setState(() => _drag = null);
    if (target == _original) return;
    ref
        .read(dashboardLayoutProvider.notifier)
        .place(widget.page.id, widget.placement.id, target);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cell = widget.cell;
    final target = _target;
    final dragging = _drag != null;
    final fits = isFree(widget.page, target, ignoring: widget.placement.id);
    final outline = dragging && !fits ? scheme.error : scheme.primary;

    return Positioned(
      left: target.x * cell,
      top: target.y * cell,
      width: target.width * cell,
      height: target.height * cell,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Measured from where the finger went down, not from where the drag
        // was recognised: otherwise the gauge trails the finger by the touch
        // slop, and a short drag registers no movement at all.
        dragStartBehavior: DragStartBehavior.down,
        onTap: () => showGaugeOptions(
          context,
          pageId: widget.page.id,
          placementId: widget.placement.id,
          definition: widget.definition,
        ),
        onPanStart: (_) => _start(_Drag.move),
        onPanUpdate: _update,
        onPanEnd: (_) => _end(),
        onPanCancel: () => setState(() => _drag = null),
        child: Stack(
          children: [
            Positioned.fill(
              child: Opacity(opacity: dragging ? 0.7 : 1, child: widget.child),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: outline, width: dragging ? 2 : 1),
                  ),
                ),
              ),
            ),
            // Big enough to hit with a thumb, whatever size the cells are.
            Positioned(
              right: 0,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (_) => _start(_Drag.resize),
                onPanUpdate: _update,
                onPanEnd: (_) => _end(),
                onPanCancel: () => setState(() => _drag = null),
                child: Semantics(
                  label: 'Resize',
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.bottomRight,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(6),
                          bottomRight: Radius.circular(6),
                        ),
                      ),
                      child: Icon(
                        Icons.open_in_full,
                        size: 11,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hairline cell boundaries, shown while editing.
class _GridPainter extends CustomPainter {
  _GridPainter({required this.cell, required this.color});

  final double cell;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width + 0.5; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height + 0.5; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.cell != cell || old.color != color;
}
