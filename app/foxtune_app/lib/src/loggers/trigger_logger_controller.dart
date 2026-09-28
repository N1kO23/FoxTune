import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../storage/json_store.dart';

/// The loggers FoxTune can show: tooth and composite ones.
///
/// rusEFI also declares a trigger oscilloscope, whose records are samples of
/// an analogue input rather than edges; that is left out.
List<IniLogger> triggerLoggersOf(IniDocument? definition) => [
  for (final logger in definition?.loggers ?? const <IniLogger>[])
    if (logger.kind == IniLoggerKind.tooth ||
        logger.kind == IniLoggerKind.composite)
      logger,
];

/// What the trigger logger shows.
class TriggerLoggerState {
  const TriggerLoggerState({
    this.selected = 0,
    this.running = false,
    this.busy = false,
    this.latest,
    this.captures = 0,
    this.run,
    this.recorded = 0,
    this.error,
  });

  /// Which of [triggerLoggersOf] is chosen.
  final int selected;

  /// Whether it is running on the ECU.
  final bool running;

  /// Starting or stopping.
  final bool busy;

  /// The newest capture, kept after the logger stops.
  final TriggerLog? latest;

  /// Captures read since it started.
  final int captures;

  /// Every capture read since it started, as CSV, kept after it stops -
  /// `null` until one has anything in it. See [TriggerLog.toCsv].
  ///
  /// Written to as each capture is read rather than held in memory: a
  /// logger left running on a phone would otherwise grow without end.
  final File? run;

  /// Records in [run]: teeth, or edges for a composite log.
  final int recorded;

  /// The last thing that went wrong, until a capture arrives.
  final Object? error;

  TriggerLoggerState copyWith({
    bool? running,
    bool? busy,
    TriggerLog? latest,
    int? captures,
    File? run,
    int? recorded,
    Object? error,
    bool clearError = false,
  }) => TriggerLoggerState(
    selected: selected,
    running: running ?? this.running,
    busy: busy ?? this.busy,
    latest: latest ?? this.latest,
    captures: captures ?? this.captures,
    run: run ?? this.run,
    recorded: recorded ?? this.recorded,
    error: clearError ? null : error ?? this.error,
  );
}

/// Runs the connected ECU's trigger loggers.
///
/// Tied to the connection: a new one starts afresh, and losing it ends the
/// logger. The ECU is told to stop its logger whenever it still can be -
/// Speeduino's replaces its trigger interrupts with the logger's own while
/// one runs.
final triggerLoggerProvider =
    NotifierProvider<TriggerLoggerController, TriggerLoggerState>(
      TriggerLoggerController.new,
    );

class TriggerLoggerController extends Notifier<TriggerLoggerState> {
  TriggerLogger? _session;
  StreamSubscription<TriggerLog>? _captures;
  StreamSubscription<Object>? _errors;

  /// The run's file, open while the logger runs.
  RandomAccessFile? _writer;

  /// The live data, which carries the flag that says a capture is ready -
  /// followed through the provider, so a poller started afresh at a new
  /// rate is followed too.
  ProviderSubscription<AsyncValue<RealtimeSnapshot>>? _live;
  StreamController<RealtimeSnapshot>? _feed;

  @override
  TriggerLoggerState build() {
    ref.watch(connectionProvider);
    ref.onDispose(_end);
    return const TriggerLoggerState();
  }

  List<IniLogger> get _loggers {
    final connection = ref.read(connectionProvider);
    return connection is EcuConnected
        ? triggerLoggersOf(connection.definition)
        : const [];
  }

  /// Chooses logger [index]. Not while one is running.
  void select(int index) {
    if (state.running || state.busy) return;
    if (index < 0 || index >= _loggers.length) return;
    state = TriggerLoggerState(selected: index);
  }

