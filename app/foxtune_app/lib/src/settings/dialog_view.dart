import 'package:flutter/material.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/stat_tile.dart' show FlagLamp;
import 'builtin_panels.dart';
import 'curve_editor.dart';
import 'setting_field.dart';
import 'settings_scope.dart';

/// How a table or curve reached from a settings screen should be opened.
typedef OpenTableCallback = void Function(String tableId, {bool asSurface});

/// Renders one `[UserDefined]` dialog.
///
/// The definition describes 240 of these, which is why they are generated
/// rather than written: hand-building them would be a week's work that went
/// stale on the next firmware release. Everything here is driven by the
/// dialog's own declaration - which control a field gets, when it is greyed
/// out, what is nested inside what.
class DialogView extends StatelessWidget {
  const DialogView({
    super.key,
    required this.dialog,
    required this.scope,
    required this.editable,
    required this.onEdit,
    required this.onOpenTable,
    this.baselineTune,
    this.depth = 0,
    this.visited = const {},
  });

  /// The dialog to render.
  final IniDialog dialog;

  /// The tune, resolver and realtime feed behind it.
  final SettingsScope scope;

  /// Whether the session may change anything.
  final bool editable;

  /// Called after any edit lands.
  final VoidCallback onEdit;

  /// Opens a table or its 3D view.
  final OpenTableCallback onOpenTable;

  /// The tune as last synchronised with the ECU, for marking changes.
  final TuneState? baselineTune;

  /// Nesting depth, so a pathological definition cannot recurse forever.
  final int depth;

  /// Dialog ids already on the stack above this one.
  final Set<String> visited;

