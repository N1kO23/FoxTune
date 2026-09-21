import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/gauge_status.dart';
import '../tune/burn_actions.dart';
import '../tune/surface_screen.dart';
import '../tune/table_editor_screen.dart';
import '../tune/tune_controller.dart';
import 'curve_editor.dart';
import 'dialog_view.dart';
import 'settings_scope.dart';

/// Which settings screen is open.
final selectedSettingProvider = StateProvider<String?>((ref) => null);

/// The ECU's settings, generated from the definition's own menu.
///
/// Trigger setup, engine constants, injector characteristics, warmup and
/// afterstart enrichment and everything else a tune needs beyond its tables.
/// Nothing here is hand-written per setting: the screens, the controls, and
/// the rules for which fields apply all come out of the `.ini`, which is what
/// lets FoxTune follow a firmware release rather than trail it.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, required this.connection});

  final EcuConnected connection;

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tuneAsync = ref.watch(tuneProvider);

    return tuneAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Message(text: '$error'),
      data: (tune) {
        final definition = widget.connection.definition;
        if (tune == null || definition == null) {
          return const _Message(text: 'No tune loaded.');
        }
        if (definition.menus.isEmpty) {
          return const _Message(
            text: 'This definition declares no settings menus.',
          );
        }

        final resolver =
            ref.watch(tuneResolverProvider) ?? TuneValueResolver(tune);
        final scope = SettingsScope(
          tune: tune,
          resolver: resolver,
          realtime: ref.watch(realtimeProvider).valueOrNull,
        );

        final permission = ref.watch(writePermissionProvider);
        final selected = ref.watch(selectedSettingProvider);

        return Column(
          children: [
            _Toolbar(tune: tune, permission: permission),
            const Divider(height: 1),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final list = _MenuList(
                    scope: scope,
                    query: _query,
                    selected: selected,
                    onQueryChanged: (q) => setState(() => _query = q),
                    onSelect: (target) => _open(
                      context,
                      target,
                      wide: constraints.maxWidth >= 880,
                    ),
                  );

                  if (constraints.maxWidth < 880) return list;

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 300, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: selected == null
                            ? const _Message(
                                text: 'Choose a setting group on the left.',
                              )
                            : SettingDetail(
                                target: selected,
                                connection: widget.connection,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  void _open(BuildContext context, String target, {required bool wide}) {
    ref.read(selectedSettingProvider.notifier).state = target;
    if (wide) return;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(_titleFor(target))),
          body: SettingDetail(target: target, connection: widget.connection),
        ),
      ),
    );
  }

  String _titleFor(String target) {
    final definition = widget.connection.definition!;
    return definition.dialogNamed(target)?.title.ifNotEmpty ??
        definition.tableNamed(target)?.title ??
        definition.curveNamed(target)?.title ??
        target;
  }
}

extension on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}

/// Write mode, unsaved-change count and the Burn button.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.tune, required this.permission});

  final TuneState tune;
  final WritePermission permission;

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
        ],
      ),
    );
  }
}

/// The menu as the definition declares it, filtered by its own conditions.
class _MenuList extends StatelessWidget {
  const _MenuList({
    required this.scope,
    required this.query,
    required this.selected,
    required this.onQueryChanged,
    required this.onSelect,
  });

  final SettingsScope scope;
  final String query;
  final String? selected;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final needle = query.trim().toLowerCase();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: 'Search settings',
              border: OutlineInputBorder(),
            ),
            onChanged: onQueryChanged,
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (final menu in scope.definition.menus)
                ..._menuSection(context, menu, searching, needle),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _menuSection(
    BuildContext context,
    IniMenu menu,
    bool searching,
    String needle,
  ) {
    final entries = <Widget>[];

    void addLeaf(IniMenuItem item, {int indent = 0}) {
      // A menu entry whose condition is false describes hardware that is not
      // fitted or a mode that is not selected, so it is not offered - the
      // same as TunerStudio.
      if (!scope.test(item.condition)) return;
      final label = item.displayLabel.isEmpty ? item.target : item.displayLabel;
      if (searching && !label.toLowerCase().contains(needle)) return;

      entries.add(
        ListTile(
          dense: true,
          selected: selected == item.target,
          contentPadding: EdgeInsets.only(left: 16.0 + indent * 14, right: 12),
          title: Text(label, overflow: TextOverflow.ellipsis),
          trailing: item.isBuiltIn
              ? const Icon(Icons.block, size: 15)
              : _kindIcon(item.target),
          onTap: () => onSelect(item.target),
        ),
      );
    }

    for (final item in menu.items) {
      if (item.isSeparator) {
        if (!searching && entries.isNotEmpty) {
          entries.add(const Divider(height: 1, indent: 16));
        }
        continue;
      }
      if (item.isGroup) {
        if (!scope.test(item.condition)) continue;
        final before = entries.length;
        for (final child in item.children) {
          if (child.isSeparator) {
            // A rule between the group's own entries, where there are any
            // on both sides of it.
            if (!searching && entries.length > before) {
              entries.add(const Divider(height: 1, indent: 30));
            }
            continue;
          }
          addLeaf(child, indent: 1);
        }
        if (entries.length > before && !searching) {
          entries.insert(
            before,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 2),
              child: Text(
                item.displayLabel,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          );
        }
        continue;
      }
      addLeaf(item);
    }

    if (entries.isEmpty) return const [];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
        child: Text(
          menu.displayLabel.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ),
      ...entries,
    ];
  }

  Widget? _kindIcon(String target) =>
      switch (scope.definition.targetKind(target)) {
        IniTargetKind.table => const Icon(Icons.grid_on, size: 15),
        IniTargetKind.map => const Icon(Icons.view_in_ar_outlined, size: 15),
        IniTargetKind.curve => const Icon(Icons.show_chart, size: 15),
        IniTargetKind.unknown => const Icon(Icons.block, size: 15),
        _ => null,
      };
}

