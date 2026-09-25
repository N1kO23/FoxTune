import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app_settings/app_settings.dart';
import '../dashboard/dashboard_controller.dart';
import 'connection_controller.dart';
import 'connection_state.dart';

/// Notices a connection ending, and ports coming and going.
///
/// Two independent signals, because each catches what the other misses:
///
/// - **A USB detach** for the connected port is immediate - a phone reports a
///   pulled OTG cable at once - but only USB reports it, and only when the
///   platform says which device went.
/// - **The realtime monitor giving up** after consecutive failed polls covers
///   everything else: a network bridge dropping, the ECU losing power, the
///   firmware crashing. It takes a few seconds, which is why the detach is
///   worth having too.
///
/// Watched from the app shell so it lives as long as the app does.
final connectionWatchdogProvider = Provider<void>((ref) {
  final transport = ref.watch(transportProvider);

  final portEvents = transport.portEvents.listen((event) {
    // Whatever changed, the list of ports is now out of date.
    ref.invalidate(portsProvider);

    if (event.attached) return;
    final connection = ref.read(connectionProvider);
    final address = event.address;
    // A detach that does not say which device it was is left to the realtime
    // monitor: acting on it could end a perfectly healthy session because an
    // unrelated USB stick was pulled.
    if (connection is EcuConnected &&
        address != null &&
        address == connection.port.address) {
      ref
          .read(connectionProvider.notifier)
          .connectionLost('The ECU was unplugged.');
    }
  });
  ref.onDispose(portEvents.cancel);

  StreamSubscription<Object>? pollErrors;
  ref.listen<RealtimeMonitor?>(realtimeMonitorProvider, (previous, monitor) {
    unawaited(pollErrors?.cancel());
    pollErrors = monitor?.errors.listen((error) {
      if (error is! RealtimeLinkLost) return;
      ref
          .read(connectionProvider.notifier)
          .connectionLost('The ECU stopped responding.');
    });
  }, fireImmediately: true);
  ref.onDispose(() => pollErrors?.cancel());
});

/// Holds the screen on while an ECU is connected.
///
/// Gauges that go dark mid-drive are useless, and once the screen is off
/// Android throttles the app enough to drop realtime samples and datalog
/// rows. Only while connected, though: nothing about an idle connect screen
/// justifies draining the battery.
abstract interface class ScreenWake {
  Future<void> hold();
  Future<void> release();
}

class _PlatformScreenWake implements ScreenWake {
  const _PlatformScreenWake();

  // A wake lock is a convenience. If the platform refuses one, the
  // connection must carry on regardless, so failures are swallowed here
  // rather than surfacing into connection handling.
  @override
  Future<void> hold() async {
    try {
      await WakelockPlus.enable();
    } on Object {
      return;
    }
  }

  @override
  Future<void> release() async {
    try {
      await WakelockPlus.disable();
    } on Object {
      return;
    }
  }
}

/// The platform's screen wake lock.
final screenWakeProvider = Provider<ScreenWake>(
  (ref) => const _PlatformScreenWake(),
);

/// Takes and releases the screen wake lock as the connection comes and goes,
/// unless the user has turned that off in App settings.
final screenWakeWatcherProvider = Provider<void>((ref) {
  final wake = ref.watch(screenWakeProvider);
  // Turning it off while connected rebuilds this, and the previous build
  // lets go of the lock as it is disposed.
  if (!ref.watch(appSettingsProvider.select((s) => s.keepScreenOn))) return;
  var held = false;

  ref.listen<EcuConnectionState>(connectionProvider, (previous, next) {
    final connected = next is EcuConnected;
    if (connected == held) return;
    held = connected;
    unawaited(connected ? wake.hold() : wake.release());
  }, fireImmediately: true);
  ref.onDispose(() {
    if (held) unawaited(wake.release());
  });
});