  static const _maxDepth = 8;

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final item in dialog.items)
        if (scope.isVisible(item)) item,
    ];

    final body = dialog.isBorderLayout
        ? _BorderLayout(children: _placed(context, items))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final item in items) _build(context, item)],
          );

    if (depth == 0 || dialog.title.isEmpty) return body;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dialog.title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }

  /// Groups children by the compass position a `border` dialog gave them.
  Map<String, List<Widget>> _placed(
    BuildContext context,
    List<IniDialogItem> items,
  ) {
    final placed = <String, List<Widget>>{};
    for (final item in items) {
      final position = item is IniDialogPanel
          ? (item.position ?? 'Center').toLowerCase()
          : 'center';
      (placed[position] ??= []).add(_build(context, item));
    }
    return placed;
  }

  Widget _build(BuildContext context, IniDialogItem item) {
    final enabled = editable && scope.isEnabled(item);

    return switch (item) {
      IniDialogField() => _field(context, item, enabled),
      IniDialogPanel() => _panel(context, item),
      IniDialogSlider() => _slider(item, enabled),
      IniDialogCommandButton() => _commandButton(context, item),
      IniDialogIndicator() => _indicator(item),
      IniDialogText() => _prose(context, item.text, IniFieldEmphasis.none),
      IniDialogSettingSelector() => _selector(context, item, enabled),
      IniDialogGauge() => _elsewhere(context, 'Live gauge - see the Dashboard'),
      IniDialogLiveGraph() => _elsewhere(
        context,
        'Live graph - see the Dashboard',
      ),
    };
  }

  Widget _field(BuildContext context, IniDialogField field, bool enabled) {
    if (field.isSpacer) return const SizedBox(height: 14);

    final constant = field.constant;
    if (constant == null) return _prose(context, field.label, field.emphasis);

    final setting = scope.setting(constant);
    if (setting == null) {
      // A constant the field model does not cover - the aux-channel aliases
      // are text, which the ECU does not store as a number. Saying so beats
      // leaving a gap the tuner cannot account for.
      return _unsupported(context, '${field.label} ($constant)');
    }

    return SettingFieldTile(
      label: field.label,
      setting: setting,
      enabled: enabled,
      readOnly: field.readOnly,
      onChanged: onEdit,
    );
  }

  Widget _slider(IniDialogSlider slider, bool enabled) {
    final setting = scope.setting(slider.constant);
    if (setting == null) return const SizedBox.shrink();
    return SettingSliderTile(
      label: slider.label,
      setting: setting,
      enabled: enabled,
      onChanged: onEdit,
    );
  }

  Widget _panel(BuildContext context, IniDialogPanel panel) {
    final definition = scope.definition;

    switch (definition.targetKind(panel.target)) {
      case IniTargetKind.dialog:
        final nested = definition.dialogNamed(panel.target)!;
        if (depth >= _maxDepth || visited.contains(nested.id)) {
          return _unsupported(context, 'Nested too deeply: ${nested.id}');
        }
        return DialogView(
          dialog: nested,
          scope: scope,
          editable: editable,
          onEdit: onEdit,
          onOpenTable: onOpenTable,
          baselineTune: baselineTune,
          depth: depth + 1,
          visited: {...visited, dialog.id},
        );

      case IniTargetKind.curve:
        final curve = definition.curveNamed(panel.target)!;
        final view = CurveView.of(scope.tune, curve, resolver: scope.resolver);
        if (view == null) {
          return _unsupported(context, 'Curve ${curve.title}');
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: CurveEditor(
            view: view,
            editable: editable,
            onEdit: onEdit,
            baseline: _baselineCurve(curve),
            cursorX: _channel(view.xChannel),
          ),
        );

      case IniTargetKind.table:
        return _tableLink(context, panel.target, asSurface: false);

      case IniTargetKind.map:
        final table = definition.tableForMap(panel.target)!;
        return _tableLink(context, table.id, asSurface: true);

      case IniTargetKind.builtIn:
        final built = BuiltInPanels.build(
          panel.target,
          scope: scope,
          editable: editable,
          onEdit: onEdit,
        );
        if (built != null) return built;
        final reason = BuiltInPanels.unsupported[panel.target];
        return reason == null
            ? _unsupported(context, panel.target)
            : _explained(context, reason);

      case IniTargetKind.unknown:
        return _unsupported(context, panel.target);
    }
  }

  CurveView? _baselineCurve(IniCurve curve) {
    final tune = baselineTune;
    if (tune == null) return null;
    return CurveView.of(tune, curve);
  }

  double? _channel(String? name) => name == null ? null : scope.realtime?[name];

  Widget _tableLink(
    BuildContext context,
    String tableId, {
    required bool asSurface,
  }) {
    final table = scope.definition.tableNamed(tableId);
    if (table == null) return _unsupported(context, tableId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: OutlinedButton.icon(
        onPressed: () => onOpenTable(tableId, asSurface: asSurface),
        icon: Icon(asSurface ? Icons.view_in_ar_outlined : Icons.grid_on),
        label: Text('Open ${table.title}'),
      ),
    );
  }

  Widget _commandButton(BuildContext context, IniDialogCommandButton button) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Tooltip(
        // These fire actions at the ECU - several start a calibration - and
        // FoxTune has not been able to test one against hardware. Shipping an
        // untested write path is not worth the completeness.
        message:
            'Commands are not supported yet: "${button.command}" would '
            'be sent to the ECU.',
        child: FilledButton.tonal(onPressed: null, child: Text(button.label)),
      ),
    );
  }

  Widget _indicator(IniDialogIndicator lamp) {
    final value = CompiledExpression.tryCompile(lamp.expression)
        ?.evaluate(scope.resolve);
    final on = value == null ? null : value != 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FlagLamp(
          label: on ?? false ? lamp.onLabel : lamp.offLabel,
          on: on,
        ),
      ),
    );
  }

  Widget _selector(
    BuildContext context,
    IniDialogSettingSelector selector,
    bool enabled,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(selector.label)),
          const SizedBox(width: 12),
          SizedBox(
            width: 186,
            child: DropdownButtonFormField<IniSettingPreset>(
              isDense: true,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Choose...',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: [
                for (final option in selector.options)
                  DropdownMenuItem(
                    value: option,
                    child: Text(option.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: enabled
                  ? (option) {
                      if (option == null) return;
                      // One preset writes several constants at once, which is
                      // the whole point: picking a sensor should not mean
                      // looking its two calibration numbers up by hand.
                      for (final entry in option.assignments.entries) {
                        scope.setting(entry.key)?.setValue(entry.value);
                      }
                      onEdit();
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _prose(BuildContext context, String text, IniFieldEmphasis emphasis) {
    if (text.isEmpty) return const SizedBox(height: 14);

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = switch (emphasis) {
      IniFieldEmphasis.warning => theme.textTheme.bodyMedium?.copyWith(
        color: scheme.error,
      ),
      IniFieldEmphasis.note => theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      IniFieldEmphasis.none => theme.textTheme.bodySmall?.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (emphasis == IniFieldEmphasis.warning) ...[
            Icon(Icons.warning_amber_rounded, size: 16, color: scheme.error),
            const SizedBox(width: 6),
          ],
          Expanded(child: Text(_plain(text), style: style)),
        ],
      ),
    );
  }

  /// Strips the simple HTML the definition uses in its help prose.
  static String _plain(String text) =>
      text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n').trim();

  /// Something left out on purpose, with the reason why.
  Widget _explained(BuildContext context, String reason) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.block,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _elsewhere(BuildContext context, String what) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.open_in_new,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            what,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _unsupported(BuildContext context, String what) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            Icons.block,
            size: 15,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$what is not supported yet',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Places a `border` dialog's regions.
///
/// Wide enough, West / Center / East sit side by side as the definition
/// intends; narrower, everything stacks in reading order rather than being
/// squeezed into unusable columns.
class _BorderLayout extends StatelessWidget {
  const _BorderLayout({required this.children});

  final Map<String, List<Widget>> children;

  static const _order = ['north', 'west', 'center', 'east', 'south'];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final middle = ['west', 'center', 'east'];
        final wide =
            constraints.maxWidth >= 900 &&
            middle.where(children.containsKey).length > 1;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...?children['north'],
            if (wide)
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final position in middle)
                      if (children[position] case final region?)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: region,
                            ),
                          ),
                        ),
                  ],
                ),
              )
            else
              for (final position in middle) ...?children[position],
            ...?children['south'],
            // Anything the definition placed somewhere unexpected still has
            // to appear rather than vanish.
            for (final entry in children.entries)
              if (!_order.contains(entry.key)) ...entry.value,
          ],
        );
      },
    );
  }
}
