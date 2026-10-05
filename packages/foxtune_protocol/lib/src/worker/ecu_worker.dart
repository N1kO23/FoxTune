import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

import '../command_runner.dart';
import '../command_set.dart';
import '../ecu_client.dart';
import '../ecu_link.dart';
import '../frame.dart';
import '../realtime_decoder.dart';
import '../realtime_monitor.dart';
import '../realtime_source.dart';
import '../response_code.dart';

/// Opens the link to an ECU, on the isolate that will use it.
///
/// Sent to the worker's isolate, so whatever it needs to open the link is
/// data: a port's address and speed, a host and port.
abstract interface class LinkOpener {
  /// Opens the link. Called on the worker's isolate.
  Future<EcuLink> open();
}

/// Records realtime blocks on the worker's isolate - a datalog, say - so the
/// recording keeps pace with the ECU whatever the isolate that asked for it
/// is doing.
abstract interface class BlockSink {
  /// Takes one block, read at [timestamp].
  void add(Uint8List block, DateTime timestamp);

  /// How many blocks have been recorded - not every block taken need be.
  int get count;

  /// Finishes the recording.
  Future<void> close();
}

/// Opens a [BlockSink] on the worker's isolate.
///
/// Sent there, so - like [LinkOpener] - what it needs is data.
abstract interface class BlockSinkFactory {
  Future<BlockSink> open();
}

/// A recording a worker is making: see [EcuWorker.startRecording].
class WorkerRecording {
  WorkerRecording._(this._worker, this._id);

  final EcuWorker _worker;
  final int _id;
  final _finished = Completer<int>();

  /// How many blocks have been recorded, as last reported.
  int get count => _count;
  var _count = 0;

  /// Completes with how many blocks the recording holds once it is finished -
  /// or fails, if the recording could not be made or carried on.
  Future<int> get done => _finished.future;

  /// Finishes the recording, and completes with how many blocks it holds.
  Future<int> stop() {
    _worker._send(_StopRecording(_id));
    return _finished.future;
  }
}

/// An ECU connection on an isolate of its own.
///
/// It owns the link, carries out the commands asked of it one at a time, and
/// polls live data at the rate asked for - on its own event loop, so its
/// timeouts and its pacing are out of reach of whatever keeps the isolate
/// that asked busy: frames being drawn, a heavy screen being built, a garbage
/// collection. And it hands live data over in batches, as fast as that
/// isolate takes them, so a busy one is never flooded either.
///
/// [commands] runs commands for an [EcuClient.withRunner]; [realtime] polls.
class EcuWorker {
  EcuWorker._(
    this._isolate,
    this._toWorker,
    this._fromWorker,
    this._subscription,
    this._relayed,
  ) {
    _startRelay();
  }

  /// A worker that opens its link with [opener].
  ///
  /// Fails as opening the link failed, with what the opener threw - or with
  /// an [IsolateSpawnException] if the worker itself could not be started.
  static Future<EcuWorker> spawn(LinkOpener opener) => _spawn(opener: opener);

  /// A worker whose link is [link], already open on this isolate - and
  /// closed with the worker.
  ///
  /// For a link only this isolate can reach: Flutter delivers platform
  /// channel messages - Android's USB serial among them - to the root isolate
  /// alone. Its bytes pass through here on their way to and from the worker,
  /// so a busy moment here can still delay them; everything else the worker
  /// does stays out of reach.
  static Future<EcuWorker> relay(EcuLink link) => _spawn(relayed: link);

