import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/bar_gauge.dart';
import '../dashboard/gauge_status.dart';
import '../dashboard/meter_gauge.dart';
import '../dashboard/stat_tile.dart';
import '../motion/demo_drive.dart';
import '../window/window_app_bar.dart';
import 'app_settings.dart';
import 'motion_settings.dart';

/// Where FoxTune's animations and effects are switched on and off, over a
/// little live preview to judge them by.
///
/// Every change shows at once, and is saved as it is made.
class MotionScreen extends ConsumerWidget {
  const MotionScreen({super.key});

  /// Opens it over [context].
  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const MotionScreen()));

  /// What [motion] has on, in a few words: for the App settings entry.
  static String summary(MotionSettings motion) {
    if (motion.allOn) return 'All on';
    if (motion.allOff) return 'Off';
    return [
      if (motion.liveData) 'Smooth live data',
      if (motion.transitions) 'Transitions',
      if (motion.glow) 'Glow',
    ].join(', ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final motion = ref.watch(appSettingsProvider.select((s) => s.motion));
    void update(MotionSettings next) => ref
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(motion: next));
    final reduced = MediaQuery.disableAnimationsOf(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Motion & effects')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'How lively FoxTune is. Readings, alarms and everything '
                    'you enter are never held back by any of this - only how '
                    'things move on the way there.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const _Preview(),
                if (reduced)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(
                          Icons.motion_photos_off_outlined,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Your system asks for reduced motion, so nothing '
                            'moves whatever is set here. Glow still shows.',
                            style: muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                SwitchListTile(
                  title: const Text('Smooth live data'),
                  subtitle: const Text(
                    "Dials, bars and the table's live marker glide between "
                    'readings, lamps fade, and graphs scroll smoothly. The '
                    'glide never holds back a number.',
                  ),
                  value: motion.liveData,
                  onChanged: (on) => update(motion.copyWith(liveData: on)),
                ),
                SwitchListTile(
                  title: const Text('Calm readouts'),
                  subtitle: const Text(
                    'Numbers change about 10 times a second, so they can be '
                    'read at high data rates. Needles, bars and alarms still '
                    'follow every reading.',
                  ),
                  value: motion.calmReadouts,
                  onChanged: (on) => update(motion.copyWith(calmReadouts: on)),
                ),
                SwitchListTile(
                  title: const Text('Transitions'),
                  subtitle: const Text(
                    'Tabs, dashboard pages and screens fade as they change, '
                    'and gauges ease in when a page opens.',
                  ),
                  value: motion.transitions,
                  onChanged: (on) => update(motion.copyWith(transitions: on)),
                ),
                SwitchListTile(
                  title: const Text('Glow'),
                  subtitle: const Text(
                    'A soft glow under live readings, and on buttons under '
                    "the pointer. The Grid wallpaper's glow drifts slowly.",
                  ),
                  value: motion.glow,
                  onChanged: (on) => update(motion.copyWith(glow: on)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A dial, a bar and a lamp following the website's scripted drive, fed at
/// the live data rate - so the switches can be judged on something moving as
/// the dashboard does. Still where the system asks for reduced motion.
class _Preview extends ConsumerStatefulWidget {
  const _Preview();

  @override
  ConsumerState<_Preview> createState() => _PreviewState();
}

class _PreviewState extends ConsumerState<_Preview> {
  static const _rpm = GaugeSpec(
    channel: 'rpm',
    label: 'RPM',
    units: 'rpm',
    min: 0,
    max: 8000,
    warnAbove: 6000,
    dangerAbove: 6800,
  );
  static const _tps = GaugeSpec(
    channel: 'tps',
    label: 'Throttle',
    units: '%',
    min: 0,
    max: 100,
  );

  /// A moment of the cruise: what is shown when nothing moves.
  static const _still = 11.0;

  final _clock = Stopwatch();
  Timer? _timer;
  Duration? _interval;
  var _seconds = _still;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  /// Steps the drive at the live data rate - readings arrive the way they
  /// would from an ECU, and the glide is seen bridging them.
  void _schedule() {
    final interval = ref.read(appSettingsProvider).liveDataInterval;
    final run =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (run && _timer != null && interval == _interval) return;
    _timer?.cancel();
    _timer = null;
    _interval = interval;
    if (!run) {
      _clock.stop();
      return;
    }
    _clock.start();
    _timer = Timer.periodic(interval, (_) {
      setState(() => _seconds = _still + _clock.elapsedMicroseconds / 1e6);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A new rate is followed at once, as the dashboard follows it.
    ref.listen(
      appSettingsProvider.select((s) => s.liveDataInterval),
      (_, _) => _schedule(),
    );
    final engine = demoDriveAt(_seconds);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            height: 140,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Center(
                    child: MeterGauge(spec: _rpm, value: engine.rpm),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: BarGauge(spec: _tps, value: engine.tps),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FlagLamp(
                          label: 'DFCO',
                          on: engine.dfco,
                          onColor: StatusPalette.warning,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
