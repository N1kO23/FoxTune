import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'ecu_link.dart';
import 'frame.dart';
import 'response_code.dart';

/// Carries out an [EcuClient]'s commands: sends each one, and waits for its
/// reply.
///
/// The protocol is strictly request/response with no request identifiers, so
/// exactly one command may be outstanding at a time. Callers need not care:
/// concurrent commands are queued and issued in order.
///
/// Behind an interface so the commands can be carried out somewhere else than
/// where they are asked for - on an isolate of their own, out of reach of
/// whatever keeps the asking isolate busy; see `EcuWorker`.
abstract interface class EcuCommandRunner {
  /// Sends [payload] and completes with the data of the reply, or fails with
  /// an [EcuProtocolException] - a rejection, a timeout after [timeout], or a
  /// dead link.
  Future<Uint8List> run(List<int> payload, {required Duration timeout});

  /// Frame-level failures observed since the last command completed. Useful
  /// for reporting link quality rather than for control flow.
  List<EcuFrameException> get recentFrameErrors;

  /// Fails anything queued, and stops. Does not close the link.
  Future<void> close();
}

/// [EcuCommandRunner] over an [EcuLink], on this isolate.
class LinkCommandRunner implements EcuCommandRunner {
  LinkCommandRunner(
    this._link, {
    this.maxRetries = 3,
    EcuFrameDecoder? decoder,
  }) : _decoder = decoder ?? EcuFrameDecoder() {
    _linkSubscription = _link.incoming.listen(
      _decoder.add,
      onError: _failPending,
      // A link that ends - a socket the bridge closed, a port unplugged -
      // will not answer what is in flight: fail it now rather than at its
      // timeout, so a lost link is noticed in moments.
      onDone: () => _failPending(
        EcuProtocolException('The link closed'),
        StackTrace.empty,
      ),
    );
    _responseSubscription = _decoder.responses.listen(_completePending);
    _errorSubscription = _decoder.errors.listen((e) {
      // A CRC failure means the reply is gone. Let the command time out and
      // be retried rather than resolving it with bad data.
      _frameErrors.add(e);
    });
  }

  final EcuLink _link;
  final EcuFrameDecoder _decoder;

  /// How many times a [SerialResponse.busy] reply is retried.
  final int maxRetries;

  late final StreamSubscription<List<int>> _linkSubscription;
  late final StreamSubscription<EcuResponse> _responseSubscription;
  late final StreamSubscription<EcuFrameException> _errorSubscription;

  final _queue = Queue<_PendingRequest>();
  final _frameErrors = <EcuFrameException>[];
  _PendingRequest? _inFlight;
  bool _closed = false;

  @override
  List<EcuFrameException> get recentFrameErrors =>
      List.unmodifiable(_frameErrors);

  @override
  Future<Uint8List> run(List<int> payload, {required Duration timeout}) {
    if (_closed) {
      return Future.error(EcuProtocolException('Client is closed'));
    }
    final request = _PendingRequest(payload, timeout: timeout);
    _queue.add(request);
    _pump();
    return request.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in [..._queue, if (_inFlight != null) _inFlight!]) {
      pending.fail(EcuProtocolException('Client closed'));
    }
    _queue.clear();
    _inFlight = null;
    await _linkSubscription.cancel();
    await _responseSubscription.cancel();
    await _errorSubscription.cancel();
    await _decoder.close();
  }

  void _pump() {
    if (_inFlight != null || _queue.isEmpty || _closed) return;
    final request = _queue.removeFirst();
    _inFlight = request;
    _frameErrors.clear();
    _dispatch(request);
  }

  void _dispatch(_PendingRequest request) {
    _decoder.reset();

    try {
      _link.send(EcuFrame.encode(request.payload));
    } on Object catch (error) {
      // A dead link throws synchronously from send(). Clearing _inFlight here
      // is essential: leaving it set would wedge the client permanently, with
      // every later command queued behind a request that can never complete.
      _inFlight = null;
      request.fail(EcuProtocolException('Link write failed: $error'));
      _pump();
      return;
    }

    final wait = request.timeout;
    request.timer = Timer(wait, () {
      if (!identical(_inFlight, request)) return;
      _inFlight = null;
      request.fail(EcuProtocolException(
          'Timed out after ${wait.inMilliseconds}ms waiting for a reply'
          '${_frameErrors.isEmpty ? '' : ' (${_frameErrors.length} bad frame(s))'}',
          response: SerialResponse.timeout));
      _pump();
    });
  }

  void _completePending(EcuResponse response) {
    final request = _inFlight;
    if (request == null) return;

    if (response.code?.isRetryable ?? false) {
      if (request.attempts < maxRetries) {
        request.attempts++;
        request.timer?.cancel();
        _dispatch(request);
        return;
      }
      _inFlight = null;
      request.fail(EcuProtocolException(
          'ECU stayed busy after ${request.attempts + 1} attempts',
          response: response.code));
      _pump();
      return;
    }

    _inFlight = null;
    request.timer?.cancel();

    if (!response.isOk) {
      request.fail(EcuProtocolException(
          'ECU rejected the command'
          '${response.code == null ? ' with unknown code 0x${response.rawCode.toRadixString(16)}' : ''}',
          response: response.code));
    } else {
      request.complete(response.data);
    }
    _pump();
  }

  void _failPending(Object error, StackTrace stack) {
    final request = _inFlight;
    _inFlight = null;
    request?.timer?.cancel();
    request?.fail(EcuProtocolException('Link failure: $error'));
    _pump();
  }
}

class _PendingRequest {
  _PendingRequest(this.payload, {required this.timeout});

  final List<int> payload;

  /// How long to wait for the reply.
  final Duration timeout;
  final _completer = Completer<Uint8List>();

  Timer? timer;
  int attempts = 0;

  Future<Uint8List> get future => _completer.future;

  void complete(Uint8List data) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.complete(data);
  }

  void fail(Object error) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}
