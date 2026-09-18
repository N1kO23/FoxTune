import 'dart:async';

import 'ecu_client.dart';
import 'realtime_decoder.dart';
import 'response_code.dart';

/// Polls the ECU for realtime data and publishes decoded snapshots.
///
/// Requests are issued one at a time and the next poll is scheduled only after
/// the previous one settles. Firing on a fixed timer instead would queue
/// requests faster than a 115200-baud link can answer them, and latency would
/// grow without bound.
class RealtimeMonitor {
  RealtimeMonitor({
    required EcuClient client,
    required RealtimeDecoder decoder,
    this.interval = const Duration(milliseconds: 33),
    this.maxConsecutiveErrors = 5,
  })  : _client = client,
        _decoder = decoder;

  final EcuClient _client;
  final RealtimeDecoder _decoder;

  /// Target time between polls. 33ms is roughly 30 Hz.
  final Duration interval;

  /// How many failures in a row before the monitor gives up and stops.
  ///
  /// A single dropped frame is routine; a sustained run of them means the link
  /// is gone, and continuing to hammer it hides that from the user.
  final int maxConsecutiveErrors;

  final _snapshots = StreamController<RealtimeSnapshot>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// Decoded samples, newest last.
  Stream<RealtimeSnapshot> get snapshots => _snapshots.stream;

  /// Poll failures. Subscribing is optional; errors are not fatal on their own.
  Stream<Object> get errors => _errors.stream;

  bool _running = false;
  int _consecutiveErrors = 0;
  int _pollCount = 0;
  DateTime? _rateWindowStart;
  int _rateWindowCount = 0;
  double _measuredHz = 0;

  /// Whether polling is active.
  bool get isRunning => _running;

  /// Total successful polls since [start].
  int get pollCount => _pollCount;

  /// Achieved poll rate, averaged over the last second.
  ///
  /// This is the honest number: it reflects what the link actually sustained,
  /// which on a slow connection is well below the requested rate.
  double get measuredHz => _measuredHz;

  /// Begins polling. Does nothing if already running.
  void start() {
    if (_running) return;
    _running = true;
    _consecutiveErrors = 0;
    _rateWindowStart = DateTime.now();
    _rateWindowCount = 0;
    unawaited(_loop());
  }

  /// Stops polling. Safe to call when not running.
  Future<void> stop() async {
    _running = false;
  }

  /// Stops polling and releases the streams.
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
        final block = await _client.readRealtime(count: count);
        if (!_running) return;

        _consecutiveErrors = 0;
        _pollCount++;
        _recordRate();
        if (!_snapshots.isClosed) {
          _snapshots.add(_decoder.decode(block, timestamp: started));
        }
      } on Object catch (error) {
        if (!_running) return;
        _consecutiveErrors++;
        if (!_errors.isClosed) _errors.add(error);

        if (_consecutiveErrors >= maxConsecutiveErrors) {
          _running = false;
          if (!_errors.isClosed) {
            _errors.add(EcuProtocolException(
                'Stopped polling after $_consecutiveErrors consecutive '
                'failures'));
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
