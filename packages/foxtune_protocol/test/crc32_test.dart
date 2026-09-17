import 'dart:convert';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('crc32', () {
    // Reference values cross-checked against Python's zlib.crc32, which
    // implements the same CRC-32/ISO-HDLC variant as the firmware's library.
    test('matches known CRC-32/ISO-HDLC vectors', () {
      expect(crc32(const <int>[]), 0x00000000);
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
      expect(
        crc32(ascii.encode('The quick brown fox jumps over the lazy dog')),
        0x414FA339,
      );
    });

    test('computes incrementally across chunks', () {
      final whole = crc32(ascii.encode('123456789'));
      final chunked = crc32(
        ascii.encode('6789'),
        crc32(ascii.encode('12345')),
      );
      expect(chunked, whole);
    });

    test('checksums a page-read frame', () {
      // 'p' + page 1 + offset 0 + count 128, little-endian throughout.
      const frame = <int>[0x70, 0x01, 0x00, 0x00, 0x00, 0x80, 0x00];
      expect(crc32(frame), 0x81DB44BB);
    });

    test('always yields a value inside the unsigned 32-bit range', () {
      for (var i = 0; i < 256; i++) {
        final value = crc32(<int>[i, 0xFF, i]);
        expect(value, inInclusiveRange(0, 0xFFFFFFFF));
      }
    });
  });
}
