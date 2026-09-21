@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

/// Commands rendered from the real definitions, byte for byte.
///
/// The bytes here are what each firmware parses: Speeduino's page read is
/// `'p'`, the CAN id, the page, then offset and count little-endian; rusEFI's
/// is `'R'` and the page as the two identifier bytes the definition gives,
/// which its firmware reads as a little-endian word.
void main() {
  IniDocument load(String name) {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/$name'),
      File('../foxtune_ini/test/fixtures/$name'),
    ];
    return IniParser(defined: {'CELSIUS'}).parse(
      candidates.firstWhere((f) => f.existsSync()).readAsStringSync(),
    );
  }

  group('Speeduino', () {
    late EcuCommandSet commands;
    setUpAll(
      () => commands = EcuCommandSet.fromDefinition(load('speeduino.ini')),
    );

    test('reads a page as p, CAN id, page, offset, count', () {
      expect(commands.pageRead(2, 0x0102, 251), [
        0x70, 0, 2, 0x02, 0x01, 251, 0, //
      ]);
    });

    test('writes with M and the data after the header', () {
      expect(commands.pageWrite(1, 4, [9, 8]), [
        0x4D, 0, 1, 4, 0, 2, 0, 9, 8, //
      ]);
    });

    test('asks for a whole-page CRC by page alone', () {
      expect(commands.pageCrc(3), [0x64, 0, 3]);
    });

    test('reads realtime through the r sub-command', () {
      expect(commands.realtime(0, 139), [0x72, 0, 0x30, 0, 0, 139, 0]);
    });

    test('matches what the client sent before there was a command set', () {
      final fallback = EcuCommandSet.speeduino();
      for (var page = 1; page <= 15; page++) {
        expect(fallback.pageRead(page, 7, 9), commands.pageRead(page, 7, 9));
        expect(fallback.burn(page), commands.burn(page));
      }
    });
  });

  group('rusEFI', () {
    late IniDocument doc;
    late EcuCommandSet commands;
    setUpAll(() {
      doc = load('rusefi_uaefi.ini');
      commands = EcuCommandSet.fromDefinition(doc);
    });

    test('addresses pages by the identifier bytes the definition gives', () {
      // "\x00\x01" for the second page - page 0x0100 to the firmware.
      expect(commands.identifierOf(1), [0x00, 0x00]);
      expect(commands.identifierOf(2), [0x00, 0x01]);
      expect(commands.pageRead(2, 0x10, 0x20), [
        0x52, 0x00, 0x01, 0x10, 0x00, 0x20, 0x00, //
      ]);
    });

    test('writes with C', () {
      expect(commands.pageWrite(1, 0, [5]), [
        0x43, 0x00, 0x00, 0, 0, 1, 0, 5, //
      ]);
    });

    test('asks for the CRC of the whole page as a range', () {
      final size = doc.constants.pageSizes.first;
      expect(commands.pageCrc(1), [
        0x6B, 0x00, 0x00, 0, 0, size & 0xFF, size >> 8, //
      ]);
    });

    test('has no burn for its working-memory pages', () {
      expect(commands.burn(1), [0x42, 0x00, 0x00]);
      expect(commands.canBurn(2), isFalse);
      expect(commands.canBurn(3), isFalse);
      expect(commands.canBurn(4), isTrue);
    });

    test('reads realtime with O, in pieces no larger than a transfer', () {
      expect(commands.realtime(1024, 1024), [0x4F, 0, 4, 0, 4]);
      expect(commands.realtimeChunk, 1024);
      expect(doc.outputChannels.blockSize, greaterThan(commands.realtimeChunk));
    });

    test('waits as long as the definition says replies can take', () {
      expect(commands.timeout, const Duration(seconds: 3));
    });
  });

  test('refuses a placeholder it does not know', () {
    expect(
      () => EcuCommandSet().render('X%9q'),
      throwsA(isA<FormatException>()),
    );
  });
}
