import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show kSpeeduinoBaudRate;
import 'package:foxtune_transport/foxtune_transport.dart'
    show kDelayAfterPortOpen;

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../definitions/definition_library.dart';
import '../definitions/definitions_screen.dart';
import '../files/file_saving.dart';
import '../storage/json_store.dart';
import '../window/window_app_bar.dart';
import 'app_settings.dart';
import 'wallpaper.dart';

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
                const _WallpaperSettings(),
                const _Heading('Connection'),
                _Picked<int>(
                  title: 'Baud rate',
                  explanation:
                      "The speed a USB or Bluetooth serial link runs at, which "
                      "has to be the ECU's own. Speeduino talks at 115200 over "
                      'USB; a Bluetooth module is often set slower. A network '
                      'bridge sets its own, so this does not apply to it.',
                  value: settings.baudRate,
                  choices: AppSettings.baudRates,
                  label: (rate) => rate == kSpeeduinoBaudRate
                      ? '$rate (Speeduino)'
                      : '$rate',
                  note: connected ? 'applies from the next connection' : null,
                  onChanged: (rate) =>
                      controller.update((s) => s.copyWith(baudRate: rate)),
                ),
                _Picked<Duration>(
                  title: 'Wait after opening a port',
                  explanation:
                      'An Arduino Mega restarts as its port opens, and answers '
                      'about a second later - talking to it sooner gets no '
                      'reply. Boards that do not restart, such as a Teensy, an '
                      'STM32 or a rusEFI, connect sooner without the wait.',
                  value: settings.delayAfterOpen,
                  choices: AppSettings.delaysAfterOpen,
                  label: _describeWait,
                  note: connected ? 'applies from the next connection' : null,
                  onChanged: (wait) => controller.update(
                    (s) => s.copyWith(delayAfterOpen: wait),
                  ),
                ),
                _Picked<int>(
                  title: 'Live data rate',
                  explanation:
                      'How many times a second live data is read, at most. A '
                      "slow link manages what it can; a lower rate spares a "
                      "phone's battery.",
                  value: settings.liveDataRate,
                  choices: AppSettings.liveDataRates,
                  label: (rate) => '$rate times a second',
                  onChanged: (rate) =>
                      controller.update((s) => s.copyWith(liveDataRate: rate)),
                ),
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

/// The wallpaper: which one, how an image is laid out, how strongly it shows
/// - and a preview of the result.
class _WallpaperSettings extends ConsumerStatefulWidget {
  const _WallpaperSettings();

  @override
  ConsumerState<_WallpaperSettings> createState() => _WallpaperSettingsState();
}

class _WallpaperSettingsState extends ConsumerState<_WallpaperSettings> {
  /// The strength while the slider is being dragged. The preview follows it;
  /// the setting is saved once the slider is let go, rather than with every
  /// step of the drag.
  double? _dragging;

  void _change(Wallpaper Function(Wallpaper current) change) => ref
      .read(appSettingsProvider.notifier)
      .update((s) => s.copyWith(wallpaper: change(s.wallpaper)));

