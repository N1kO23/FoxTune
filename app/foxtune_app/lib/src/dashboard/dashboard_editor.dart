import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';

/// What the gauge picker returned: a gauge or an indicator.
typedef PickedSource = ({String? gauge, String? indicator});

/// Which sources a picker offers.
enum PickerMode { gauges, indicators, both }

/// Most channels one time graph shows. Past four, lanes get too thin to read.
const maxGraphLanes = 4;

/// Asks for a gauge or an indicator from the definition.
Future<PickedSource?> pickSource(
  BuildContext context, {
  required IniDocument definition,
  PickerMode mode = PickerMode.both,
  String title = 'Add to page',
}) => showModalBottomSheet<PickedSource>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.8,
    maxChildSize: 0.95,
    builder: (context, controller) => _SourcePicker(
      definition: definition,
      mode: mode,
      title: title,
      scroll: controller,
    ),
  ),
);

class _SourcePicker extends StatefulWidget {
  const _SourcePicker({
    required this.definition,
    required this.mode,
    required this.title,
    required this.scroll,
  });

  final IniDocument definition;
  final PickerMode mode;
  final String title;
  final ScrollController scroll;

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  String _query = '';
  late bool _indicators = widget.mode == PickerMode.indicators;

  bool _matches(String text) =>
      _query.isEmpty || text.toLowerCase().contains(_query.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final definition = widget.definition;

    final children = <Widget>[];
    if (_indicators) {
      for (final indicator in definition.frontPage.indicators) {
        if (!_matches(
          '${indicator.onLabel} ${indicator.offLabel} '
          '${indicator.expression}',
        )) {
          continue;
        }
        children.add(
          ListTile(
            leading: const Icon(Icons.circle_outlined, size: 18),
            title: Text(indicator.onLabel),
            subtitle: Text(indicator.offLabel),
            onTap: () =>
                Navigator.of(context)
                    .pop((gauge: null, indicator: indicator.expression)),
          ),
        );
      }
    } else {
      String? category;
      for (final gauge in definition.gauges) {
        if (!_matches(
          '${gauge.displayTitle} ${gauge.channel} '
          '${gauge.category}',
        )) {
          continue;
        }
        if (gauge.category != category) {
          category = gauge.category;
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                category.isEmpty ? 'Gauges' : category.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          );
        }
        children.add(
          ListTile(
            title: Text(gauge.displayTitle),
            subtitle: Text(
              [
                gauge.channel,
                if (gauge.units.isNotEmpty) gauge.units,
              ].join(' · '),
            ),
            onTap: () =>
                Navigator.of(context).pop((gauge: gauge.name, indicator: null)),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(widget.title, style: theme.textTheme.titleMedium),
        ),
        if (widget.mode == PickerMode.both)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Gauges')),
                ButtonSegment(value: true, label: Text('Indicators')),
              ],
              selected: {_indicators},
              onSelectionChanged: (s) => setState(() => _indicators = s.first),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search',
              border: OutlineInputBorder(),
            ),
            onChanged: (q) => setState(() => _query = q.trim()),
          ),
        ),
        Expanded(
          child: children.isEmpty
              ? const Center(child: Text('Nothing matches.'))
              : ListView(controller: widget.scroll, children: children),
        ),
      ],
    );
  }
}

