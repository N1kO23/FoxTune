import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../definitions/definition_library.dart';
import '../definitions/definitions_screen.dart';
import '../window/window_app_bar.dart';
import 'app_settings.dart';

/// FoxTune's own settings, as against the ECU's in the Settings tab - and the
/// way to the ECU definitions it has.
class AppSettingsScreen extends ConsumerWidget {
  const AppSettingsScreen({super.key});

  /// Opens the settings over [context].
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const AppSettingsScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final connected = ref.watch(connectionProvider) is EcuConnected;

    return Scaffold(
      appBar: const WindowAppBar(title: Text('App settings')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                const _Heading('Display'),
                _Choice<ThemeMode>(
                  title: 'Theme',
                  selected: settings.themeMode,
                  choices: const {
                    ThemeMode.system: 'System',
                    ThemeMode.light: 'Light',
                    ThemeMode.dark: 'Dark',
                  },
                  onChanged: (mode) =>
                      controller.update((s) => s.copyWith(themeMode: mode)),
                ),
                _Choice<TemperatureUnit>(
                  title: 'Temperature',
                  detail: [
                    'Speeduino definitions offer both scales; rusEFI always '
                        'uses °C. Gauge limits you have set, and tunes loaded '
                        'from .msq files, are converted.',
                    if (connected) 'Applies from the next connection.',
                  ].join(' '),
                  selected: settings.temperatureUnit,
                  choices: {
                    for (final unit in TemperatureUnit.values)
                      unit: unit.symbol,
                  },
                  onChanged: (unit) => controller.update(
                    (s) => s.copyWith(temperatureUnit: unit),
                  ),
                ),
                const _Heading('Connection'),
                SwitchListTile(
                  title: const Text('Keep the screen on while connected'),
                  subtitle: const Text(
                    'So gauges stay in sight, and logging is not slowed once '
                    'the screen would have turned off.',
                  ),
                  value: settings.keepScreenOn,
                  onChanged: (on) =>
                      controller.update((s) => s.copyWith(keepScreenOn: on)),
                ),
                SwitchListTile(
                  title: const Text('Download definitions automatically'),
                  subtitle: const Text(
                    'When none on this device matches the ECU, fetch the one '
                    'rusefi.com or speeduino.com publishes for its exact '
                    'build.',
                  ),
                  value: settings.downloadDefinitions,
                  onChanged: (on) => controller.update(
                    (s) => s.copyWith(downloadDefinitions: on),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('ECU definitions'),
                  subtitle: Text(
                    ref
                        .watch(definitionEntriesProvider)
                        .when(
                          data: (entries) {
                            final kept = entries
                                .where((e) => !e.isBuiltIn)
                                .length;
                            return '${entries.length - kept} built in, '
                                '$kept on this device';
                          },
                          loading: () => 'Built in, and kept on this device',
                          error: (error, _) => 'Could not list them: $error',
                        ),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => DefinitionsScreen.open(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// A setting chosen from a few [choices], with the buttons under its title so
/// they fit a phone held upright.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.selected,
    required this.choices,
    required this.onChanged,
    this.detail,
  });

  final String title;
  final String? detail;
  final T selected;

  /// Each choice, and its label.
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodyLarge),
          if (detail case final detail?) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          SegmentedButton<T>(
            segments: [
              for (final MapEntry(key: value, value: label) in choices.entries)
                ButtonSegment(value: value, label: Text(label)),
            ],
            selected: {selected},
            showSelectedIcon: false,
            onSelectionChanged: (picked) => onChanged(picked.single),
          ),
        ],
      ),
    );
  }
}
