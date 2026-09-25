import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

import 'command_set.dart';
import 'ecu_link.dart';
import 'frame.dart';
import 'response_code.dart';

/// Which firmware an ECU runs, as far as its handshake tells.
enum EcuFamily {
  speeduino,
  rusefi,

  /// Something else that speaks the TunerStudio protocol, such as a
  /// MegaSquirt.
  other;

  /// The family a signature belongs to.
  static EcuFamily of(String signature) {
    final lower = signature.trim().toLowerCase();
    if (lower.startsWith('rusefi')) return rusefi;
    if (lower.startsWith('speeduino')) return speeduino;
    return other;
  }
}

/// What an ECU reported about itself during the handshake.
class EcuIdentification {
  const EcuIdentification({
    required this.signature,
    required this.version,
    EcuFamily? family,
  }) : _family = family;

  /// The signature string, e.g. `speeduino 202504-dev` or
  /// `rusEFI master.2026.09.21.uaefi.419928595`. This is what must be matched
  /// against the loaded `.ini` before any write is permitted.
  final String signature;

  /// The human-readable version string.
  final String version;

  final EcuFamily? _family;

  /// Which firmware this is.
  EcuFamily get family => _family ?? EcuFamily.of(signature);

  @override
  String toString() => 'EcuIdentification($signature, $version)';
}

