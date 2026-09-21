import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../tune/tune_controller.dart';
import 'log_files.dart';

/// State of the datalogger.
class LogSession {
  const LogSession({
    required this.recording,
    this.path,
    this.rows = 0,
    this.startedAt,
    this.droppedChannels = const [],
    this.error,
  });

  final bool recording;
  final String? path;
  final int rows;
  final DateTime? startedAt;

  /// Channels excluded from this log, so their absence is visible.
  final List<String> droppedChannels;

  final String? error;

  Duration get elapsed =>
      startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);
}

/// Drives datalogging to a `.msl` file.
final logSessionProvider = NotifierProvider<LogController, LogSession>(
  LogController.new,
);

class LogController extends Notifier<LogSession> {
  LogRecorder? _recorder;

  @override
  LogSession build() {
    // Losing the ECU ends the log rather than leaving a half-written file open.
    ref.listen(connectionProvider, (previous, next) {
      if (next is! EcuConnected && state.recording) {
        stop();
      }
    });
    ref.onDispose(() => _recorder?.stop());
    return const LogSession(recording: false);
  }

  /// Begins recording to a timestamped file in the documents directory.
  Future<void> start() async {
    if (state.recording) return;

    final connection = ref.read(connectionProvider);
    if (connection is! EcuConnected || connection.definition == null) {
      state = const LogSession(
        recording: false,
        error: 'Not connected to an ECU.',
      );
      return;
    }

    // A probe sample decides which columns the log carries, so recording
    // cannot start until data is actually flowing.
    final probe = ref.read(realtimeProvider).valueOrNull;
    if (probe == null) {
      state = const LogSession(
        recording: false,
        error: 'Waiting for realtime data. Try again in a moment.',
      );
      return;
    }

    final tune = ref.read(tuneProvider).valueOrNull;
    final recorder = LogRecorder(
      definition: connection.definition!,
      constantResolver: tune == null ? null : TuneValueResolver(tune).resolve,
    );

    try {
      final dir = await ref.read(logDirectoryProvider.future);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/foxtune-$stamp.msl');

      await recorder.start(file, probe: probe);
      // Subscribe to the monitor directly rather than to the provider's
      // AsyncValue stream: the recorder wants every sample, not rebuild
      // notifications.
      final monitor = ref.read(realtimeMonitorProvider);
      if (monitor == null) {
        await recorder.stop();
        state = const LogSession(
          recording: false,
          error: 'Realtime polling is not running.',
        );
        return;
      }
      recorder.listenTo(monitor.snapshots);

      _recorder = recorder;
      state = LogSession(
        recording: true,
        path: file.path,
        startedAt: DateTime.now(),
        droppedChannels: recorder.droppedChannels,
      );
    } on Object catch (error) {
      state = LogSession(recording: false, error: '$error');
    }
  }

  /// Finishes the log.
  Future<void> stop() async {
    final recorder = _recorder;
    if (recorder == null) {
      state = const LogSession(recording: false);
      return;
    }
    _recorder = null;
    final rows = recorder.rowCount;
    final file = await recorder.stop();
    // A new log exists, so the list of recorded ones is out of date.
    ref.invalidate(recentLogsProvider);
    state = LogSession(
      recording: false,
      path: file?.path,
      rows: rows,
      droppedChannels: recorder.droppedChannels,
    );
  }

  /// Refreshes the row count shown in the UI.
  void refresh() {
    final recorder = _recorder;
    if (recorder == null || !state.recording) return;
    state = LogSession(
      recording: true,
      path: state.path,
      rows: recorder.rowCount,
      startedAt: state.startedAt,
      droppedChannels: state.droppedChannels,
    );
  }
}