/// Opens the options for one placed gauge.
Future<void> showGaugeOptions(
  BuildContext context, {
  required String pageId,
  required String placementId,
  required IniDocument definition,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _GaugeOptions(
    pageId: pageId,
    placementId: placementId,
    definition: definition,
  ),
);

/// Style, source, graph channels and window, and removal, for one gauge.
///
/// Reads the gauge back from the layout on every build, so each change shows
/// at once without closing the sheet.
class _GaugeOptions extends ConsumerWidget {
  const _GaugeOptions({
    required this.pageId,
    required this.placementId,
    required this.definition,
  });

  final String pageId;
  final String placementId;
  final IniDocument definition;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(dashboardLayoutProvider.notifier);
    final placement = ref
        .watch(dashboardLayoutProvider)
        .valueOrNull
        ?.pageById(pageId)
        ?.items
        .where((i) => i.id == placementId)
        .firstOrNull;
    if (placement == null) return const SizedBox.shrink();

    void update(GaugePlacement next) => controller.replaceGauge(pageId, next);

    final children = <Widget>[];

    if (placement.style == GaugeStyle.lamp) {
      final indicator = definition.frontPage.indicators
          .where((i) => i.expression == placement.indicator)
          .firstOrNull;
      children
        ..add(
          Text(
            indicator?.onLabel ?? placement.indicator ?? 'Indicator',
            style: theme.textTheme.titleMedium,
          ),
        )
        ..add(
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Change indicator'),
            onTap: () async {
              final picked = await pickSource(
                context,
                definition: definition,
                mode: PickerMode.indicators,
                title: 'Change indicator',
              );
              if (picked?.indicator case final expression?) {
                update(placement.copyWith(indicator: expression));
              }
            },
          ),
        );
    } else {
      final names = placement.gauges;
      final first = names.isEmpty ? null : definition.gaugeNamed(names.first);
      children
        ..add(
          Text(
            first?.displayTitle ?? names.firstOrNull ?? 'Gauge',
            style: theme.textTheme.titleMedium,
          ),
        )
        ..add(const SizedBox(height: 12))
        ..add(
          SegmentedButton<GaugeStyle>(
            showSelectedIcon: false,
            segments: [
              for (final style in GaugeStyle.numeric)
                ButtonSegment(value: style, label: Text(style.label)),
            ],
            selected: {placement.style},
            onSelectionChanged: (s) {
              final style = s.first;
              update(
                placement.copyWith(
                  style: style,
                  // Only a graph shows more than one channel.
                  gauges: style == GaugeStyle.graph || names.isEmpty
                      ? names
                      : [names.first],
                ),
              );
            },
          ),
        );

      if (placement.style == GaugeStyle.graph) {
        children.add(const SizedBox(height: 12));
        for (final name in names) {
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(definition.gaugeNamed(name)?.displayTitle ?? name),
              trailing: names.length > 1
                  ? IconButton(
                      tooltip: 'Remove from graph',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => update(
                        placement.copyWith(
                          gauges: [
                            for (final n in names)
                              if (n != name) n,
                          ],
                        ),
                      ),
                    )
                  : null,
            ),
          );
        }
        if (names.length < maxGraphLanes) {
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add),
              title: const Text('Add a channel'),
              onTap: () async {
                final picked = await pickSource(
                  context,
                  definition: definition,
                  mode: PickerMode.gauges,
                  title: 'Add to graph',
                );
                if (picked?.gauge case final gauge?) {
                  if (names.contains(gauge)) return;
                  update(placement.copyWith(gauges: [...names, gauge]));
                }
              },
            ),
          );
        }
        children
          ..add(const SizedBox(height: 8))
          ..add(Text('Time shown', style: theme.textTheme.labelLarge))
          ..add(const SizedBox(height: 4))
          ..add(
            Wrap(
              spacing: 8,
              children: [
                for (final seconds in graphWindows)
                  ChoiceChip(
                    label: Text('${seconds}s'),
                    selected: placement.windowSeconds == seconds,
                    onSelected: (_) =>
                        update(placement.copyWith(windowSeconds: seconds)),
                  ),
              ],
            ),
          );
      } else {
        children.add(
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Change gauge'),
            onTap: () async {
              final picked = await pickSource(
                context,
                definition: definition,
                mode: PickerMode.gauges,
                title: 'Change gauge',
              );
              if (picked?.gauge case final gauge?) {
                update(placement.copyWith(gauges: [gauge]));
              }
            },
          ),
        );
      }
    }

    children
      ..add(const Divider(height: 24))
      ..add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            onPressed: () {
              controller.removeGauge(pageId, placementId);
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove from page'),
          ),
        ),
      );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// Asks for a page name. Returns `null` if cancelled or left blank.
Future<String?> askPageName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _PageNameDialog(title: title, initial: initial),
  );
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Owns its text controller, so the controller lives exactly as long as the
/// field using it - including through the dialog's closing animation, which
/// outlasts the moment the dialog returns its answer.
class _PageNameDialog extends StatefulWidget {
  const _PageNameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_PageNameDialog> createState() => _PageNameDialogState();
}

class _PageNameDialogState extends State<_PageNameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Page name'),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('OK'),
      ),
    ],
  );
}

/// Asks before something that cannot be undone.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
