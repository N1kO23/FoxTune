import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_state.dart';
import '../logging/record_button.dart';
import '../tune/tune_controller.dart';
import 'dashboard_controller.dart';
import 'dashboard_editor.dart';
import 'dashboard_grid.dart';
import 'gauge_catalog.dart';
import 'gauge_status.dart';
import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';
import 'sample_history.dart';

/// The live gauge cluster: pages of gauges the tuner arranges.
///
/// Read-only by construction: nothing here can change the tune. Arranging
/// gauges changes only the layout, never a setting - which is what makes it
/// safe to hand to someone with an engine running.
///
/// Which gauges exist, their ranges and their warning points all come from
/// the definition's `[GaugeConfigurations]`; the first page starts as its
/// `[FrontPage]`. Limits that are expressions - the tachometer's are the
/// Gauge Limits settings - are evaluated each time a gauge is drawn, so they
/// follow the tune.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.connection});

  final EcuConnected connection;

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String? _pageId;
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(realtimeProvider).valueOrNull;
    final monitor = ref.watch(realtimeMonitorProvider);
    final layout = ref.watch(dashboardLayoutProvider);
    final definition = widget.connection.definition;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _StatusBar(
            connection: widget.connection,
            monitor: monitor,
            hasData: snapshot != null,
          ),
        ),
        Expanded(
          child: definition == null
              ? const _Message(
                  text:
                      'No ECU definition is loaded, so there are no gauges '
                      'to show.',
                )
              : layout.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, _) => _Message(text: '$error'),
                  data: (layout) {
                    if (layout.pages.isEmpty) {
                      return const _Message(text: 'No dashboard pages.');
                    }
                    final page =
                        layout.pageById(_pageId ?? '') ?? layout.pages.first;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PageBar(
                          pages: layout.pages,
                          current: page,
                          editing: _editing,
                          definition: definition,
                          onSelect: (id) => setState(() => _pageId = id),
                          onToggleEditing: () =>
                              setState(() => _editing = !_editing),
                        ),
                        if (snapshot == null) const _WaitingForData(),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                            child: DashboardPageView(
                              page: page,
                              editing: _editing,
                              definition: definition,
                              catalog: GaugeCatalog(
                                definition: definition,
                                resolver: ref.watch(tuneResolverProvider),
                                realtime: snapshot,
                                limits: layout.limits,
                              ),
                              history: ref.watch(sampleHistoryProvider),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Page tabs, and - while editing - adding gauges and managing pages.
class _PageBar extends ConsumerWidget {
  const _PageBar({
    required this.pages,
    required this.current,
    required this.editing,
    required this.definition,
    required this.onSelect,
    required this.onToggleEditing,
  });

  final List<DashboardPage> pages;
  final DashboardPage current;
  final bool editing;
  final IniDocument definition;
  final ValueChanged<String> onSelect;
  final VoidCallback onToggleEditing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(dashboardLayoutProvider.notifier);
    final index = pages.indexWhere((p) => p.id == current.id);

    Future<void> add() async {
      final picked = await pickSource(context, definition: definition);
      if (picked == null) return;
      if (picked.indicator case final expression?) {
        controller.addGauge(
          current.id,
          style: GaugeStyle.lamp,
          indicator: expression,
        );
      } else if (picked.gauge case final gauge?) {
        controller.addGauge(
          current.id,
          // A bare channel has no declared range to put on a dial; it starts
          // as a number, and becomes a dial once it has a range.
          style: GaugeRef.channelOf(gauge) == null
              ? GaugeStyle.dial
              : GaugeStyle.digital,
          gauges: [gauge],
        );
      }
    }

    Future<void> pageAction(String action) async {
      switch (action) {
        case 'rename':
          final name = await askPageName(
            context,
            title: 'Rename page',
            initial: current.name,
          );
          if (name != null) controller.renamePage(current.id, name);
        case 'new':
          final name = await askPageName(
            context,
            title: 'New page',
            initial: 'Page ${pages.length + 1}',
          );
          if (name != null) {
            onSelect(controller.addPage(name, like: current.id));
          }
        case 'grid':
          final density = await showDialog<int>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Grid size'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'Squares across the page. A finer grid places and sizes '
                    'gauges in smaller steps; gauges stay the size they are.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                RadioGroup<int>(
                  groupValue: current.density,
                  onChanged: (value) => Navigator.of(context).pop(value),
                  child: Column(
                    children: [
                      for (final choice in gridDensityChoices)
                        RadioListTile<int>(
                          value: choice,
                          title: Text(
                            '${choice * current.width.phones} across',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
          if (density != null) controller.setDensity(current.id, density);
        case 'width':
          final width = await showDialog<PageWidth>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Page width'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'A wider page holds more gauges side by side, at the same '
                    'size. On a screen narrower than the page, the whole page '
                    'shrinks to fit.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                RadioGroup<PageWidth>(
                  groupValue: current.width,
                  onChanged: (value) => Navigator.of(context).pop(value),
                  child: Column(
                    children: [
                      for (final choice in PageWidth.values)
                        RadioListTile<PageWidth>(
                          value: choice,
                          title: Text(choice.label),
                          subtitle: Text(switch (choice.phones) {
                            1 => 'A phone held upright',
                            final n => '$n times as wide',
                          }),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
          if (width != null) controller.setWidth(current.id, width);
        case 'left':
          controller.movePage(current.id, -1);
        case 'right':
          controller.movePage(current.id, 1);
        case 'reset':
          if (!context.mounted) return;
          if (await confirm(
            context,
            title: 'Reset "${current.name}"?',
            message:
                'Its gauges are replaced with the ECU definition\'s '
                'default front page.',
            action: 'Reset',
          )) {
            controller.resetPage(current.id);
          }
        case 'delete':
          if (!context.mounted) return;
          if (await confirm(
            context,
            title: 'Delete "${current.name}"?',
            message: 'The page and its layout are removed.',
            action: 'Delete',
          )) {
            final fallback = pages[index == 0 ? 1 : index - 1];
            controller.deletePage(current.id);
            onSelect(fallback.id);
          }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final page in pages)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(page.name),
                        selected: page.id == current.id,
                        onSelected: (_) => onSelect(page.id),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (editing) ...[
            IconButton(
              tooltip: 'Add a gauge',
              onPressed: add,
              icon: const Icon(Icons.add_circle_outline),
            ),
            PopupMenuButton<String>(
              tooltip: 'Page',
              onSelected: pageAction,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'rename',
                  child: Text('Rename page'),
                ),
                const PopupMenuItem(value: 'new', child: Text('New page')),
                PopupMenuItem(
                  value: 'width',
                  child: Text('Page width (${current.width.label})'),
                ),
                PopupMenuItem(
                  value: 'grid',
                  child: Text('Grid size (${current.columns} across)'),
                ),
                PopupMenuItem(
                  value: 'left',
                  enabled: index > 0,
                  child: const Text('Move left'),
                ),
                PopupMenuItem(
                  value: 'right',
                  enabled: index < pages.length - 1,
                  child: const Text('Move right'),
                ),
                const PopupMenuItem(
                  value: 'reset',
                  child: Text('Reset to default'),
                ),
                PopupMenuItem(
                  value: 'delete',
                  enabled: pages.length > 1,
                  child: const Text('Delete page'),
                ),
              ],
            ),
          ],
          editing
              ? FilledButton.tonalIcon(
                  onPressed: onToggleEditing,
                  icon: const Icon(Icons.check),
                  label: const Text('Done'),
                )
              : IconButton(
                  tooltip: 'Edit layout',
                  onPressed: onToggleEditing,
                  icon: const Icon(Icons.dashboard_customize_outlined),
                ),
        ],
      ),
    );
  }
}

class _WaitingForData extends StatelessWidget {
  const _WaitingForData();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            'Waiting for the first realtime sample...',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.connection,
    required this.monitor,
    required this.hasData,
  });

  final EcuConnected connection;
  final RealtimeMonitor? monitor;
  final bool hasData;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stalled = monitor != null && !monitor!.isRunning && hasData;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  stalled ? Icons.link_off : Icons.link,
                  size: 16,
                  color: stalled ? StatusPalette.critical : StatusPalette.good,
                ),
                const SizedBox(width: 6),
                Text(
                  stalled ? 'Polling stopped' : 'Live',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: stalled ? StatusPalette.critical : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Text(
              connection.identification.signature,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (monitor != null)
              Text(
                // The achieved rate, not the requested one.
                '${monitor!.measuredHz.toStringAsFixed(1)} Hz · '
                '${monitor!.pollCount} polls',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            const RecordButton(),
            if (!ref.watch(writePermissionProvider).allowed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Read-only',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
