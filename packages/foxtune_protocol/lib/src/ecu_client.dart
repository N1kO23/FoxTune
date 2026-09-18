import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'ecu_link.dart';
import 'frame.dart';
import 'response_code.dart';
import 'speeduino_constants.dart';

/// What an ECU reported about itself during the handshake.
class EcuIdentification {
  const EcuIdentification({required this.signature, required this.version});

  /// The signature string, e.g. `speeduino 202504-dev`. This is what must be
  /// matched against the loaded `.ini` before any write is permitted.
  final String signature;

  /// The human-readable version string.
  final String version;

  @override
  String toString() => 'EcuIdentification($signature, $version)';
}

/// Speaks the Speeduino protocol over an [EcuLink].
///
/// The protocol is strictly request/response with no request identifiers, so
/// exactly one command may be outstanding at a time. Callers need not care:
/// concurrent calls are queued and issued in order.
class EcuClient {
  EcuClient(
    this._link, {
    this.timeout = const Duration(milliseconds: 1000),
    this.maxRetries = 3,
    this.canId = 0,
    EcuFrameDecoder? decoder,
  }) : _decoder = decoder ?? EcuFrameDecoder() {
    _linkSubscription = _link.incoming.listen(
      _decoder.add,
      onError: _failPending,
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

  /// How long to wait for a reply before giving up on a command.
  final Duration timeout;

  /// How many times a [SerialResponse.busy] reply is retried.
  final int maxRetries;

  /// CAN id this ECU answers on. Substituted for `$tsCanId` in templates.
  final int canId;

  late final StreamSubscription<List<int>> _linkSubscription;
  late final StreamSubscription<EcuResponse> _responseSubscription;
  late final StreamSubscription<EcuFrameException> _errorSubscription;

  final _queue = Queue<_PendingRequest>();
  final _frameErrors = <EcuFrameException>[];
  _PendingRequest? _inFlight;
  bool _closed = false;

  /// Frame-level failures observed since the last command completed. Useful
  /// for reporting link quality rather than for control flow.
  List<EcuFrameException> get recentFrameErrors =>
      List.unmodifiable(_frameErrors);

  // --- Public commands -----------------------------------------------------

  /// Asks the ECU to identify itself and returns both strings.
  ///
  /// This is the whole of the connection handshake. The returned
  /// [EcuIdentification.signature] must be checked against the loaded
  /// definition before anything is written.
  Future<EcuIdentification> identify() async {
    final signature = await readSignature();
    final version = await queryVersion();
    return EcuIdentification(signature: signature, version: version);
  }

  /// Sends `S` and returns the signature string.
  Future<String> readSignature() async =>
      _asciiOf(await _command([SpeeduinoCommand.signature]));

  /// Sends `Q` and returns the version string.
  Future<String> queryVersion() async =>
      _asciiOf(await _command([SpeeduinoCommand.query]));

  /// Reads [count] bytes from configuration [page] starting at [offset].
  ///
  /// Transfers larger than [blockingFactor] are split automatically. The
  /// firmware does not reject an oversized request cleanly, so chunking here
  /// is mandatory rather than an optimisation.
  Future<Uint8List> readPage(
    int page, {
    required int count,
    required int blockingFactor,
    int offset = 0,
  }) async {
    if (blockingFactor <= 0) {
      throw ArgumentError.value(
          blockingFactor, 'blockingFactor', 'must be positive');
    }
    final result = Uint8List(count);
    var read = 0;
    while (read < count) {
      final chunk =
          count - read < blockingFactor ? count - read : blockingFactor;
      final data = await _command([
        SpeeduinoCommand.pageRead,
        ..._uint16le(page),
        ..._uint16le(offset + read),
        ..._uint16le(chunk),
      ]);
      if (data.length != chunk) {
        throw EcuProtocolException(
            'Page $page: asked for $chunk bytes at ${offset + read}, '
            'got ${data.length}');
      }
      result.setRange(read, read + chunk, data);
      read += chunk;
    }
    return result;
  }

  /// Writes [data] into configuration [page] at [offset], in RAM only.
  ///
  /// Nothing is persisted until [burnPage]. Transfers are split to
  /// [blockingFactor] for the same reason reads are: the firmware does not
  /// reject an oversized write cleanly.
  Future<void> writePage(
    int page, {
    required List<int> data,
    required int blockingFactor,
    int offset = 0,
  }) async {
    if (blockingFactor <= 0) {
      throw ArgumentError.value(
          blockingFactor, 'blockingFactor', 'must be positive');
    }
    var written = 0;
    while (written < data.length) {
      final remaining = data.length - written;
      final chunk = remaining < blockingFactor ? remaining : blockingFactor;
      await _command([
        SpeeduinoCommand.pageWrite,
        ..._uint16le(page),
        ..._uint16le(offset + written),
        ..._uint16le(chunk),
        ...data.sublist(written, written + chunk),
      ]);
      written += chunk;
    }
  }

  /// Commits [page] from RAM to EEPROM.
  ///
  /// [burnCommand] selects the variant the definition declares - `b` normally,
  /// `B` on COMMS_COMPAT builds, which deliberately slow the EEPROM write.
  Future<void> burnPage(int page,
      {int burnCommand = SpeeduinoCommand.burn}) async {
    await _command([burnCommand, ..._uint16le(page)]);
  }

  /// Asks the ECU for the CRC-32 of a whole page.
  ///
  /// Comparing this with a locally computed CRC is a far stronger check that a
  /// write landed than re-reading and comparing, and it costs one short
  /// command instead of a full page transfer.
  Future<int> pageCrc(int page) async {
    final data = await _command([SpeeduinoCommand.pageCrc, ..._uint16le(page)]);
    if (data.length < 4) {
      throw EcuProtocolException(
          'Page CRC reply was ${data.length} bytes, expected 4');
    }
    // The envelope is big-endian and so is this value.
    return ByteData.sublistView(data).getUint32(0, Endian.big);
  }

  /// Fetches [count] bytes of the realtime data block.
  ///
  /// The field layout comes from the definition's `[OutputChannels]`; this
  /// returns the raw block.
  Future<Uint8List> readRealtime({required int count, int offset = 0}) =>
      _command([
        SpeeduinoCommand.realtime,
        canId,
        SpeeduinoCommand.realtimeSubCommand,
        ..._uint16le(offset),
        ..._uint16le(count),
      ]);

  /// Sends an arbitrary payload and returns the response data.
  ///
  /// Exposed for commands this class does not model yet.
  Future<Uint8List> send(List<int> payload) => _command(payload);

  /// Closes the client. Does not close the underlying link.
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

  // --- Request plumbing ----------------------------------------------------

  Future<Uint8List> _command(List<int> payload) {
    if (_closed) {
      return Future.error(EcuProtocolException('Client is closed'));
    }
    final request = _PendingRequest(payload);
    _queue.add(request);
    _pump();
    return request.future;
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

    request.timer = Timer(timeout, () {
      if (!identical(_inFlight, request)) return;
      _inFlight = null;
      request.fail(EcuProtocolException(
          'Timed out after ${timeout.inMilliseconds}ms waiting for a reply'
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

  static List<int> _uint16le(int value) => [value & 0xFF, (value >> 8) & 0xFF];

  static String _asciiOf(Uint8List bytes) {
    // The firmware pads some strings with NULs; trim them rather than letting
    // them into a UI label.
    final end = bytes.indexOf(0);
    final slice = end < 0 ? bytes : bytes.sublist(0, end);
    return ascii.decode(slice, allowInvalid: true).trim();
  }
}

class _PendingRequest {
  _PendingRequest(this.payload);

  final List<int> payload;
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
