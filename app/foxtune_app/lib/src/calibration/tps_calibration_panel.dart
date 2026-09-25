import 'package:flutter/material.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../settings/setting_field.dart';
import '../settings/settings_scope.dart';

/// Setting the throttle position sensor's closed and wide-open readings from
/// the sensor itself.
///
/// TunerStudio offers this from its Tools menu without the definition
/// describing it: Speeduino's keeps the two readings as `tpsMin` and
/// `tpsMax`, in no dialog at all, beside the live `tpsADC`. So FoxTune puts
/// its own in the same menu, where both are stored in the live reading's
/// units and one can simply be copied into the other - or typed in.
///
/// They go into the tune like any other change, and are burned with it.
class TpsCalibrationPanel extends StatefulWidget {
  const TpsCalibrationPanel({
    super.key,
    required this.scope,
    required this.editable,
    required this.onEdit,
  });

  /// The menu target FoxTune gives this panel - one no definition uses.
  static const target = 'foxtune_tps';

  static const title = 'Calibrate Throttle Position Sensor';

  static const _live = 'tpsADC';
  static const _closed = 'tpsMin';
  static const _open = 'tpsMax';

  /// Whether [definition] keeps the readings as settings in the same units as
  /// the live reading, so they can be set from it.
  ///
  /// rusEFI keeps volts where its live reading is in ADC counts, and
  /// calibrates with buttons of its own, so it is left to those.
  static bool availableFor(IniDocument definition) {
    final live = definition.outputChannels.channelNamed(_live);
    if (live is! IniScalarField) return false;
    final units = live.units.trim().toLowerCase();
    for (final name in const [_closed, _open]) {
      final field = definition.constants.findField(name)?.field;
      if (field is! IniScalarField ||
          field.units.trim().toLowerCase() != units) {
        return false;
      }
    }
    return true;
  }

  final SettingsScope scope;
  final bool editable;
  final VoidCallback onEdit;

  @override
  State<TpsCalibrationPanel> createState() => _TpsCalibrationPanelState();
}

class _TpsCalibrationPanelState extends State<TpsCalibrationPanel> {
  /// Readings taken into each setting so far, by name.
  ///
  /// Part of its field's key, so taking a reading starts the field afresh
  /// with it. A field commits what is typed into it when it loses focus, and
  /// pressing the button does not take the focus away - so without this,
  /// half-typed text would land on top of the reading as soon as it did.
  final _taken = <String, int>{};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = widget.scope;
    final closed = scope.setting(TpsCalibrationPanel._closed);
    final open = scope.setting(TpsCalibrationPanel._open);
    if (closed == null || open == null) {
      return const Text('This definition has no throttle calibration.');
    }
    final reading = scope.realtime?[TpsCalibrationPanel._live];
    final percent = scope.realtime?['TPS'];

    Widget row(String label, SettingView setting) {
      final field = SettingFieldTile(
        key: ValueKey((setting.name, _taken[setting.name] ?? 0)),
        label: label,
        setting: setting,
        enabled: widget.editable,
        onChanged: widget.onEdit,
      );
      final take = FilledButton.tonal(
        onPressed: widget.editable && reading != null
            ? () {
                setting.setValue(reading);
                setState(
                  () => _taken.update(
                    setting.name,
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  ),
                );
                widget.onEdit();
              }
            : null,
        child: const Text('Use the reading'),
      );
      // Beside the field where there is room, and under it on a phone.
      return LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth < 520
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field,
                  Align(alignment: Alignment.centerRight, child: take),
                  const SizedBox(height: 8),
                ],
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  // Level with the entry box, not with the box and the bounds
                  // under it.
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: field),
                    const SizedBox(width: 12),
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: take,
                    ),
                  ],
                ),
              ),
      );
    }

    final low = closed.value;
    final high = open.value;
    const howTo =
        'Set the closed reading with the throttle closed, and the other with '
        'it held wide open.';
    final String? note = switch ((low, high)) {
      (final double a, final double b) when a == b =>
        'Closed and wide open read the same. $howTo',
      (final double a, final double b) when (a - b).abs() < 20 =>
        'The two readings are only ${(a - b).abs().round()} apart. $howTo',
      (final double a, final double b) when a > b =>
        'Wide open reads lower than closed, which Speeduino takes as a '
            'sensor wired the other way round - and handles.',
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(TpsCalibrationPanel.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'With the engine off, leave the throttle closed and use the '
          'reading for closed; then hold it wide open and use the reading '
          'for wide open. Either can be typed in instead. Both are changes '
          'to the tune: burn them to keep them.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Text('Sensor reading now')),
            Text(
              reading == null ? '--' : reading.round().toString(),
              style: theme.textTheme.headlineSmall,
            ),
            if (percent != null) ...[
              const SizedBox(width: 12),
              Text(
                '${percent.round()} %',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        if (reading == null)
          Text(
            'Waiting for live data from the ECU.',
            style: theme.textTheme.bodySmall,
          ),
        const Divider(height: 24),
        row('Closed throttle', closed),
        row('Wide open throttle', open),
        if (note != null) ...[
          const SizedBox(height: 8),
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: StatusPalette.warning,
            ),
          ),
        ],
      ],
    );
  }
}