/// Whatever a menu entry points at: a dialog, a curve or a table.
class SettingDetail extends ConsumerWidget {
  const SettingDetail({
    super.key,
    required this.target,
    required this.connection,
  });

  /// The `subMenu` or `panel` target to show.
  final String target;

  final EcuConnected connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tune = ref.watch(tuneProvider).valueOrNull;
    final definition = connection.definition;
    if (tune == null || definition == null) {
      return const _Message(text: 'No tune loaded.');
    }

    final resolver = ref.watch(tuneResolverProvider) ?? TuneValueResolver(tune);
    final scope = SettingsScope(
      tune: tune,
      resolver: resolver,
      realtime: ref.watch(realtimeProvider).valueOrNull,
    );
    final editable = ref.watch(writePermissionProvider).allowed;
    final baseline = ref.watch(tuneBaselineProvider);

    void edited() => ref.read(tuneProvider.notifier).notifyEdited();

    void openTable(String tableId, {bool asSurface = false}) {
      final title = definition.tableNamed(tableId)?.title ?? tableId;
      if (!asSurface) {
        ref.read(selectedTableProvider.notifier).state = tableId;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(asSurface ? '$title - 3D' : title)),
            body: asSurface
                ? SurfaceScreen(connection: connection, tableId: tableId)
                : TableEditorScreen(connection: connection),
          ),
        ),
      );
    }

    switch (definition.targetKind(target)) {
      case IniTargetKind.dialog:
        final dialog = definition.dialogNamed(target)!;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (dialog.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    dialog.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              DialogView(
                dialog: dialog,
                scope: scope,
                editable: editable,
                onEdit: edited,
                onOpenTable: openTable,
                baselineTune: baseline,
              ),
              if (dialog.topicHelp case final url?) _HelpLink(url: url),
              if (dialog.webHelp case final url?) _HelpLink(url: url),
            ],
          ),
        );

      case IniTargetKind.curve:
        final curve = definition.curveNamed(target)!;
        final view = CurveView.of(tune, curve, resolver: resolver);
        if (view == null) {
          return _Message(text: '"${curve.title}" cannot be edited here.');
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          child: CurveEditor(
            view: view,
            editable: editable,
            onEdit: edited,
            baseline: baseline == null ? null : CurveView.of(baseline, curve),
            cursorX: view.xChannel == null
                ? null
                : scope.realtime?[view.xChannel!],
          ),
        );

      case IniTargetKind.table:
        return _OpenTablePane(
          title: definition.tableNamed(target)!.title,
          onOpen: () => openTable(target),
        );

      case IniTargetKind.map:
        final table = definition.tableForMap(target)!;
        return _OpenTablePane(
          title: table.title,
          asSurface: true,
          onOpen: () => openTable(table.id, asSurface: true),
        );

      case IniTargetKind.builtIn:
        return const _Message(
          text:
              'This is one of TunerStudio\'s own editors - a sensor '
              'calibration wizard or the SD card browser. It lives in '
              'TunerStudio rather than in the ECU definition, so there is '
              'nothing here to generate a screen from.',
        );

      case IniTargetKind.unknown:
        return _Message(text: 'The definition does not describe "$target".');
    }
  }
}

class _OpenTablePane extends StatelessWidget {
  const _OpenTablePane({
    required this.title,
    required this.onOpen,
    this.asSurface = false,
  });

  final String title;
  final VoidCallback onOpen;
  final bool asSurface;

  @override
  Widget build(BuildContext context) => Center(
    child: FilledButton.icon(
      onPressed: onOpen,
      icon: Icon(asSurface ? Icons.view_in_ar_outlined : Icons.grid_on),
      label: Text(asSurface ? 'Open $title in 3D' : 'Open $title'),
    ),
  );
}

class _HelpLink extends StatelessWidget {
  const _HelpLink({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SelectableText(
        url,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
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
