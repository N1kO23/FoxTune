import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../app_settings/app_settings.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../tune/tune_controller.dart';

/// The polling loop for the live connection, or `null` when disconnected.
///
/// Tied to the connection: reconnecting rebuilds it, and disconnecting stops
/// the polling rather than leaving it running against a dead link.
///
/// It polls on the connection's worker where it has one - out of reach of
/// whatever keeps this isolate busy, so the rate holds and no reading is
/// missed while a frame takes long; the samples are handed over as fast as
/// this isolate takes them.
final realtimeMonitorProvider = Provider<RealtimeSource?>((ref) {
  final connection = ref.watch(connectionProvider);
  if (connection is! EcuConnected) return null;

  final definition = connection.definition;
  final client = ref.read(connectionProvider.notifier).client;
  if (definition == null || client == null) return null;

  // Some computed channels depend on tune constants rather than telemetry -
  // dutyCycle needs twoStroke, which lives on a configuration page - so give
  // the decoder a way to reach the loaded tune. Without it those gauges read
  // as unavailable.
  //
  // Reached through the controller rather than by watching the tune's value.
  // Watching would tie the poller's lifetime to the tune, and a tune changes
  // on every edited cell: autotuning applies corrections many times a second,
  // and each one would dispose this monitor and start a fresh one mid-poll.
  final tuneController = ref.read(tuneProvider.notifier);

  // Watched, so a new rate takes effect at once: the poller is started afresh
  // at it.
  final interval = ref.watch(
    appSettingsProvider.select((s) => s.liveDataInterval),
  );

  final decoder = RealtimeDecoder(
    definition.outputChannels,
    constantResolver: (name) => tuneController.resolver?.resolve(name),
  );
  final worker = ref.read(connectionProvider.notifier).worker;
  final monitor = worker != null
      ? worker.realtime(
          channels: definition.outputChannels,
          decoder: decoder,
          commands: client.commands,
          interval: interval,
          timeout: client.timeout,
        )
      : RealtimeMonitor(client: client, decoder: decoder, interval: interval);
  monitor.start();
  ref.onDispose(monitor.dispose);
  return monitor;
});

/// Decoded realtime samples - every one of them.
///
/// For what needs each sample: the graph history, autotuning, logging. A
/// widget showing live data watches [liveProvider] instead, which passes on
/// at most one a frame.
final realtimeProvider = StreamProvider<RealtimeSnapshot>((ref) {
  final monitor = ref.watch(realtimeMonitorProvider);
  if (monitor == null) return const Stream<RealtimeSnapshot>.empty();
  return monitor.snapshots;
});

/// The newest realtime sample, for widgets: passed on at most once a frame.
///
/// The feed can run far faster than the screen is drawn - rusEFI reports up
/// to 200 times a second - and a widget watching [realtimeProvider] is told of
/// every sample, its selectors run for each, though it is drawn at most once a
/// frame. This keeps the newest and hands it over as the next frame begins,
/// so whatever watches it rebuilds once, with what that frame will show.
///
/// Asks for a frame only while something watches it: unwatched, Riverpod
/// pauses it, and its own listening with it.
final liveProvider = NotifierProvider<LiveSample, RealtimeSnapshot?>(
  LiveSample.new,
);

class LiveSample extends Notifier<RealtimeSnapshot?> {
  RealtimeSnapshot? _newest;
  var _scheduled = false;

  @override
  RealtimeSnapshot? build() {
    ref.listen(realtimeProvider, (_, next) {
      _newest = next.value;
      if (_scheduled) return;
      _scheduled = true;
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _scheduled = false;
        if (ref.mounted) state = _newest;
      });
    });
    return _newest = ref.read(realtimeProvider).value;
  }
}

/// The newest realtime sample, at most ten times a second: for what states
/// live values in words or forms rather than drawing them - a reader cannot
/// take in more, and rebuilding them faster is wasted.
final calmLiveProvider = NotifierProvider<CalmLiveSample, RealtimeSnapshot?>(
  CalmLiveSample.new,
);

class CalmLiveSample extends Notifier<RealtimeSnapshot?> {
  /// The least time between two samples passed on.
  static const spacing = Duration(milliseconds: 100);

  /// Open for [spacing] after a sample is passed on; one arriving meanwhile
  /// waits for it to close, and then the newest is passed on.
  Timer? _window;
  var _waiting = false;

  @override
  RealtimeSnapshot? build() {
    ref.onDispose(() => _window?.cancel());
    ref.listen(realtimeProvider, (_, next) {
      if (_window == null) {
        _publish(next.value);
      } else {
        _waiting = true;
      }
    });
    return ref.read(realtimeProvider).value;
  }

  void _publish(RealtimeSnapshot? sample) {
    state = sample;
    _window = Timer(spacing, () {
      _window = null;
      if (_waiting && ref.mounted) {
        _waiting = false;
        _publish(ref.read(realtimeProvider).value);
      }
    });
  }
}

/// Poll failures, so the UI can show link trouble instead of a frozen display.
final realtimeErrorProvider = StreamProvider<Object>((ref) {
  final monitor = ref.watch(realtimeMonitorProvider);
  if (monitor == null) return const Stream<Object>.empty();
  return monitor.errors;
});

/// Watches [provider] while the widget reading it is on screen, and only reads
/// it while the widget is hidden.
///
/// The connected shell keeps every tab alive in an [IndexedStack], which marks
/// the ones not shown as hidden to [Visibility.of]; a pushed route leaves the
/// screen beneath it built, with [TickerMode] off. Watching the realtime feed
/// from a hidden screen rebuilds, and lays out again, something nobody can
/// see - 30 times a second, for every such screen. Hidden, a widget here keeps
/// what it last showed and its subscription lapses, since Riverpod drops
/// whatever a build did not watch. Both are inherited, so being shown again
/// rebuilds the widget, and it watches afresh.
///
/// Catching up at once relies on the feed itself running while nothing
/// watches it, which the connected shell sees to: left alone, Riverpod pauses
/// a provider nobody is listening to.
///
/// For widgets that show live data. Providers that must keep up with the feed
/// while nothing shows them - the graph history, autotuning, logging - listen
/// to it directly instead.
T watchWhileVisible<T>(
  WidgetRef ref,
  BuildContext context,
  ProviderListenable<T> provider,
) => Visibility.of(context) && TickerMode.valuesOf(context).enabled
    ? ref.watch(provider)
    : ref.read(provider);