  Future<void> start() async {
    final loggers = _loggers;
    if (state.running || state.busy || state.selected >= loggers.length) {
      return;
    }
    final client = ref.read(connectionProvider.notifier).client;
    if (client == null) return;
    final logger = loggers[state.selected];

    // A new run: the last one's file goes, and its count with it. Its
    // capture stays on screen until this one has one to show.
    state = TriggerLoggerState(
      selected: state.selected,
      busy: true,
      latest: state.latest,
    );
    final File file;
    final RandomAccessFile writer;
    try {
      file = await _newRunFile(logger);
      writer = file.openSync(mode: FileMode.writeOnly);
    } on Object catch (error) {
      if (ref.mounted) {
        state = state.copyWith(
          busy: false,
          error: 'Could not make a file for the run: $error',
        );
      }
      return;
    }
    if (!ref.mounted) {
      writer.closeSync();
      return;
    }
    _writer = writer;

    final feed = _feed = StreamController<RealtimeSnapshot>.broadcast();
    _live = ref.listen(realtimeProvider, (_, next) {
      if (next.value case final snapshot? when !feed.isClosed) {
        feed.add(snapshot);
      }
    });
    final session = TriggerLogger(
      client: client,
      logger: logger,
      snapshots: feed.stream,
    );
    _captures = session.captures.listen((log) {
      if (!ref.mounted) return;
      final number = state.captures + 1;
      Object? failure;
      var kept = false;
      if (!log.isEmpty) {
        try {
          writer.writeStringSync(
            log.toCsv(capture: number, header: state.recorded == 0),
          );
          kept = true;
        } on Object catch (error) {
          failure = 'Could not add capture $number to the run: $error';
        }
      }
      state = state.copyWith(
        latest: log,
        captures: number,
        run: kept ? file : null,
        recorded: kept ? state.recorded + log.records.length : null,
        error: failure,
        clearError: failure == null,
      );
    });
    _errors = session.errors.listen((error) {
      if (ref.mounted) state = state.copyWith(error: error);
    });
    try {
      await session.start();
      if (!ref.mounted) {
        await session.dispose();
        return;
      }
      _session = session;
      state = state.copyWith(running: true, busy: false);
    } on Object catch (error) {
      await _cancelSubscriptions();
      _closeRun();
      await session.dispose();
      if (!ref.mounted) return;
      state = state.copyWith(busy: false, error: error);
    }
  }

  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    _session = null;
    state = state.copyWith(busy: true);
    Object? failure;
    try {
      await session.stop();
    } on Object catch (error) {
      failure = error;
    }
    await _cancelSubscriptions();
    _closeRun();
    await session.dispose();
    if (!ref.mounted) return;
    state = state.copyWith(running: false, busy: false, error: failure);
  }

  /// An empty file for a run of [logger], in place of the last run's.
  ///
  /// Only the latest run is kept: it is there to be saved, and one that was
  /// not saved before the next started is not wanted.
  Future<File> _newRunFile(IniLogger logger) async {
    final root = await ref.read(appStorageDirectoryProvider.future);
    final directory = Directory('${root.path}/trigger-logs')
      ..createSync(recursive: true);
    for (final old in directory.listSync()) {
      if (old is File && old.path.endsWith('.csv')) old.deleteSync();
    }
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    return File('${directory.path}/${logger.id}-$stamp.csv');
  }

  void _closeRun() {
    final writer = _writer;
    _writer = null;
    try {
      writer?.closeSync();
    } on FileSystemException {
      // Nothing more is written to it either way.
    }
  }

  /// Stops listening at once - nothing more arrives after this returns its
  /// future, whenever that completes.
  Future<void> _cancelSubscriptions() async {
    final captures = _captures;
    final errors = _errors;
    final feed = _feed;
    _live?.close();
    _live = null;
    _captures = null;
    _errors = null;
    _feed = null;
    await Future.wait([?captures?.cancel(), ?errors?.cancel(), ?feed?.close()]);
  }

  void _end() {
    final session = _session;
    _session = null;
    unawaited(_cancelSubscriptions());
    _closeRun();
    if (session != null) unawaited(session.dispose());
  }
}
