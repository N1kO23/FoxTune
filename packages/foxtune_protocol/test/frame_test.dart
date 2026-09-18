import 'dart:convert';
import 'dart:typed_data';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

/// Builds a valid frame the way the ECU would, for feeding to the decoder.
Uint8List ecuFrame(List<int> payload) => EcuFrame.encode(payload);

void main() {
  group('EcuFrame.encode', () {
    // Byte sequences cross-checked against Python: big-endian length and CRC,
    // matching the firmware's serialWrite(uint16_t) and reverse_bytes().
    test('wraps a single-byte command', () {
      expect(EcuFrame.encode(const [0x51]),
          [0x00, 0x01, 0x51, 0xCE, 0x6E, 0x8E, 0xEF]);
    });

    test('wraps a page-read command', () {
      // 'p' + page 1 + offset 0 + count 128, payload data little-endian.
      expect(
        EcuFrame.encode(const [0x70, 0x01, 0x00, 0x00, 0x00, 0x80, 0x00]),
        [
          0x00, 0x07, 0x70, 0x01, 0x00, 0x00, 0x00, 0x80, 0x00, //
          0x81, 0xDB, 0x44, 0xBB
        ],
      );
    });

    test('puts the length in big-endian order, not little', () {
      // 300 bytes: big-endian 0x012C. Little-endian would be 0x2C 0x01 and the
      // ECU would read a 11265-byte frame.
      final frame = EcuFrame.encode(List<int>.filled(300, 0xAA));
      expect(frame[0], 0x01);
      expect(frame[1], 0x2C);
      expect(frame.length, 300 + EcuFrame.overhead);
    });

    test('length excludes the CRC bytes', () {
      final frame = EcuFrame.encode(const [1, 2, 3]);
      final declared = (frame[0] << 8) | frame[1];
      expect(declared, 3);
      expect(frame.length, 3 + 6);
    });

    test('handles an empty payload', () {
      expect(EcuFrame.encode(const []).length, EcuFrame.overhead);
    });
  });

  group('EcuFrameDecoder', () {
    late EcuFrameDecoder decoder;

    setUp(() => decoder = EcuFrameDecoder());
    tearDown(() => decoder.close());

    test('decodes a well-formed response', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder.add(ecuFrame([0x00, ...ascii.encode('speeduino 202504-dev')]));
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.code, SerialResponse.ok);
      expect(ascii.decode(seen.single.data), 'speeduino 202504-dev');
    });

    test('reassembles a frame split across several reads', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      final frame = ecuFrame([0x00, 0x11, 0x22, 0x33]);
      // One byte at a time - the worst case a serial port can produce.
      for (final byte in frame) {
        decoder.add([byte]);
      }
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.data, [0x11, 0x22, 0x33]);
    });

    test('decodes several frames delivered in one read', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder.add([
        ...ecuFrame([0x00, 0xAA]),
        ...ecuFrame([0x00, 0xBB])
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(2));
      expect(seen[0].data, [0xAA]);
      expect(seen[1].data, [0xBB]);
    });

    test('surfaces error codes rather than treating them as data', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder.add(ecuFrame([0x84]));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.code, SerialResponse.rangeError);
      expect(seen.single.isOk, isFalse);
      expect(seen.single.data, isEmpty);
    });

    test('reports a busy response as retryable', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder.add(ecuFrame([0x85]));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.code, SerialResponse.busy);
      expect(seen.single.code!.isRetryable, isTrue);
    });

    test('keeps an unrecognised code available as a raw byte', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder.add(ecuFrame([0x7B]));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.code, isNull);
      expect(seen.single.rawCode, 0x7B);
    });

    test('rejects a frame whose CRC does not match', () async {
      final seen = <EcuResponse>[];
      final errors = <EcuFrameException>[];
      decoder.responses.listen(seen.add);
      decoder.errors.listen(errors.add);

      final corrupted = ecuFrame([0x00, 0x11, 0x22])..last ^= 0xFF;
      decoder.add(corrupted);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty, reason: 'a bad frame must never reach the caller');
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('CRC'));
    });

    test('detects corruption of the payload itself', () async {
      final seen = <EcuResponse>[];
      final errors = <EcuFrameException>[];
      decoder.responses.listen(seen.add);
      decoder.errors.listen(errors.add);

      final corrupted = ecuFrame([0x00, 0x11, 0x22])..[3] ^= 0x01;
      decoder.add(corrupted);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      expect(errors, hasLength(1));
    });

    test('recovers the next frame after a corrupted one', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      decoder
        ..add(ecuFrame([0x00, 0x11])..last ^= 0xFF)
        ..add(ecuFrame([0x00, 0x22]));
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1));
      expect(seen.single.data, [0x22]);
    });

    test('resynchronises instead of stalling on an implausible length',
        () async {
      final seen = <EcuResponse>[];
      final errors = <EcuFrameException>[];
      final small = EcuFrameDecoder(maxPayloadLength: 64);
      addTearDown(small.close);
      small.responses.listen(seen.add);
      small.errors.listen(errors.add);

      // The length prefix is outside the CRC's coverage, so a flipped bit here
      // is undetectable. Without a bound the decoder would wait forever.
      small
        ..add([0xFF, 0xFF])
        ..add(ecuFrame([0x00, 0x42]));
      await Future<void>.delayed(Duration.zero);

      expect(errors, isNotEmpty);
      expect(seen, hasLength(1),
          reason: 'the following good frame must still be recovered');
      expect(seen.single.data, [0x42]);
    });

    test('round-trips a payload of the maximum blocking factor', () async {
      final seen = <EcuResponse>[];
      decoder.responses.listen(seen.add);

      // 251 bytes is the Speeduino blockingFactor on a standard build.
      final payload = [0x00, ...List<int>.generate(251, (i) => i & 0xFF)];
      decoder.add(ecuFrame(payload));
      await Future<void>.delayed(Duration.zero);

      expect(seen.single.data, hasLength(251));
      expect(seen.single.data.last, 250);
    });
  });
}
