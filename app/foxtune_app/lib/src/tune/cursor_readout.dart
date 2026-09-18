import 'package:flutter/material.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Shows where the engine is currently operating on the open table.
///
/// The grid rings the live cell, but on a 16x16 table that cell is often
/// scrolled out of view, and at speed it moves faster than the eye tracks. This
/// states the operating point in words so it stays readable regardless.
class CursorReadout extends StatelessWidget {
  const CursorReadout({
    super.key,
    required this.view,
    required this.cursor,
    required this.x,
    required this.y,
  });

  final TableView view;

  /// The cell the engine is operating in, if it could be determined.
  final ({int row, int column})? cursor;

  /// Live X axis value, in the axis's own units.
  final double? x;

  /// Live Y axis value.
  final double? y;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cell = cursor;

    // Without live data there is no operating point to show. Say so rather
    // than rendering a stale or invented position.
    if (cell == null || x == null || y == null) {
      return _Bar(
        children: [
          Icon(
            Icons.my_location_outlined,
            size: 15,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            'No live position - connect and wait for realtime data',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final value = view.valueAt(cell.row, cell.column);
    final label = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final figure = theme.textTheme.labelLarge?.copyWith(
      color: scheme.onSurface,
      fontWeight: FontWeight.w600,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return _Bar(
      children: [
        Icon(Icons.my_location, size: 15, color: scheme.tertiary),
        const SizedBox(width: 8),
        Text('Operating at ', style: label),
        Text('${x!.toStringAsFixed(0)} ${view.xUnits}', style: figure),
        Text(' · ', style: label),
        Text('${y!.toStringAsFixed(0)} ${view.yUnits}', style: figure),
        Text('  →  ', style: label),
        Text(
          value == null
              ? '--'
              : '${value.toStringAsFixed(view.zDecimals)} ${view.zUnits}',
          style: figure?.copyWith(color: scheme.tertiary),
        ),
        Text('   cell R${cell.row + 1} C${cell.column + 1}', style: label),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    // Wrap rather than Row: this sits in a Column whose width is the
    // screen, and the figures must not overflow on a phone.
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    ),
  );
}