  /// Asks for an image, keeps a copy of it and shows it.
  Future<void> _chooseImage() async {
    final messenger = ScaffoldMessenger.of(context);
    void complain(String message) => messenger.showSnackBar(
      SnackBar(content: Text(message), backgroundColor: StatusPalette.critical),
    );

    final PickedFile? picked;
    try {
      picked = await ref
          .read(fileSavingProvider)
          .pickFile(
            extensions: wallpaperImageExtensions,
            dialogTitle: 'Choose a wallpaper',
          );
    } on WrongFileTypeException catch (error) {
      complain(error.message);
      return;
    } on Object catch (error) {
      complain('Could not open a file: $error');
      return;
    }
    if (picked == null) return;
    if (!looksLikeImage(picked.bytes)) {
      complain('${picked.name} is not an image FoxTune can show.');
      return;
    }

    final name = picked.name;
    try {
      final root = await ref.read(appStorageDirectoryProvider.future);
      final kept = keepWallpaperImage(
        root,
        picked,
        replacing: ref.read(appSettingsProvider).wallpaper.image,
      );
      _change(
        (w) => w.copyWith(
          kind: WallpaperKind.image,
          image: kept.path,
          imageName: name,
        ),
      );
    } on Object catch (error) {
      complain('Could not keep the image: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wallpaper = ref.watch(appSettingsProvider.select((s) => s.wallpaper));
    final shown = wallpaper.copyWith(strength: _dragging);
    final percent = '${(shown.strength * 100).round()}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Choice<WallpaperKind>(
          title: 'Wallpaper',
          detail: 'Drawn behind the main screen.',
          selected: wallpaper.kind,
          choices: const {
            WallpaperKind.none: 'None',
            WallpaperKind.branding: 'FoxTune',
            WallpaperKind.image: 'Image',
          },
          onChanged: (kind) {
            // With no image yet, choosing one comes first - and the wallpaper
            // changes only once there is one to show.
            if (kind == WallpaperKind.image && wallpaper.image == null) {
              _chooseImage();
            } else {
              _change((w) => w.copyWith(kind: kind));
            }
          },
        ),
        if (wallpaper.kind == WallpaperKind.image) ...[
          ListTile(
            title: const Text('Image'),
            subtitle: Text(
              wallpaper.imageName ?? 'Chosen image',
              overflow: TextOverflow.ellipsis,
            ),
            trailing: OutlinedButton(
              onPressed: _chooseImage,
              child: const Text('Choose...'),
            ),
          ),
          _Choice<WallpaperFit>(
            title: 'Layout',
            selected: wallpaper.fit,
            choices: {for (final fit in WallpaperFit.values) fit: fit.label},
            onChanged: (fit) => _change((w) => w.copyWith(fit: fit)),
          ),
          _Position(
            selected: wallpaper.alignment,
            onChanged: (alignment) =>
                _change((w) => w.copyWith(alignment: alignment)),
          ),
        ],
        if (wallpaper.kind != WallpaperKind.none) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Text('Strength', style: theme.textTheme.bodyLarge),
                Expanded(
                  child: Slider(
                    value: shown.strength,
                    divisions: 20,
                    label: percent,
                    onChanged: (strength) =>
                        setState(() => _dragging = strength),
                    onChangeEnd: (strength) {
                      setState(() => _dragging = null);
                      _change((w) => w.copyWith(strength: strength));
                    },
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(percent, textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'It is faded into the background colour rather than darkened, '
              'so what sits on it stays readable in the light theme as in '
              'the dark.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _Preview(wallpaper: shown),
        ],
      ],
    );
  }
}

/// Where a wallpaper image is anchored, from a grid of the nine places.
class _Position extends StatelessWidget {
  const _Position({required this.selected, required this.onChanged});

  final Alignment selected;
  final ValueChanged<Alignment> onChanged;

  static const _rows = [
    [
      (Alignment.topLeft, 'Top left'),
      (Alignment.topCenter, 'Top'),
      (Alignment.topRight, 'Top right'),
    ],
    [
      (Alignment.centerLeft, 'Left'),
      (Alignment.center, 'Centre'),
      (Alignment.centerRight, 'Right'),
    ],
    [
      (Alignment.bottomLeft, 'Bottom left'),
      (Alignment.bottomCenter, 'Bottom'),
      (Alignment.bottomRight, 'Bottom right'),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Position', style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  'Where the image sits - or, where it is cropped, which '
                  'part of it is kept.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in _rows)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (alignment, name) in row)
                      IconButton(
                        tooltip: name,
                        isSelected: alignment == selected,
                        icon: const Icon(Icons.crop_square),
                        selectedIcon: const Icon(Icons.square_rounded),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => onChanged(alignment),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// [wallpaper] as the main screen would show it, with text on it to judge
/// by - and shaped like the window, so a fill or a fit crops as it will there.
class _Preview extends StatelessWidget {
  const _Preview({required this.wallpaper});

  final Wallpaper wallpaper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = MediaQuery.sizeOf(context);
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          height: 180,
          child: AspectRatio(
            aspectRatio: window.height > 0 ? window.width / window.height : 1,
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      WallpaperView(wallpaper: wallpaper),
                      Center(
                        child: Text(
                          'Text on the wallpaper',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _describeWait(Duration wait) {
  if (wait == Duration.zero) return 'None';
  final ms = wait.inMilliseconds;
  final seconds = ms % 1000 == 0 ? '${ms ~/ 1000}' : '${ms / 1000}';
  return wait == kDelayAfterPortOpen
      ? '$seconds s (Arduino Mega)'
      : '$seconds s';
}

/// A setting picked from a list of [choices], shown with the one in force.
class _Picked<T> extends StatelessWidget {
  const _Picked({
    required this.title,
    required this.explanation,
    required this.value,
    required this.choices,
    required this.label,
    required this.onChanged,
    this.note,
  });

  final String title;

  /// What the setting does, said where it is chosen.
  final String explanation;

  final T value;
  final List<T> choices;
  final String Function(T choice) label;
  final ValueChanged<T> onChanged;

  /// Said after the value in force, where there is something to say.
  final String? note;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text([label(value), ?note].join(' - ')),
    onTap: () async {
      final picked = await showDialog<T>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(title),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                explanation,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            RadioGroup<T>(
              groupValue: value,
              onChanged: (choice) => Navigator.of(context).pop(choice),
              child: Column(
                children: [
                  for (final choice in choices)
                    RadioListTile<T>(value: choice, title: Text(label(choice))),
                ],
              ),
            ),
          ],
        ),
      );
      if (picked != null) onChanged(picked);
    },
  );
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
