import 'dart:async';

import 'package:foxtune_ini/foxtune_ini.dart';

import 'ecu_client.dart';
import 'realtime_decoder.dart';
import 'response_code.dart';
import 'trigger_log.dart';

/// Runs one of the ECU's high-speed loggers: starts it, reads each capture
/// once the ECU has one, and stops it again.
///
/// The ECU says a capture is ready through a live-data flag - the logger's
/// `dataReadyCondition`, `toothLog1Ready == 1` for Speeduino - so this
/// watches the live data the dashboard already polls for rather than asking
/// separately. A capture that never fills, from an engine that is not
/// turning, is read anyway once the logger's `dataReadTimeout` has passed:
/// Speeduino answers with what it has, and an empty capture says as much as
/// a full one.
///
/// Every command is the definition's own, rendered as the page commands are,
/// so this runs Speeduino's loggers and rusEFI's alike.
class TriggerLogger {
  TriggerLogger({
    required EcuClient client,
    required this.logger,
    required Stream<RealtimeSnapshot> snapshots,
    Duration? readTimeout,
  })  : _client = client,
        _snapshots = snapshots,
        _readTimeout = readTimeout ?? logger.readTimeout ?? _defaultTimeout,
        _ready = logger.readyCondition == null
            ? null
            : CompiledExpression.tryCompile(logger.readyCondition!);

  static const _defaultTimeout = Duration(seconds: 5);

  final EcuClient _client;
  final Stream<RealtimeSnapshot> _snapshots;
  final Duration _readTimeout;
  final CompiledExpression? _ready;

  /// The logger this runs.
  final IniLogger logger;

  final _captures = StreamController<TriggerLog>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  StreamSubscription<RealtimeSnapshot>? _subscription;
  Timer? _timer;
  Future<void>? _reading;
  bool _running = false;

  /// When the last read finished, or the logger started. A live sample taken
  /// before then may still show the flag that read cleared.
  DateTime _since = DateTime.now();

  /// Each capture, as it is read.
  Stream<TriggerLog> get captures => _captures.stream;

  /// Failed reads. The logger keeps going after one.
  Stream<Object> get errors => _errors.stream;

  /// Whether the logger is running.
  bool get isRunning => _running;

  /// Starts the logger on the ECU, and reading from it.
  Future<void> start() async {
    if (_running) return;
    await _sendTemplate(logger.startCommand);
    _running = true;
    _since = DateTime.now();
    _subscription = _snapshots.listen(_onSnapshot);
    _armTimeout();
  }

  /// Stops reading, and stops the logger on the ECU.
  ///
  /// A read already under way is let finish first, so the stop command is
  /// not answered in its place.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    await _subscription?.cancel();
    _subscription = null;
    await _reading;
    await _sendTemplate(logger.stopCommand);
  }

  /// Stops the logger, if the link still allows, and closes the streams.
  Future<void> dispose() async {
    try {
      await stop();
    } on Object {
      // The link is gone; the ECU stops its logger when it next restarts.
    }
    await _captures.close();
    await _errors.close();
  }

  void _onSnapshot(RealtimeSnapshot snapshot) {
    if (!_running || _reading != null) return;
    if (!snapshot.timestamp.isAfter(_since)) return;
    final ready = _ready?.evaluate(snapshot.value);
    if (ready != null && ready != 0) _read();
  }

  void _armTimeout() {
    _timer?.cancel();
    _timer = Timer(_readTimeout, () {
      if (_running && _reading == null) _read();
    });
  }

  void _read() {
    _timer?.cancel();
    _reading = _readOnce().whenComplete(() {
      _reading = null;
      _since = DateTime.now();
      if (_running) _armTimeout();
    });
  }

  Future<void> _readOnce() async {
    final template = logger.readCommand;
    if (template == null) return;
    try {
      final data = await _client.send(
        _client.commands.render(template),
        // A whole capture is several hundred bytes; at 115200 baud that is
        // most of a normal reply's wait on its own.
        timeout: _client.timeout < _readReplyTimeout
            ? _readReplyTimeout
            : _client.timeout,
      );
      if (!_running || _captures.isClosed) return;
      _captures.add(TriggerLog.decode(logger, data));
      if (!logger.continuousRead) {
        unawaited(stop().catchError((Object error) => _report(error)));
      }
    } on EcuProtocolException catch (error) {
      // rusEFI answers a read with no capture ready with a range error,
      // which only means there is nothing yet.
      if (error.response == SerialResponse.rangeError) return;
      _report(error);
    } on Object catch (error) {
      _report(error);
    }
  }

  static const _readReplyTimeout = Duration(seconds: 2);

  void _report(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  Future<void> _sendTemplate(String? template) async {
    if (template == null || template.trim().isEmpty) return;
    await _client.send(_client.commands.render(template));
  }
}
