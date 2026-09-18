import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';

/// The polling loop for the live connection, or `null` when disconnected.
///
/// Tied to the connection: reconnecting rebuilds it, and disconnecting stops
/// the polling rather than leaving it running against a dead link.
final realtimeMonitorProvider = Provider<RealtimeMonitor?>((ref) {
  final connection = ref.watch(connectionProvider);
  if (connection is! EcuConnected) return null;

  final definition = connection.definition;
  final client = ref.read(connectionProvider.notifier).client;
  if (definition == null || client == null) return null;

  final monitor = RealtimeMonitor(
    client: client,
    decoder: RealtimeDecoder(definition.outputChannels),
    interval: const Duration(milliseconds: 33),
  );
  monitor.start();
  ref.onDispose(monitor.dispose);
  return monitor;
});

/// Decoded realtime samples.
final realtimeProvider = StreamProvider<RealtimeSnapshot>((ref) {
  final monitor = ref.watch(realtimeMonitorProvider);
  if (monitor == null) return const Stream<RealtimeSnapshot>.empty();
  return monitor.snapshots;
});

/// Poll failures, so the UI can show link trouble instead of a frozen display.
final realtimeErrorProvider = StreamProvider<Object>((ref) {
  final monitor = ref.watch(realtimeMonitorProvider);
  if (monitor == null) return const Stream<Object>.empty();
  return monitor.errors;
});
