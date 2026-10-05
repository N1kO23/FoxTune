import 'dart:async';
import 'dart:typed_data';

import 'crc32.dart';
import 'response_code.dart';

/// The `msEnvelope_1.0` wire envelope used by the Speeduino serial protocol.
///
/// Layout, confirmed against the firmware's `comms.cpp`:
///
/// ```text
/// [length : uint16 big-endian] [payload : length bytes] [crc32 : big-endian]
/// ```
///
/// Two byte-order rules apply at once and are easy to confuse. The *envelope*
/// - the length prefix and the CRC - is big-endian, because the firmware's
/// `serialWrite(uint16_t)` emits `(value >> 8)` first and byte-reverses the CRC
/// before sending. The *payload data* is little-endian, as the .ini's
/// `endianness = little` declares. Mixing the two up yields frames the ECU
/// silently rejects.
///
/// [length] counts the payload only; the four CRC bytes sit outside it. The
/// CRC likewise covers the payload only, which means a corrupted length prefix
/// is undetectable - hence [EcuFrameDecoder.maxPayloadLength].
abstract final class EcuFrame {
  /// Bytes of envelope overhead: 2 length + 4 CRC.
  static const int overhead = 6;

  /// Wraps [payload] in a complete frame ready for transmission.
  static Uint8List encode(List<int> payload) {
    final frame = Uint8List(2 + payload.length + 4);
    final view = ByteData.view(frame.buffer);
    view.setUint16(0, payload.length, Endian.big);
    frame.setRange(2, 2 + payload.length, payload);
    view.setUint32(2 + payload.length, crc32(payload), Endian.big);
    return frame;
  }
}

/// A decoded response from the ECU.
class EcuResponse {
  const EcuResponse({
    required this.code,
    required this.rawCode,
    required this.data,
  });

  /// The decoded return code, or `null` if the firmware sent a byte this
  /// version does not recognise.
  final SerialResponse? code;

  /// The raw first payload byte, always available even when [code] is null.
  final int rawCode;

  /// Payload after the return code byte. Empty for acknowledgements.
  final Uint8List data;

  /// Whether the ECU reported success.
  bool get isOk => code?.isOk ?? false;

  @override
  String toString() =>
      'EcuResponse(${code?.name ?? '0x${rawCode.toRadixString(16)}'}, '
      '${data.length} bytes)';
}

/// Raised when a frame arrives that cannot be trusted.
class EcuFrameException implements Exception {
  EcuFrameException(this.message);

  final String message;

  @override
  String toString() => 'EcuFrameException: $message';
}

/// Reassembles [EcuResponse]s from an arbitrarily chunked byte stream.
///
/// Serial delivery gives no framing: one read may split a response in half or
/// carry several at once. This buffers until a whole frame is present, checks
/// its CRC, and emits the result.
class EcuFrameDecoder {
  EcuFrameDecoder({this.maxPayloadLength = 4096});

  /// Largest payload considered plausible.
  ///
  /// The length prefix sits outside the CRC's coverage, so a corrupted length
  /// cannot be detected directly. Without this bound, one flipped bit would
  /// make the decoder wait for up to 64KB that will never arrive and stall the
  /// connection. A frame claiming more than this is treated as desynchronised.
  final int maxPayloadLength;

  /// Bytes received and not yet decoded: those from [_read] up to [_write].
  ///
  /// One buffer, decoded in place: frames are read where they lie, and what
  /// is held is moved to the front - or the buffer grown - only when there is
  /// no room after it. Rebuilding the buffer from every chunk instead, as
  /// this once did, copied a frame over again for each piece it came in, and
  /// rusEFI's live data comes in pieces of a kilobyte, hundreds of times a
  /// second.
  var _bytes = Uint8List(1024);
  var _read = 0;
  var _write = 0;

  final _controller = StreamController<EcuResponse>.broadcast();

  /// Decoded responses, in arrival order.
  Stream<EcuResponse> get responses => _controller.stream;

  /// Errors are surfaced here rather than on [responses], so a single bad
  /// frame does not tear down the subscription.
  final _errors = StreamController<EcuFrameException>.broadcast();

  /// CRC failures and desynchronisation reports.
  Stream<EcuFrameException> get errors => _errors.stream;

  /// Feeds freshly received [bytes] into the decoder.
  void add(List<int> bytes) {
    _reserve(bytes.length);
    _bytes.setRange(_write, _write + bytes.length, bytes);
    _write += bytes.length;
    _drain();
  }

  /// Makes room for [count] more bytes after [_write].
  void _reserve(int count) {
    if (_write + count <= _bytes.length) return;
    final held = _write - _read;
    if (held + count <= _bytes.length) {
      // Overlapping, which setRange copes with when copying within a list.
      _bytes.setRange(0, held, _bytes, _read);
    } else {
      var capacity = _bytes.length * 2;
      while (capacity < held + count) {
        capacity *= 2;
      }
      _bytes = Uint8List(capacity)..setRange(0, held, _bytes, _read);
    }
    _read = 0;
    _write = held;
  }

  void _drain() {
    final data = _bytes;
    final view = ByteData.sublistView(data);

    while (true) {
      final available = _write - _read;
      if (available < 2) break;

      final length = view.getUint16(_read, Endian.big);

      if (length > maxPayloadLength) {
        // Unrecoverable without a resync marker, which this protocol lacks.
        // Drop one byte and retry so a stray byte cannot wedge the stream
        // permanently.
        _errors.add(EcuFrameException(
            'Implausible frame length $length (max $maxPayloadLength); '
            'resynchronising'));
        _read += 1;
        continue;
      }

      if (available < 2 + length + 4) break;

      final start = _read + 2;
      final payload = Uint8List.sublistView(data, start, start + length);
      final expected = view.getUint32(start + length, Endian.big);
      _read += 2 + length + 4;

      if (crc32(payload) != expected) {
        _errors.add(EcuFrameException(
            'CRC mismatch on a $length byte frame; discarding'));
        continue;
      }
      if (payload.isEmpty) {
        _errors.add(EcuFrameException('Empty frame; discarding'));
        continue;
      }

      _controller.add(EcuResponse(
        code: SerialResponse.fromByte(payload[0]),
        rawCode: payload[0],
        // Copied once, out of a buffer about to be reused.
        data: Uint8List.fromList(Uint8List.sublistView(payload, 1)),
      ));
    }

    // Everything decoded: start again from the front, with nothing to move.
    if (_read == _write) _read = _write = 0;
  }

  /// Discards any partially received frame.
  void reset() => _read = _write = 0;

  /// Releases the streams.
  Future<void> close() async {
    await _controller.close();
    await _errors.close();
  }
}
