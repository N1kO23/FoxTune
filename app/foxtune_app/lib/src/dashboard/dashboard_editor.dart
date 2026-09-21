import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import 'gauge_catalog.dart';
import 'gauge_status.dart';
import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';

/// What the gauge picker returned: a numeric source as a [GaugeRef], or the
/// expression of an indicator.
typedef PickedSource = ({String? gauge, String? indicator});

/// Which sources a picker offers.
enum PickerMode { gauges, indicators, both }

/// Most channels one time graph shows. Past four, lanes get too thin to read.
const maxGraphLanes = 4;

/// Asks for a gauge, a channel or an indicator from the definition.
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

enum _Tab {
  gauges('Gauges'),
  channels('Channels'),
  indicators('Indicators');

  const _Tab(this.label);
  final String label;
}

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

  late final List<_Tab> _tabs = switch (widget.mode) {
    PickerMode.both => _Tab.values,
    PickerMode.gauges => const [_Tab.gauges, _Tab.channels],
    PickerMode.indicators => const [_Tab.indicators, _Tab.channels],
  };
  late _Tab _tab = _tabs.first;

  late final List<ChannelChoice> _channels = [
    for (final channel in GaugeCatalog.channelsWithoutGauges(widget.definition))
      if (switch (widget.mode) {
        PickerMode.both => true,
        PickerMode.gauges => !channel.isFlag,
        PickerMode.indicators => channel.isFlag,
      })
        channel,
  ];

  bool _matches(String text) =>
      _query.isEmpty || text.toLowerCase().contains(_query.toLowerCase());

  Widget _heading(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.1,
        color: theme.colorScheme.primary,
      ),
    ),
  );

  List<Widget> _indicators() => [
    for (final indicator in widget.definition.frontPage.indicators)
      if (_matches(
        '${indicator.onLabel} ${indicator.offLabel} ${indicator.expression}',
      ))
        ListTile(
          leading: const Icon(Icons.circle_outlined, size: 18),
          title: Text(indicator.onLabel),
          subtitle: Text(indicator.offLabel),
          onTap: () =>
              Navigator.of(context)
                  .pop((gauge: null, indicator: indicator.expression)),
        ),
  ];

  List<Widget> _gauges(ThemeData theme) {
    final children = <Widget>[];
    String? category;
    for (final gauge in widget.definition.gauges) {
      if (!_matches(
        '${gauge.displayTitle} ${gauge.channel} ${gauge.category}',
      )) {
        continue;
      }
      if (gauge.category != category) {
        category = gauge.category;
        children.add(_heading(theme, category.isEmpty ? 'Gauges' : category));
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
    return children;
  }

  List<Widget> _channelList(ThemeData theme) {
    final matching = [
      for (final channel in _channels)
        if (_matches('${channel.name} ${channel.units}')) channel,
    ];
    if (matching.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          'Live channels the ECU definition has no gauge for. It gives them '
          'no range or alarms, so set your own from the gauge\'s options.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final channel in matching)
        ListTile(
          leading: channel.isFlag
              ? const Icon(Icons.circle_outlined, size: 18)
              : const Icon(Icons.numbers, size: 18),
          title: Text(channel.name),
          subtitle: Text(
            channel.isFlag
                ? 'Status bit'
                : (channel.units.isEmpty ? 'Number' : channel.units),
          ),
          onTap: () => Navigator.of(context).pop(
            channel.isFlag
                ? (gauge: null, indicator: channel.name)
                : (gauge: GaugeRef.channel(channel.name), indicator: null),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = switch (_tab) {
      _Tab.gauges => _gauges(theme),
      _Tab.channels => _channelList(theme),
      _Tab.indicators => _indicators(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(widget.title, style: theme.textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<_Tab>(
            showSelectedIcon: false,
            segments: [
              for (final tab in _tabs)
                ButtonSegment(value: tab, label: Text(tab.label)),
            ],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
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
  required GaugeCatalog catalog,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _GaugeOptions(
    pageId: pageId,
    placementId: placementId,
    definition: definition,
    catalog: catalog,
  ),
);

/// Style, source, limits, graph channels and window, and removal, for one
/// gauge.
///
/// Reads the gauge back from the layout on every build, so each change shows
/// at once without closing the sheet.
class _GaugeOptions extends ConsumerWidget {
  const _GaugeOptions({
    required this.pageId,
    required this.placementId,
    required this.definition,
    required this.catalog,
  });

  final String pageId;
  final String placementId;
  final IniDocument definition;
  final GaugeCatalog catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(dashboardLayoutProvider.notifier);
    final layout = ref.watch(dashboardLayoutProvider).valueOrNull;
    final placement = layout
        ?.pageById(pageId)
        ?.items
        .where((i) => i.id == placementId)
        .firstOrNull;
    if (layout == null || placement == null) return const SizedBox.shrink();
    final catalog = this.catalog.withLimits(layout.limits);

    void update(GaugePlacement next) => controller.replaceGauge(pageId, next);

    Future<void> editLimits(String source) async {
      final result = await showDialog<({GaugeLimits? limits})>(
        context: context,
        builder: (_) => _LimitsDialog(
          catalog: catalog,
          source: source,
          own: layout.limits[source],
        ),
      );
      if (result != null) controller.setLimits(source, result.limits);
    }

    final children = <Widget>[];

    if (placement.style == GaugeStyle.lamp) {
      final indicator = catalog.indicatorFor(placement.indicator);
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
      final refs = placement.gauges;
      children
        ..add(
          Text(
            refs.isEmpty ? 'Gauge' : catalog.titleOfRef(refs.first),
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
                  gauges: style == GaugeStyle.graph || refs.isEmpty
                      ? refs
                      : [refs.first],
                ),
              );
            },
          ),
        );

      if (placement.style == GaugeStyle.graph) {
        children.add(const SizedBox(height: 12));
        for (final source in refs) {
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(catalog.titleOfRef(source)),
              subtitle: Text(_describe(catalog, source)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Range and alarms',
                    icon: const Icon(Icons.tune),
                    onPressed: () => editLimits(source),
                  ),
                  if (refs.length > 1)
                    IconButton(
                      tooltip: 'Remove from graph',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => update(
                        placement.copyWith(
                          gauges: [
                            for (final r in refs)
                              if (r != source) r,
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        if (refs.length < maxGraphLanes) {
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
                if (picked?.gauge case final source?) {
                  if (refs.contains(source)) return;
                  update(placement.copyWith(gauges: [...refs, source]));
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
              if (picked?.gauge case final source?) {
                update(placement.copyWith(gauges: [source]));
              }
            },
          ),
        );
        if (refs.isNotEmpty) {
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.tune),
              title: const Text('Range and alarms'),
              subtitle: Text(_describe(catalog, refs.first)),
              onTap: () => editLimits(refs.first),
            ),
          );
        }
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

/// A one-line summary of a gauge's range and alarms, and where they come
/// from.
String _describe(GaugeCatalog catalog, String source) {
  final spec = catalog.specOf(source);
  if (spec == null) return 'Not in this ECU definition';
  final mine = catalog.limits.containsKey(source);

  String n(double value) => spec.formatLabel(value);
  final parts = [
    if (!spec.hasRange)
      'No range declared'
    else
      '${n(spec.min)} to ${n(spec.max)}'
          '${spec.units.isEmpty ? '' : ' ${spec.units}'}',
    if (spec.dangerBelow case final v?) 'danger at ${n(v)} or below',
    if (spec.warnBelow case final v?) 'warn at ${n(v)} or below',
    if (spec.warnAbove case final v?) 'warn at ${n(v)} or above',
    if (spec.dangerAbove case final v?) 'danger at ${n(v)} or above',
    if (spec.dangerBelow == null &&
        spec.warnBelow == null &&
        spec.warnAbove == null &&
        spec.dangerAbove == null)
      'no alarms',
  ];
  return '${parts.join(', ')}${mine ? ' (set by you)' : ''}';
}

/// Edits one gauge's range, alarm points and decimals.
///
/// Returns `(limits: ...)` to save, `(limits: null)` to hand the gauge back to
/// the definition, or nothing if cancelled. Owns its text controllers, so they
/// live exactly as long as the fields using them.
class _LimitsDialog extends StatefulWidget {
  const _LimitsDialog({
    required this.catalog,
    required this.source,
    required this.own,
  });

  final GaugeCatalog catalog;
  final String source;

  /// Limits already set by the tuner, if any.
  final GaugeLimits? own;

  @override
  State<_LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<_LimitsDialog> {
  late final GaugeSpec? _defined = widget.catalog.definedSpecOf(widget.source);

  late final _min = _field(widget.own?.min ?? _definedRange?.min);
  late final _max = _field(widget.own?.max ?? _definedRange?.max);
  late final _bands = _startingBands();
  late final _dangerBelow = _field(_bands.dangerBelow);
  late final _warnBelow = _field(_bands.warnBelow);
  late final _warnAbove = _field(_bands.warnAbove);
  late final _dangerAbove = _field(_bands.dangerAbove);
  late final _decimals = TextEditingController(
    text: '${widget.own?.decimals ?? _defined?.decimals ?? 0}',
  );

  String? _problem;

  ({double min, double max})? get _definedRange {
    final spec = _defined;
    return spec == null || !spec.hasRange
        ? null
        : (min: spec.min, max: spec.max);
  }

  /// The alarm points the fields start from: the tuner's, if they have set
  /// limits - where a missing band means off - and otherwise the definition's.
  ({
    double? dangerBelow,
    double? warnBelow,
    double? warnAbove,
    double? dangerAbove,
  })
  _startingBands() {
    if (widget.own case final own?) {
      return (
        dangerBelow: own.dangerBelow,
        warnBelow: own.warnBelow,
        warnAbove: own.warnAbove,
        dangerAbove: own.dangerAbove,
      );
    }
    final spec = _defined;
    return (
      dangerBelow: spec?.dangerBelow,
      warnBelow: spec?.warnBelow,
      warnAbove: spec?.warnAbove,
      dangerAbove: spec?.dangerAbove,
    );
  }

  TextEditingController _field(double? value) =>
      TextEditingController(text: value == null ? '' : _plain(value));

  /// [value] without trailing zeros: 3000, not 3000.0.
  static String _plain(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  static double? _parse(TextEditingController field) {
    final text = field.text.trim().replaceAll(',', '.');
    return text.isEmpty ? null : double.tryParse(text);
  }

  @override
  void dispose() {
    for (final field in [
      _min,
      _max,
      _dangerBelow,
      _warnBelow,
      _warnAbove,
      _dangerAbove,
      _decimals,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void _save() {
    final limits = GaugeLimits(
      min: _parse(_min) ?? double.nan,
      max: _parse(_max) ?? double.nan,
      decimals: int.tryParse(_decimals.text.trim()) ?? -1,
      dangerBelow: _parse(_dangerBelow),
      warnBelow: _parse(_warnBelow),
      warnAbove: _parse(_warnAbove),
      dangerAbove: _parse(_dangerAbove),
    );
    final problem = limits.problem;
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.of(context).pop((limits: limits));
  }

  Widget _number(TextEditingController controller, String label) => TextField(
    controller: controller,
    keyboardType: const TextInputType.numberWithOptions(
      signed: true,
      decimal: true,
    ),
    decoration: InputDecoration(labelText: label, isDense: true),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = widget.catalog;
    final source = widget.source;
    final units = _defined?.units ?? '';
    final isChannel = GaugeRef.channelOf(source) != null;

    final notes = [
      if (isChannel && _definedRange == null)
        'The ECU definition declares no range for this channel. Set one to '
            'draw it as a dial or bar.'
      else if (isChannel)
        'The ECU definition gives this channel no gauge. The range shown is '
            'everything it can report, which is rarely what it actually does.',
      if (catalog.followsTune(source))
        'The definition ties these limits to settings in the tune - Gauge '
            'Limits, for the tachometer. Saving here fixes them at what you '
            'enter, and they stop following the tune.',
      if (catalog.ignoresDefinedBands(source))
        "The definition's alarm points for this gauge contradict each other - "
            'no reading at all would count as normal - so FoxTune ignores '
            'them. Set your own here.',
    ];

    return AlertDialog(
      title: Text(catalog.titleOfRef(source)),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note, style: theme.textTheme.bodySmall),
            ),
          Text(
            units.isEmpty ? 'Range' : 'Range, in $units',
            style: theme.textTheme.labelLarge,
          ),
          Row(
            children: [
              Expanded(child: _number(_min, 'From')),
              const SizedBox(width: 12),
              Expanded(child: _number(_max, 'To')),
            ],
          ),
          const SizedBox(height: 16),
          Text('Alarms', style: theme.textTheme.labelLarge),
          Text(
            'Leave one empty to switch it off.',
            style: theme.textTheme.bodySmall,
          ),
          Row(
            children: [
              Expanded(child: _number(_dangerBelow, 'Danger at or below')),
              const SizedBox(width: 12),
              Expanded(child: _number(_warnBelow, 'Warn at or below')),
            ],
          ),
          Row(
            children: [
              Expanded(child: _number(_warnAbove, 'Warn at or above')),
              const SizedBox(width: 12),
              Expanded(child: _number(_dangerAbove, 'Danger at or above')),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _decimals,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Decimals',
                isDense: true,
              ),
            ),
          ),
          if (_problem case final problem?) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  StatusPalette.iconFor(GaugeStatus.danger),
                  size: 16,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    problem,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        if (widget.own != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop((limits: null)),
            child: const Text("Use the definition's"),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
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
