import 'package:flutter/material.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import 'setting_field.dart';
import 'settings_scope.dart';

/// Panels TunerStudio draws itself, which a definition names but does not
/// describe.
///
/// Everything else on a settings screen is generated from the `.ini`. A
/// `panel = std_*` line is the exception: it tells TunerStudio to put one of
/// its own built-in panels there, and the definition has nothing to say about
/// what is in it. Speeduino's Engine Constants embeds `std_injection`, and
/// that panel is the only place nine core settings - required fuel and the
/// cylinder count among them - can be edited at all. So the few that matter
/// are built by hand here, and nowhere else is.
///
/// Each one is still made of ordinary constants from `[Constants]`, rendered
/// with the same controls as a generated dialog, so bounds, option labels and
/// help text still come from the definition.
abstract final class BuiltInPanels {
  /// Built-in panels FoxTune can draw, by identifier.
  static const supported = {'std_injection'};

  /// Built-in panels left out on purpose, and why.
  ///
  /// Each is one that holds no tune settings - so nothing becomes impossible
  /// to edit by leaving it out - and does something FoxTune will not do
  /// untested. A built-in panel in neither list is one nobody has looked at,
  /// and a test fails until someone does.
  static const unsupported = {
    'std_ms3Rtc':
        'Setting the ECU clock is not supported yet. It sends a '
        'command to the ECU rather than changing the tune, and has not been '
        'tried against hardware.',
  };

  /// Draws the built-in panel [id], or returns `null` if it is not one FoxTune
  /// knows.
  static Widget? build(
    String id, {
    required SettingsScope scope,
    required bool editable,
    required VoidCallback onEdit,
  }) => switch (id) {
    'std_injection' => InjectionPanel(
      scope: scope,
      editable: editable,
      onEdit: onEdit,
    ),
    _ => null,
  };
}

/// TunerStudio's standard injection panel.
///
/// Matches TunerStudio's field order, so a tuner moving between the two finds
/// things where they expect.
class InjectionPanel extends StatelessWidget {
  const InjectionPanel({
    super.key,
    required this.scope,
    required this.editable,
    required this.onEdit,
  });

  final SettingsScope scope;
  final bool editable;
  final VoidCallback onEdit;

  /// Constants the panel edits, with the labels TunerStudio gives them.
  static const fields = [
    ('reqFuel', 'Required fuel'),
    ('algorithm', 'Fuel load source'),
    ('divider', 'Squirts per engine cycle'),
    ('alternate', 'Injector staging'),
    ('twoStroke', 'Engine stroke'),
    ('nCylinders', 'Number of cylinders'),
    ('injType', 'Injector port type'),
    ('nInjectors', 'Number of injectors'),
    ('engineType', 'Engine type'),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final (constant, label) in fields) {
      final setting = scope.setting(constant);
      // Another firmware's definition may lack some of these. The panel shows
      // what exists rather than failing over what does not.
      if (setting == null) continue;

      rows.add(
        constant == 'divider'
            ? _SquirtsField(
                label: label,
                divider: setting,
                scope: scope,
                enabled: editable,
                onChanged: onEdit,
              )
            : SettingFieldTile(
                label: label,
                setting: setting,
                enabled: editable,
                onChanged: onEdit,
              ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Injection', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          ...rows,
        ],
      ),
    );
  }
}

/// Squirt counts that divide [cylinders] evenly.
///
/// The firmware computes squirts as `nCylinders / divider` in integer
/// arithmetic, so only an even division means what it appears to: `divider`
/// 3 on a four-cylinder is one squirt, not one and a third.
@visibleForTesting
List<int> squirtOptions(int cylinders) => [
  for (var squirts = 1; squirts <= cylinders; squirts++)
    if (cylinders % squirts == 0) squirts,
];

/// The squirt count [divider] stands for, or `null` if it does not divide
/// [cylinders] evenly.
@visibleForTesting
int? squirtsFor(int cylinders, int divider) {
  if (cylinders <= 0 || divider <= 0 || cylinders % divider != 0) return null;
  return cylinders ~/ divider;
}

/// "Squirts per engine cycle", which the firmware stores the other way up.
///
/// `divider` holds *cylinders per squirt*: the firmware works out
/// `nSquirts = nCylinders / divider`. Offered as a plain number it would read
/// backwards to anyone used to TunerStudio, and accept values that silently
/// round to something else. So this offers squirt counts - only the ones that
/// divide the cylinder count evenly - and stores the matching divider.
class _SquirtsField extends StatelessWidget {
  const _SquirtsField({
    required this.label,
    required this.divider,
    required this.scope,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final SettingView divider;
  final SettingsScope scope;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cylinders = int.tryParse(
      scope.setting('nCylinders')?.optionLabel ?? '',
    );
    final stored = divider.value?.round();
    final current = cylinders == null || stored == null
        ? null
        : squirtsFor(cylinders, stored);

    // The firmware overrides the setting outright for a four-stroke engine
    // running sequential: one squirt per cycle, whatever is stored.
    final sequential =
        scope.setting('injLayout')?.optionLabel?.toLowerCase() == 'sequential';
    final fourStroke =
        scope.setting('twoStroke')?.optionLabel?.toLowerCase() != 'two-stroke';
    final overridden = sequential && fourStroke;

    final String? note = switch ((cylinders, current, overridden)) {
      (null, _, _) => 'Set the number of cylinders first.',
      (_, _, true) =>
        'Ignored while injection is sequential: the ECU squirts once per '
            'cycle.',
      (final int n, null, _) when stored != null && stored != 0 =>
        'The stored value does not divide evenly into $n cylinders - '
            'choose again.',
      _ => null,
    };

    final control = cylinders == null
        ? const Text('--')
        : DropdownButtonFormField<int>(
            // Keyed on what it depends on, so a change of cylinder count
            // rebuilds the choices instead of asserting over a stale one.
            key: ValueKey((cylinders, current)),
            initialValue: current,
            hint: const Text('Choose...'),
            isDense: true,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            items: [
              for (final squirts in squirtOptions(cylinders))
                DropdownMenuItem(value: squirts, child: Text('$squirts')),
            ],
            onChanged: enabled && !overridden
                ? (squirts) {
                    if (squirts == null) return;
                    divider.setValue((cylinders ~/ squirts).toDouble());
                    onChanged();
                  }
                : null,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SettingLabel(
                  label: label,
                  setting: divider,
                  enabled: enabled && !overridden,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(width: 186, child: control),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: current == null && !overridden && cylinders != null
                      ? StatusPalette.warning
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