/// Speaks the TunerStudio serial protocol over an [EcuLink].
///
/// The envelope - length, payload, CRC-32 - is the same for every ECU this
/// supports. What differs is the commands inside it, which come from the
/// definition through [commands]: until a definition is loaded they are
/// Speeduino's.
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
    EcuCommandSet? commands,
    EcuFrameDecoder? decoder,
  })  : commands = commands ?? EcuCommandSet.speeduino(canId: canId),
        _decoder = decoder ?? EcuFrameDecoder() {
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

  /// How pages and live data are addressed. Set once the definition for this
  /// ECU is known - see [useDefinition].
  EcuCommandSet commands;

  /// Switches to the commands [definition] declares, and to its reply
  /// timeout where that is longer than the current one.
  void useDefinition(IniDocument definition) {
    commands = EcuCommandSet.fromDefinition(definition, canId: canId);
    final declared = commands.timeout;
    if (declared != null && declared > timeout) timeout = declared;
  }

  final EcuLink _link;
  final EcuFrameDecoder _decoder;

  /// How long to wait for a reply before giving up on a command.
  Duration timeout;

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
  /// This is the whole of the connection handshake, and it has to work before
  /// FoxTune knows which firmware it is talking to - so it only uses what
  /// every supported ECU understands. Both answer `S`, with different things:
  /// rusEFI with its signature (its `queryCommand`), Speeduino with its
  /// display string. So `S` goes first. A reply that starts "rusEFI" is the
  /// signature, and `V` gives the version; anything else is a display string,
  /// and `Q` gives the signature - the command Speeduino's definition names as
  /// its `queryCommand`, which MegaSquirt shares.
  ///
  /// The returned [EcuIdentification.signature] must be checked against the
  /// loaded definition before anything is written.
  Future<EcuIdentification> identify() async {
    final hello = _asciiOf(await _command(const [_hello]));
    if (EcuFamily.of(hello) == EcuFamily.rusefi) {
      String version;
      try {
        version = _asciiOf(await _command(const [_rusEfiVersion]));
      } on EcuProtocolException {
        // Only the title bar needs it; an older build that does not answer
        // is still the ECU its signature says it is.
        version = hello;
      }
      return EcuIdentification(
        signature: hello,
        version: version,
        family: EcuFamily.rusefi,
      );
    }
    final signature = _asciiOf(await _command(const [_query]));
    return EcuIdentification(signature: signature, version: hello);
  }

  static const _hello = 0x53; // 'S'
  static const _query = 0x51; // 'Q'
  static const _rusEfiVersion = 0x56; // 'V'

  /// Reads [count] bytes from configuration [page] starting at [offset].
  ///
  /// Transfers larger than the blocking factor - [blockingFactor], or the
  /// definition's - are split automatically. Firmware does not reject an
  /// oversized request cleanly, so chunking here is mandatory rather than an
  /// optimisation.
  Future<Uint8List> readPage(
    int page, {
    required int count,
    int? blockingFactor,
    int offset = 0,
  }) async {
    final chunkLimit = _chunkLimit(blockingFactor ?? commands.blockingFactor);
    final result = Uint8List(count);
    var read = 0;
    while (read < count) {
      final chunk = count - read < chunkLimit ? count - read : chunkLimit;
      final data = await _command(
        commands.pageRead(page, offset + read, chunk),
      );
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
  /// Nothing is persisted until [burnPage]. Transfers are split to the
  /// blocking factor for the same reason reads are.
  Future<void> writePage(
    int page, {
    required List<int> data,
    int? blockingFactor,
    int offset = 0,
  }) async {
    final chunkLimit = _chunkLimit(blockingFactor ?? commands.blockingFactor);
    var written = 0;
    while (written < data.length) {
      final remaining = data.length - written;
      final chunk = remaining < chunkLimit ? remaining : chunkLimit;
      await _command(commands.pageWrite(
        page,
        offset + written,
        data.sublist(written, written + chunk),
      ));
      written += chunk;
    }
  }

  static int _chunkLimit(int blockingFactor) {
    if (blockingFactor <= 0) {
      throw ArgumentError.value(
          blockingFactor, 'blockingFactor', 'must be positive');
    }
    return blockingFactor;
  }

  /// Commits [page] from RAM to permanent storage.
  ///
  /// Returns `false`, sending nothing, for a page the definition gives no burn
  /// command: working memory that takes effect as it is written.
  Future<bool> burnPage(int page) async {
    final command = commands.burn(page);
    if (command == null) return false;
    await _command(command);
    return true;
  }

  /// Asks the ECU for the CRC-32 of a whole page.
  ///
  /// Comparing this with a locally computed CRC is a far stronger check that a
  /// write landed than re-reading and comparing, and it costs one short
  /// command instead of a full page transfer.
  Future<int> pageCrc(int page) async {
    final command = commands.pageCrc(page);
    if (command == null) {
      throw EcuProtocolException(
          'The definition gives no way to check page $page');
    }
    final data = await _command(command);
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
  /// returns the raw block. A block larger than one transfer - rusEFI's is -
  /// is fetched in pieces and joined.
  Future<Uint8List> readRealtime({required int count, int offset = 0}) async {
    final chunkLimit = _chunkLimit(commands.realtimeChunk);
    if (count <= chunkLimit) {
      return _command(commands.realtime(offset, count));
    }
    final result = Uint8List(count);
    var read = 0;
    while (read < count) {
      final chunk = count - read < chunkLimit ? count - read : chunkLimit;
      final data = await _command(commands.realtime(offset + read, chunk));
      if (data.length != chunk) {
        throw EcuProtocolException(
            'Realtime: asked for $chunk bytes at ${offset + read}, '
            'got ${data.length}');
      }
      result.setRange(read, read + chunk, data);
      read += chunk;
    }
    return result;
  }

  /// Sends an arbitrary payload and returns the response data.
  ///
  /// Exposed for commands this class does not model yet. [timeout] replaces
  /// [EcuClient.timeout] for this one command, for one the ECU answers only
  /// once it has done something slow - saved to its EEPROM, say.
  Future<Uint8List> send(List<int> payload, {Duration? timeout}) =>
      _command(payload, timeout: timeout);

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

  Future<Uint8List> _command(List<int> payload, {Duration? timeout}) {
    if (_closed) {
      return Future.error(EcuProtocolException('Client is closed'));
    }
    final request = _PendingRequest(payload, timeout: timeout);
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

    final wait = request.timeout ?? timeout;
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

  static String _asciiOf(Uint8List bytes) {
    // The firmware pads some strings with NULs; trim them rather than letting
    // them into a UI label.
    final end = bytes.indexOf(0);
    final slice = end < 0 ? bytes : bytes.sublist(0, end);
    return ascii.decode(slice, allowInvalid: true).trim();
  }
}

class _PendingRequest {
  _PendingRequest(this.payload, {this.timeout});

  final List<int> payload;

  /// How long to wait for this one's reply, where not the client's usual.
  final Duration? timeout;
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
