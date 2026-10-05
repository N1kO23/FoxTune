import 'dart:async';
import 'dart:typed_data';

import 'ecu_client.dart';
import 'realtime_decoder.dart';
import 'realtime_plan.dart';
import 'realtime_source.dart';
import 'response_code.dart';

/// Polls the ECU for realtime data and publishes decoded snapshots.
///
/// Requests are issued one at a time and the next poll is scheduled only after
/// the previous one settles. Firing on a fixed timer instead would queue
/// requests faster than a 115200-baud link can answer them, and latency would
/// grow without bound.
class RealtimeMonitor implements RealtimeSource {
  RealtimeMonitor({
    required EcuClient client,
    required RealtimeDecoder decoder,
    this.interval = const Duration(milliseconds: 33),
    this.maxConsecutiveErrors = 5,
    this.plan,
  })  : _client = client,
        _decoder = decoder;

  /// Which parts of the block each poll reads; the whole of it, without one.
  final RealtimeReadPlan? plan;

  @override
  bool readWholeBlock = false;

  final EcuClient _client;
  final RealtimeDecoder _decoder;

  /// Target time between polls. 33ms is roughly 30 Hz.
  @override
  final Duration interval;

  /// How many failures in a row before the monitor gives up and stops.
  ///
  /// A single dropped frame is routine; a sustained run of them means the link
  /// is gone, and continuing to hammer it hides that from the user.
  final int maxConsecutiveErrors;

  final _snapshots = StreamController<RealtimeSnapshot>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  @override
  Stream<RealtimeSnapshot> get snapshots => _snapshots.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  RealtimeSnapshot? get latest => _latest;
  RealtimeSnapshot? _latest;

  bool _running = false;
  int _consecutiveErrors = 0;
  int _pollCount = 0;
  DateTime? _rateWindowStart;
  int _rateWindowCount = 0;
  double _measuredHz = 0;

  @override
  bool get isRunning => _running;

  @override
  int get pollCount => _pollCount;

  @override
  double get measuredHz => _measuredHz;

  @override
  void start() {
    if (_running) return;
    _running = true;
    _consecutiveErrors = 0;
    _rateWindowStart = DateTime.now();
    _rateWindowCount = 0;
    unawaited(_loop());
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
    await _errors.close();
  }

  Future<void> _loop() async {
    final count = _decoder.blockSize;
    if (count == null || count <= 0) {
      _errors.add(StateError(
          'The definition declares no ochBlockSize, so the realtime block '
          'size is unknown.'));
      _running = false;
      return;
    }

    while (_running) {
      final started = DateTime.now();
      try {
        final spans = readWholeBlock ? null : plan?.next();
        final Uint8List block;
        if (spans == null) {
          block = await _client.readRealtime(count: count);
        } else {
          // The parts asked for, each where it lies in the block.
          block = Uint8List(count);
          for (final span in spans) {
            final part = await _client.readRealtime(
              offset: span.offset,
              count: span.length,
            );
            block.setRange(span.offset, span.end, part);
          }
        }
        if (!_running) return;

        _consecutiveErrors = 0;
        _pollCount++;
        _recordRate();
        if (!_snapshots.isClosed) {
          _snapshots.add(
            _latest = _decoder.decode(
              block,
              timestamp: started,
              coverage: spans,
            ),
          );
        }
      } on Object catch (error) {
        if (!_running) return;
        _consecutiveErrors++;
        if (!_errors.isClosed) _errors.add(error);

        if (_consecutiveErrors >= maxConsecutiveErrors) {
          _running = false;
          if (!_errors.isClosed) {
            _errors.add(RealtimeLinkLost(_consecutiveErrors, cause: error));
          }
          return;
        }
      }

      // Sleep only for whatever is left of the interval, so a slow reply does
      // not compound into an even slower poll rate.
      final elapsed = DateTime.now().difference(started);
      final remaining = interval - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
  }

  void _recordRate() {
    _rateWindowCount++;
    final start = _rateWindowStart;
    if (start == null) return;
    final elapsed = DateTime.now().difference(start);
    if (elapsed >= const Duration(seconds: 1)) {
      _measuredHz = _rateWindowCount / (elapsed.inMilliseconds / 1000);
      _rateWindowStart = DateTime.now();
      _rateWindowCount = 0;
    }
  }
}

/// The realtime monitor has stopped, because the ECU stopped answering.
///
/// Emitted once on [RealtimeMonitor.errors] when polling gives up, as a type
/// of its own so a caller can tell "the link is gone" from the ordinary
/// one-off failures that come before it. A pulled USB cable, a flat battery
/// and a crashed firmware all end here.
class RealtimeLinkLost extends EcuProtocolException {
  RealtimeLinkLost(this.failures, {this.cause})
      : super('Stopped polling after $failures consecutive failures');

  /// Consecutive failed polls that led to giving up.
  final int failures;

  /// The last failure, for diagnostics.
  final Object? cause;
}