  static Future<EcuWorker> _spawn({
    LinkOpener? opener,
    EcuLink? relayed,
  }) async {
    final fromWorker = ReceivePort('EcuWorker');
    final ready = Completer<SendPort>();
    // A port is listened to once: the handshake first, then the worker.
    void Function(Object?) receive = (message) {
      if (ready.isCompleted) return;
      switch (message) {
        case _Ready(:final toWorker):
          ready.complete(toWorker);
        // As thrown where the link was opened: a transport's own exception
        // says what went wrong in its own words.
        case _OpenFailed(:final error):
          ready.completeError(error);
        // Gone before it was ready: exited (null) or failed ([error, stack]).
        case null || List<Object?>():
          ready.completeError(
            EcuProtocolException(
              'The ECU connection failed to start'
              '${message is List ? ': ${message.first}' : ''}',
            ),
          );
      }
    };
    final subscription = fromWorker.listen((message) => receive(message));
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        _Start(fromWorker.sendPort, opener, relayed?.description),
        debugName: 'EcuWorker',
        onExit: fromWorker.sendPort,
        onError: fromWorker.sendPort,
      );
    } on Object catch (error) {
      await subscription.cancel();
      fromWorker.close();
      // As one, whatever stopped it - an opener that cannot be sent to
      // another isolate among them - so a caller can tell a worker that did
      // not start from a link that did not open.
      throw error is IsolateSpawnException
          ? error
          : IsolateSpawnException('$error');
    }
    try {
      final toWorker = await ready.future;
      final worker = EcuWorker._(
        isolate,
        toWorker,
        fromWorker,
        subscription,
        relayed,
      );
      receive = worker._receive;
      return worker;
    } on Object {
      await subscription.cancel();
      fromWorker.close();
      isolate.kill();
      rethrow;
    }
  }

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final StreamSubscription<Object?> _subscription;

  /// The link relayed for the worker, where it has one.
  final EcuLink? _relayed;
  StreamSubscription<List<int>>? _relaying;

  final _commands = <int, Completer<Uint8List>>{};
  final _recordings = <int, WorkerRecording>{};
  var _nextId = 0;
  _WorkerSource? _source;
  var _generation = 0;
  final _closed = Completer<void>();
  var _closing = false;

  /// Carries out commands on the worker: hand to [EcuClient.withRunner].
  late final EcuCommandRunner commands = _WorkerCommands(this);

  /// Polls live data on the worker: [channels] says how big the block is and
  /// [decoder] decodes it here; [commands] says how to ask for it.
  ///
  /// One at a time: a source made here replaces the last.
  RealtimeSource realtime({
    required IniOutputChannels channels,
    required RealtimeDecoder decoder,
    required EcuCommandSet commands,
    required Duration interval,
    Duration timeout = const Duration(milliseconds: 1000),
    int maxConsecutiveErrors = 5,
  }) {
    final previous = _source;
    if (previous != null) unawaited(previous.dispose());
    return _source = _WorkerSource(
      this,
      ++_generation,
      _StartPolling(
        generation: _generation,
        channels: channels,
        commands: commands,
        interval: interval,
        timeout: timeout,
        maxConsecutiveErrors: maxConsecutiveErrors,
      ),
      decoder,
    );
  }

  /// Starts recording every block polled, on the worker, into the sink
  /// [factory] opens there.
  WorkerRecording startRecording(BlockSinkFactory factory) {
    final id = _nextId++;
    final recording = _recordings[id] = WorkerRecording._(this, id);
    _send(_StartRecording(id, factory));
    return recording;
  }

  /// Stops the worker: polling, recordings, the link. Safe to call more than
  /// once.
  Future<void> close() async {
    if (!_closing) {
      _closing = true;
      _send(const _Close());
      await _closed.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      _shutDown('The ECU connection was closed');
    }
    await _closed.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  void _send(_ToWorker message) {
    if (_closed.isCompleted) return;
    _toWorker.send(message);
  }

  void _startRelay() {
    final link = _relayed;
    if (link == null || _relaying != null) return;
    _relaying = link.incoming.listen(
      (bytes) => _send(_RelayIn(Uint8List.fromList(bytes))),
      onError: (Object error) => _send(_RelayFailed('$error')),
      onDone: () => _send(const _RelayFailed('The link closed')),
    );
  }

  void _receive(Object? message) {
    switch (message) {
      case _Done(:final id, :final data):
        _commands.remove(id)?.complete(data);
      case _Failed(:final id, :final message, :final response):
        _commands.remove(id)?.completeError(
              EcuProtocolException(
                message,
                response: response == null
                    ? null
                    : SerialResponse.values.byName(response),
              ),
            );
      case final _Batch batch:
        final source = _source;
        if (source != null && source.generation == batch.generation) {
          source._take(batch);
        }
        _send(const _Ack());
      case final _PollFailed failure:
        final source = _source;
        if (source != null && source.generation == failure.generation) {
          source._fail(failure);
        }
      case _RelayOut(:final bytes):
        try {
          _relayed?.send(bytes);
        } on Object catch (error) {
          _send(_RelayFailed('$error'));
        }
      case _Recorded(:final id, :final count, :final finished, :final error):
        final recording = _recordings[id];
        if (recording == null) break;
        recording._count = count;
        if (finished) {
          _recordings.remove(id);
          if (error == null) {
            recording._finished.complete(count);
          } else {
            recording._finished.completeError(EcuProtocolException(error));
          }
        }
      case _Closed():
        _shutDown('The ECU connection was closed');
      // The isolate exited (onExit sends null) or failed (onError sends the
      // error and its stack as a list).
      case null || List<Object?>():
        _shutDown(
          message is List
              ? 'The ECU connection failed: ${message.first}'
              : 'The ECU connection ended',
        );
    }
  }

  /// Fails whatever is waiting on the worker, which is gone.
  void _shutDown(String reason) {
    if (_closed.isCompleted) return;
    _closed.complete();
    for (final command in _commands.values) {
      command.completeError(EcuProtocolException(reason));
    }
    _commands.clear();
    for (final recording in _recordings.values) {
      if (!recording._finished.isCompleted) {
        recording._finished.completeError(EcuProtocolException(reason));
      }
    }
    _recordings.clear();
    _source?._fail(_PollFailed(_generation, reason, linkLost: true));
    unawaited(_relaying?.cancel());
    unawaited(_relayed?.close());
    unawaited(_subscription.cancel());
    _fromWorker.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

/// [EcuCommandRunner] on an [EcuWorker].
class _WorkerCommands implements EcuCommandRunner {
  _WorkerCommands(this._worker);

  final EcuWorker _worker;
  var _closed = false;

  @override
  Future<Uint8List> run(List<int> payload, {required Duration timeout}) {
    if (_closed || _worker._closed.isCompleted) {
      return Future.error(EcuProtocolException('Client is closed'));
    }
    final id = _worker._nextId++;
    final reply = _worker._commands[id] = Completer<Uint8List>();
    _worker._send(_Run(id, Uint8List.fromList(payload), timeout));
    return reply.future;
  }

  @override
  List<EcuFrameException> get recentFrameErrors => const [];

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// [RealtimeSource] polled on an [EcuWorker].
class _WorkerSource implements RealtimeSource {
  _WorkerSource(this._worker, this.generation, this._polling, this._decoder);

  final EcuWorker _worker;
  final int generation;
  final _StartPolling _polling;
  final RealtimeDecoder _decoder;

  final _snapshots = StreamController<RealtimeSnapshot>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  @override
  Stream<RealtimeSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  RealtimeSnapshot? latest;

  @override
  Duration get interval => _polling.interval;

  @override
  bool isRunning = false;

  @override
  int pollCount = 0;

  @override
  double measuredHz = 0;

  @override
  void start() {
    if (isRunning || _snapshots.isClosed) return;
    isRunning = true;
    _worker._send(_polling);
  }

  @override
  Future<void> stop() async {
    if (!isRunning) return;
    isRunning = false;
    _worker._send(_StopPolling(generation));
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (identical(_worker._source, this)) _worker._source = null;
    await _snapshots.close();
    await _errors.close();
  }

  void _take(_Batch batch) {
    pollCount = batch.pollCount;
    measuredHz = batch.measuredHz;
    if (_snapshots.isClosed) return;
    for (var i = 0; i < batch.blocks.length; i++) {
      final sample = _decoder.decode(
        batch.blocks[i],
        timestamp: DateTime.fromMicrosecondsSinceEpoch(batch.times[i]),
      );
      latest = sample;
      _snapshots.add(sample);
    }
  }

  void _fail(_PollFailed failure) {
    if (failure.linkLost) isRunning = false;
    if (_errors.isClosed) return;
    _errors.add(
      failure.linkLost
          ? RealtimeLinkLost(failure.failures, cause: failure.message)
          : EcuProtocolException(failure.message),
    );
  }
}

// --- Messages ----------------------------------------------------------------

sealed class _ToWorker {
  const _ToWorker();
}

final class _Run extends _ToWorker {
  const _Run(this.id, this.payload, this.timeout);
  final int id;
  final Uint8List payload;
  final Duration timeout;
}

final class _StartPolling extends _ToWorker {
  const _StartPolling({
    required this.generation,
    required this.channels,
    required this.commands,
    required this.interval,
    required this.timeout,
    required this.maxConsecutiveErrors,
  });
  final int generation;
  final IniOutputChannels channels;
  final EcuCommandSet commands;
  final Duration interval;
  final Duration timeout;
  final int maxConsecutiveErrors;
}

final class _StopPolling extends _ToWorker {
  const _StopPolling(this.generation);
  final int generation;
}

/// The UI isolate has taken the last batch, and can take another.
final class _Ack extends _ToWorker {
  const _Ack();
}

final class _StartRecording extends _ToWorker {
  const _StartRecording(this.id, this.factory);
  final int id;
  final BlockSinkFactory factory;
}

final class _StopRecording extends _ToWorker {
  const _StopRecording(this.id);
  final int id;
}

final class _RelayIn extends _ToWorker {
  const _RelayIn(this.bytes);
  final Uint8List bytes;
}

final class _RelayFailed extends _ToWorker {
  const _RelayFailed(this.reason);
  final String reason;
}

final class _Close extends _ToWorker {
  const _Close();
}

final class _Start {
  const _Start(this.toMain, this.opener, this.relayed);
  final SendPort toMain;
  final LinkOpener? opener;

  /// The relayed link's description, where the link is relayed.
  final String? relayed;
}

final class _Ready {
  const _Ready(this.toWorker);
  final SendPort toWorker;
}

final class _OpenFailed {
  const _OpenFailed(this.error);

  /// What opening the link threw - or, where that cannot be sent between
  /// isolates, what it said.
  final Object error;
}

final class _Done {
  const _Done(this.id, this.data);
  final int id;
  final Uint8List data;
}

final class _Failed {
  const _Failed(this.id, this.message, this.response);
  final int id;
  final String message;

  /// The [SerialResponse]'s name, where the ECU gave one.
  final String? response;
}

/// Samples polled since the last batch: when each was read, in microseconds
/// since the epoch, and its block.
final class _Batch {
  const _Batch({
    required this.generation,
    required this.times,
    required this.blocks,
    required this.pollCount,
    required this.measuredHz,
  });
  final int generation;
  final Int64List times;
  final List<Uint8List> blocks;
  final int pollCount;
  final double measuredHz;
}

final class _PollFailed {
  const _PollFailed(
    this.generation,
    this.message, {
    this.linkLost = false,
    this.failures = 0,
  });
  final int generation;
  final String message;
  final bool linkLost;
  final int failures;
}

final class _RelayOut {
  const _RelayOut(this.bytes);
  final Uint8List bytes;
}

final class _Recorded {
  const _Recorded(this.id, this.count, {this.finished = false, this.error});
  final int id;
  final int count;
  final bool finished;
  final String? error;
}

final class _Closed {
  const _Closed();
}

// --- The worker's isolate ----------------------------------------------------

Future<void> _workerMain(_Start start) async {
  final toMain = start.toMain;
  final inbox = ReceivePort();
  final EcuLink link;
  try {
    link = switch (start.opener) {
      final opener? => await opener.open(),
      null => _RelayedLink(start.relayed ?? 'relayed', toMain),
    };
  } on Object catch (error) {
    try {
      toMain.send(_OpenFailed(error));
    } on Object {
      toMain.send(_OpenFailed(EcuProtocolException('$error')));
    }
    inbox.close();
    return;
  }
  final worker = _Worker(toMain, link, LinkCommandRunner(link));
  toMain.send(_Ready(inbox.sendPort));
  await for (final message in inbox) {
    if (await worker.handle(message as _ToWorker)) break;
  }
  inbox.close();
  toMain.send(const _Closed());
  Isolate.exit();
}

class _Worker {
  _Worker(this.toMain, this.link, this.runner);

  final SendPort toMain;
  final EcuLink link;
  final LinkCommandRunner runner;

  RealtimeMonitor? _monitor;
  StreamSubscription<RealtimeSnapshot>? _samples;
  StreamSubscription<Object>? _errors;
  var _generation = 0;

  /// Samples polled and not yet sent, oldest first.
  final _times = ListQueue<int>();
  final _blocks = ListQueue<Uint8List>();

  /// Whether the last batch is still waiting to be taken.
  var _awaitingAck = false;

  final _sinks = <int, BlockSink>{};
  Timer? _reporting;

  /// The most samples held back for a UI isolate not taking them: past this,
  /// the oldest are let go. Recordings see every one regardless.
  static const backlog = Duration(seconds: 2);

  /// Handles [message]; `true` once the worker is to stop.
  Future<bool> handle(_ToWorker message) async {
    switch (message) {
      case _Run(:final id, :final payload, :final timeout):
        runner.run(payload, timeout: timeout).then(
              (data) => toMain.send(_Done(id, data)),
              onError: (Object error) => toMain.send(
                switch (error) {
                  EcuProtocolException(:final message, :final response) =>
                    _Failed(id, message, response?.name),
                  _ => _Failed(id, '$error', null),
                },
              ),
            );
      case final _StartPolling polling:
        await _stopPolling();
        _poll(polling);
      case _StopPolling(:final generation):
        if (generation == _generation) await _stopPolling();
      case _Ack():
        _awaitingAck = false;
        _flush();
      case _StartRecording(:final id, :final factory):
        try {
          _sinks[id] = await factory.open();
          _reporting ??= Timer.periodic(
            const Duration(milliseconds: 500),
            (_) => _sinks.forEach(
              (id, sink) => toMain.send(_Recorded(id, sink.count)),
            ),
          );
        } on Object catch (error) {
          toMain.send(_Recorded(id, 0, finished: true, error: '$error'));
        }
      case _StopRecording(:final id):
        await _finishRecording(id);
      case _RelayIn(:final bytes):
        (link as _RelayedLink).deliver(bytes);
      case _RelayFailed(:final reason):
        (link as _RelayedLink).fail(reason);
      case _Close():
        await _stopPolling();
        for (final id in [..._sinks.keys]) {
          await _finishRecording(id);
        }
        await runner.close();
        await link.close();
        return true;
    }
    return false;
  }

  void _poll(_StartPolling polling) {
    _generation = polling.generation;
    final client = EcuClient.withRunner(
      runner,
      commands: polling.commands,
      timeout: polling.timeout,
    );
    final monitor = _monitor = RealtimeMonitor(
      client: client,
      decoder: RealtimeDecoder(polling.channels),
      interval: polling.interval,
      maxConsecutiveErrors: polling.maxConsecutiveErrors,
    );
    _samples = monitor.snapshots.listen(_take);
    _errors = monitor.errors.listen(
      (error) => toMain.send(
        error is RealtimeLinkLost
            ? _PollFailed(
                polling.generation,
                '${error.cause ?? error}',
                linkLost: true,
                failures: error.failures,
              )
            : _PollFailed(polling.generation, '$error'),
      ),
    );
    monitor.start();
  }

  Future<void> _stopPolling() async {
    final monitor = _monitor;
    _monitor = null;
    await _samples?.cancel();
    await _errors?.cancel();
    _samples = null;
    _errors = null;
    _times.clear();
    _blocks.clear();
    _awaitingAck = false;
    // Not the client: it is only a view of the runner, which carries on.
    await monitor?.dispose();
  }

  void _take(RealtimeSnapshot sample) {
    for (final sink in _sinks.values) {
      sink.add(sample.block, sample.timestamp);
    }
    _times.addLast(sample.timestamp.microsecondsSinceEpoch);
    _blocks.addLast(sample.block);
    while (_times.length > 1 &&
        _times.last - _times.first > backlog.inMicroseconds) {
      _times.removeFirst();
      _blocks.removeFirst();
    }
    if (!_awaitingAck) _flush();
  }

  /// Sends what has been polled since the last batch, if anything.
  void _flush() {
    final monitor = _monitor;
    if (_times.isEmpty || monitor == null) return;
    toMain.send(
      _Batch(
        generation: _generation,
        times: Int64List.fromList(_times.toList()),
        blocks: _blocks.toList(),
        pollCount: monitor.pollCount,
        measuredHz: monitor.measuredHz,
      ),
    );
    _times.clear();
    _blocks.clear();
    _awaitingAck = true;
  }

  Future<void> _finishRecording(int id) async {
    final sink = _sinks.remove(id);
    if (_sinks.isEmpty) {
      _reporting?.cancel();
      _reporting = null;
    }
    if (sink == null) return;
    try {
      await sink.close();
      toMain.send(_Recorded(id, sink.count, finished: true));
    } on Object catch (error) {
      toMain.send(
        _Recorded(id, sink.count, finished: true, error: '$error'),
      );
    }
  }
}

/// The worker's end of a link relayed through the isolate that opened it.
class _RelayedLink implements EcuLink {
  _RelayedLink(this.description, this._toMain);

  @override
  final String description;
  final SendPort _toMain;
  final _incoming = StreamController<List<int>>.broadcast();
  var _open = true;

  void deliver(Uint8List bytes) {
    if (_open) _incoming.add(bytes);
  }

  void fail(String reason) {
    if (_open) _incoming.addError(EcuProtocolException(reason));
  }

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  void send(List<int> bytes) {
    if (!_open) throw StateError('send() on a closed link');
    _toMain.send(_RelayOut(Uint8List.fromList(bytes)));
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _incoming.close();
  }
}
