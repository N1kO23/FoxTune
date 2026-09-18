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

  final _buffer = BytesBuilder(copy: false);
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
    _buffer.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _drain();
  }

  void _drain() {
    final data = _buffer.toBytes();
    var consumed = 0;

    while (true) {
      final available = data.length - consumed;
      if (available < 2) break;

      final length =
          ByteData.view(data.buffer, data.offsetInBytes + consumed, 2)
              .getUint16(0, Endian.big);

      if (length > maxPayloadLength) {
        // Unrecoverable without a resync marker, which this protocol lacks.
        // Drop one byte and retry so a stray byte cannot wedge the stream
        // permanently.
        _errors.add(EcuFrameException(
            'Implausible frame length $length (max $maxPayloadLength); '
            'resynchronising'));
        consumed += 1;
        continue;
      }

      if (available < 2 + length + 4) break;

      final start = consumed + 2;
      final payload = Uint8List.sublistView(data, start, start + length);
      final expected =
          ByteData.view(data.buffer, data.offsetInBytes + start + length, 4)
              .getUint32(0, Endian.big);
      consumed += 2 + length + 4;

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
        data: Uint8List.fromList(payload.sublist(1)),
      ));
    }

    if (consumed > 0) {
      final remainder = data.sublist(consumed);
      _buffer
        ..clear()
        ..add(remainder);
    }
  }

  /// Discards any partially received frame.
  void reset() => _buffer.clear();

  /// Releases the streams.
  Future<void> close() async {
    await _controller.close();
    await _errors.close();
  }
}
