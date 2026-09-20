import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/gauge_status.dart';
import 'burn_actions.dart';
import 'msq_actions.dart';
import 'table_file_actions.dart';
import 'cursor_readout.dart';
import 'surface_view.dart';
import 'table_grid.dart';
import 'tune_controller.dart';

/// Which table is being edited.
final selectedTableProvider = StateProvider<String?>((ref) => null);

/// The table editor.
///
/// Editing is disabled unless the session has earned write permission, so the
/// default state of this screen - even connected to a running engine - cannot
/// change anything.
class TableEditorScreen extends ConsumerStatefulWidget {
  const TableEditorScreen({
    super.key,
    required this.connection,
    this.initialSurface = false,
  });

  final EcuConnected connection;

  /// Whether to open with the 3D surface already shown.
  ///
  /// The definition's "3D Tuning Maps" menu points at the same tables as the
  /// tuning menus, differing only in which view is wanted.
  final bool initialSurface;

  @override
  ConsumerState<TableEditorScreen> createState() => _TableEditorScreenState();
}

class _TableEditorScreenState extends ConsumerState<TableEditorScreen> {
  CellSelection _selection = const CellSelection.single(0, 0);
  late bool _showSurface = widget.initialSurface;

  @override
  Widget build(BuildContext context) {
    final tuneAsync = ref.watch(tuneProvider);
    final permission = ref.watch(writePermissionProvider);

    return tuneAsync.when(
      loading: () => const _LoadingTune(),
      error: (error, _) => _ErrorPane(message: '$error'),
      data: (tune) {
        if (tune == null) return const _ErrorPane(message: 'No tune loaded.');

        final definition = widget.connection.definition!;
        final tables = definition.tables;
        if (tables.isEmpty) {
          return const _ErrorPane(
            message: 'This definition declares no tables.',
          );
        }

        final selectedId = ref.watch(selectedTableProvider) ?? tables.first.id;
        final table = definition.tableNamed(selectedId) ?? tables.first;
        final view = TableView.of(tune, table);
        if (view == null) {
          return _ErrorPane(
            message: 'Table "${table.title}" could not be resolved.',
          );
        }

        return Column(
          children: [
            _Toolbar(
              tables: tables,
              view: view,
              selectedId: table.id,
              permission: permission,
              tune: tune,
              showSurface: _showSurface,
              onToggleSurface: () =>
                  setState(() => _showSurface = !_showSurface),
              onSelect: (id) {
                ref.read(selectedTableProvider.notifier).state = id;
                setState(() => _selection = const CellSelection.single(0, 0));
              },
            ),
            const Divider(height: 1),
            if (!view.isXAxisAscending || !view.isYAxisAscending)
              _AxisOrderWarning(
                xAscending: view.isXAxisAscending,
                yAscending: view.isYAxisAscending,
              ),
            CursorReadout(
              view: view,
              cursor: _cursorFor(view),
              x: _channelValue(view.table.xBins.channel),
              y: _channelValue(view.table.yBins.channel),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_showSurface) ...[
                      SurfaceView(
                        view: view,
                        cursor: _cursorFor(view),
                        preciseCursor: _preciseCursorFor(view),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TableGrid(
                      view: view,
                      selection: _selection,
                      editable: permission.allowed,
                      cursor: _cursorFor(view),
                      preciseCursor: _preciseCursorFor(view),
                      contributing: _contributingFor(view),
                      changes: _changesFor(view, table),
                      onSelectionChanged: (s) => setState(() => _selection = s),
                      onEdit: (edit) {
                        edit(view);
                        ref.read(tuneProvider.notifier).notifyEdited();
                      },
                      onEditAxis: (edit) {
                        edit(view);
                        ref.read(tuneProvider.notifier).notifyEdited();
                      },
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            _EditBar(
              view: view,
              selection: _selection,
              enabled: permission.allowed,
              onEdited: () => ref.read(tuneProvider.notifier).notifyEdited(),
            ),
          ],
        );
      },
    );
  }

  /// A live realtime channel value, or `null` when it is unavailable.
  double? _channelValue(String? channel) {
    if (channel == null) return null;
    return ref.watch(realtimeProvider).valueOrNull?[channel];
  }

  /// Cells this session has changed but not yet burned.
  Map<({int row, int column}), CellChange> _changesFor(
    TableView view,
    IniTable table,
  ) {
    final baseline = ref.watch(tuneBaselineProvider);
    if (baseline == null) return const {};
    final before = TableView.of(baseline, table);
    return before == null ? const {} : view.changesAgainst(before);
  }

  /// The cells the ECU is interpolating between right now.
  Set<({int row, int column})> _contributingFor(TableView view) {
    final precise = _preciseCursorFor(view);
    if (precise == null) return const {};
    return view.contributingCells(precise.row, precise.column).toSet();
  }

  /// The engine's exact position on the grid, for the overlay marker.
  ({double row, double column})? _preciseCursorFor(TableView view) {
    final x = _channelValue(view.table.xBins.channel);
    final y = _channelValue(view.table.yBins.channel);
    if (x == null || y == null) return null;
    return view.preciseCellFor(x, y);
  }

  /// Where the engine is operating, from the live realtime feed.
  ({int row, int column})? _cursorFor(TableView view) {
    final x = _channelValue(view.table.xBins.channel);
    final y = _channelValue(view.table.yBins.channel);
    if (x == null || y == null) return null;
    return view.cellFor(x, y);
  }
}

class _LoadingTune extends ConsumerWidget {
  const _LoadingTune();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.read(tuneProvider.notifier).progress;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: progress?.fraction),
          const SizedBox(height: 16),
          Text(
            progress == null
                ? 'FOX2: Reading tune from ECU...'
                : 'FOX2: Reading page ${progress.page} of ${progress.total}...',
          ),
        ],
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(message, textAlign: TextAlign.center),
    ),
  );
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.tables,
    required this.view,
    required this.selectedId,
    required this.permission,
    required this.tune,
    required this.showSurface,
    required this.onToggleSurface,
    required this.onSelect,
  });

  final List<IniTable> tables;

  /// The table currently open, for the per-table file actions.
  final TableView view;

  final String selectedId;
  final WritePermission permission;
  final TuneState tune;
  final bool showSurface;
  final VoidCallback onToggleSurface;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final writeMode = ref.watch(writeModeProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // A DropdownButton sizes itself to its widest item, and some table
          // titles are long ("Second Ignition Advance Table"). Left
          // unconstrained it overflows a phone-width toolbar, so cap it and let
          // the label ellipsize.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: DropdownButton<String>(
              value: selectedId,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              items: [
                for (final table in tables)
                  DropdownMenuItem(
                    value: table.id,
                    child: Text(table.title, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => id == null ? null : onSelect(id),
            ),
          ),
          // The write-mode switch is the deliberate act that unlocks editing.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: writeMode,
                onChanged: (v) => ref.read(writeModeProvider.notifier).set(v),
              ),
              const SizedBox(width: 4),
              Text('Write mode', style: theme.textTheme.labelLarge),
            ],
          ),
          if (!permission.allowed)
            Tooltip(
              message: permission.reason ?? '',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 15),
                  const SizedBox(width: 4),
                  Text('Read-only', style: theme.textTheme.labelSmall),
                ],
              ),
            ),
          if (tune.isDirty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note, size: 16, color: StatusPalette.warning),
                const SizedBox(width: 4),
                Text(
                  '${tune.dirtyPages.length} page(s) changed',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: StatusPalette.warning,
                  ),
                ),
              ],
            ),
          FilledButton.icon(
            onPressed: permission.allowed && tune.isDirty
                ? () => BurnActions.confirmAndBurn(context, ref, tune)
                : null,
            icon: const Icon(Icons.save),
            label: const Text('Burn to ECU'),
          ),
          IconButton(
            tooltip: showSurface ? 'Hide 3D surface' : 'Show 3D surface',
            isSelected: showSurface,
            icon: const Icon(Icons.view_in_ar_outlined),
            selectedIcon: const Icon(Icons.view_in_ar),
            onPressed: onToggleSurface,
          ),
          TextButton.icon(
            onPressed: () => ref.read(tuneProvider.notifier).reload(),
            icon: const Icon(Icons.refresh),
            label: const Text('Re-read'),
          ),
          MenuAnchor(
            builder: (context, controller, _) => IconButton(
              tooltip: 'Tune file',
              icon: const Icon(Icons.folder_outlined),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
            ),
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.save_alt),
                onPressed: () => MsqActions.save(context, ref, tune),
                child: const Text('Save tune as .msq'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.grid_on_outlined),
                onPressed: () => TableFileActions.export(context, ref, view),
                child: const Text('Export this table'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.grid_4x4),
                onPressed: () => TableFileActions.import(context, ref, view),
                child: const Text('Import into this table'),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.file_open_outlined),
                // Loading only changes the in-memory tune; the ECU is not
                // touched until the user burns.
                onPressed: () => MsqActions.load(context, ref, tune),
                child: const Text('Load .msq into editor'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Operations that apply to the current selection.
class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.view,
    required this.selection,
    required this.enabled,
    required this.onEdited,
  });

  final TableView view;
  final CellSelection selection;
  final bool enabled;
  final VoidCallback onEdited;

  void _apply(void Function() edit) {
    edit();
    onEdited();
  }

  /// Asks for one value and writes it to every selected cell.
  Future<void> _promptForValue(BuildContext context) async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _SetValueDialog(
        cellCount: selection.cellCount,
        units: view.zUnits,
        decimals: view.zDecimals,
        low: view.low,
        high: view.high,
        current: view.valueAt(selection.focusRow, selection.focusColumn),
      ),
    );
    if (value == null) return;
    _apply(() => view.fill(selection.cells, value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cells = selection.cells;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${selection.cellCount} cell(s)',
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(width: 8),
          _Action(
            label: '−1',
            enabled: enabled,
            onPressed: () => _apply(() => view.adjustBy(cells, -1)),
          ),
          _Action(
            label: '+1',
            enabled: enabled,
            onPressed: () => _apply(() => view.adjustBy(cells, 1)),
          ),
          _Action(
            label: '−1%',
            enabled: enabled,
            onPressed: () => _apply(() => view.scaleBy(cells, 99)),
          ),
          _Action(
            label: '+1%',
            enabled: enabled,
            onPressed: () => _apply(() => view.scaleBy(cells, 101)),
          ),
          // The keyboard path is type-over; a phone has no keyboard, so the
          // same operation needs a button.
          _Action(
            label: 'Set…',
            enabled: enabled,
            onPressed: () => _promptForValue(context),
          ),
          _Action(
            label: 'Interpolate',
            enabled: enabled && selection.cellCount > 2,
            onPressed: () => _apply(() => view.interpolateRegion(cells)),
          ),
          _Action(
            label: 'Smooth',
            enabled: enabled && selection.cellCount > 1,
            onPressed: () => _apply(() => view.smooth(cells)),
          ),
          // No Spacer here: this is a Wrap, which has no free space to
          // distribute. A Spacer is an Expanded, and handing Flex parent data
          // to a Wrap child breaks the layout of the whole enclosing Column -
          // silently in release builds, where the assertion is compiled out.
          // The hint simply trails the actions and wraps with them.
          Text(
            'Type to set · Enter applies · Arrows move · Shift or long-press \n'
            'extends · +/− adjust · [ ] scale',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) =>
      OutlinedButton(onPressed: enabled ? onPressed : null, child: Text(label));
}

/// Warns when an axis has stopped ascending.
///
/// The ECU interpolates on the assumption that bins increase, and so does the
/// live position marker. Editing is not blocked - spreading bins out means
/// passing through inconsistent intermediate states - so the condition is
/// surfaced instead.
class _AxisOrderWarning extends StatelessWidget {
  const _AxisOrderWarning({required this.xAscending, required this.yAscending});

  final bool xAscending;
  final bool yAscending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final axes = [
      if (!xAscending) 'RPM',
      if (!yAscending) 'load',
    ].join(' and ');

    return Container(
      width: double.infinity,
      color: StatusPalette.warning.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 15,
            color: StatusPalette.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'The $axes axis is not increasing. The ECU expects axis values '
              'to ascend; fix the order before burning.',
              style: theme.textTheme.labelSmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Prompts for a value to write across the selection.
class _SetValueDialog extends StatefulWidget {
  const _SetValueDialog({
    required this.cellCount,
    required this.units,
    required this.decimals,
    required this.low,
    required this.high,
    required this.current,
  });

  final int cellCount;
  final String units;
  final int decimals;
  final double? low;
  final double? high;
  final double? current;

  @override
  State<_SetValueDialog> createState() => _SetValueDialogState();
}

class _SetValueDialogState extends State<_SetValueDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current?.toStringAsFixed(widget.decimals) ?? '',
  );
  String? _error;

  @override
  void initState() {
    super.initState();
    // Preselected so typing replaces, matching the keyboard behaviour.
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = double.tryParse(_controller.text.trim());
    if (value == null) {
      setState(() => _error = 'Not a number');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final range = widget.low == null || widget.high == null
        ? null
        : 'Permitted: ${widget.low!.toStringAsFixed(widget.decimals)} to '
              '${widget.high!.toStringAsFixed(widget.decimals)}';

    return AlertDialog(
      title: Text(
        widget.cellCount == 1
            ? 'Set cell value'
            : 'Set ${widget.cellCount} cells',
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        decoration: InputDecoration(
          suffixText: widget.units,
          errorText: _error,
          helperText: range,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Set')),
      ],
    );
  }
}
