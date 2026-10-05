import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show RealtimeDecoder;
import 'package:foxtune_protocol/io.dart' show WorkerRecording;
import 'package:foxtune_tune/foxtune_tune.dart';

import '../app_settings/app_settings.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/live_demand.dart';
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
  /// The log, where it is written on this isolate...
  LogRecorder? _recorder;

  /// ...or on the connection's worker, where the samples are read: the log
  /// keeps pace with the ECU however busy this isolate is, and none of its
  /// formatting - a thousand columns a row for rusEFI - is done here.
  WorkerRecording? _recording;

  /// What has the whole live data block polled while a log is recorded: a
  /// log keeps every channel.
  late WholeBlockHolders _wholeBlock;

  @override
  LogSession build() {
    // Not let go of when this is disposed: it outlives every session, and is
    // disposed only with everything else.
    _wholeBlock = ref.read(wholeBlockProvider.notifier);
    // Losing the ECU ends the log rather than leaving a half-written file open.
    ref.listen(connectionProvider, (previous, next) {
      if (next is! EcuConnected && state.recording) {
        stop();
      }
    });
    ref.onDispose(() {
      _recorder?.stop();
      _recording?.stop().ignore();
    });
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

    // Recording cannot start until data is actually flowing.
    final live = ref.read(realtimeProvider).value;
    if (live == null) {
      state = const LogSession(
        recording: false,
        error: 'Waiting for realtime data. Try again in a moment.',
      );
      return;
    }

    final definition = connection.definition!;
    final tune = ref.read(tuneProvider).value;
    final resolve = tune == null ? null : TuneValueResolver(tune).resolve;
    final spacing = ref.read(appSettingsProvider).logSpacing;
    final recorder = LogRecorder(
      definition: definition,
      constantResolver: resolve,
      spacing: spacing,
    );

    try {
      final dir = await ref.read(logDirectoryProvider.future);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final file = File('${dir.path}/foxtune-$stamp.msl');

      // A probe sample decides which columns the log carries: one read whole,
      // not the latest polled, which may hold only the parts of the block in
      // use - and a column left out for a channel merely unread would be
      // missing from the whole log.
      final client = ref.read(connectionProvider.notifier).client;
      final size = definition.outputChannels.blockSize;
      final probe = client == null || size == null
          ? live
          : RealtimeDecoder(
              definition.outputChannels,
              constantResolver: resolve,
            ).decode(await client.readRealtime(count: size));

      final worker = ref.read(connectionProvider.notifier).worker;
      if (worker != null && ref.read(realtimeMonitorProvider) != null) {
        final recording = _recording = worker.startRecording(
          MslSinkFactory(
            definition: definition,
            path: file.path,
            probe: probe.block,
            tune: tune,
            spacing: spacing,
          ),
        );
        // A log that cannot be written ends here, and says why.
        recording.done.then<void>(
          (_) {},
          onError: (Object error) {
            if (!identical(_recording, recording)) return;
            _recording = null;
            _wholeBlock.release(this);
            state = LogSession(recording: false, error: '$error');
          },
        );
        _wholeBlock.hold(this);
        state = LogSession(
          recording: true,
          path: file.path,
          startedAt: DateTime.now(),
          // Worked out here once, from the same probe the log's columns are.
          droppedChannels: MslLogWriter.forDefinition(
            definition,
            probe: probe,
            constantResolver: resolve,
          ).dropped,
        );
        return;
      }

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
      _wholeBlock.hold(this);

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
    _wholeBlock.release(this);
    final recording = _recording;
    if (recording != null) {
      _recording = null;
      final session = state;
      try {
        final rows = await recording.stop();
        ref.invalidate(recentLogsProvider);
        state = LogSession(
          recording: false,
          path: session.path,
          rows: rows,
          droppedChannels: session.droppedChannels,
        );
      } on Object catch (error) {
        state = LogSession(
          recording: false,
          path: session.path,
          error: '$error',
        );
      }
      return;
    }
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
    final rows = _recording?.count ?? _recorder?.rowCount;
    if (rows == null || !state.recording) return;
    state = LogSession(
      recording: true,
      path: state.path,
      rows: rows,
      startedAt: state.startedAt,
      droppedChannels: state.droppedChannels,
    );
  }
}
