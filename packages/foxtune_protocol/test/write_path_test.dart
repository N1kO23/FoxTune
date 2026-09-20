@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// The write path, end to end against the simulator over a real socket.
///
/// These are the commands that can damage an engine, so the assertions are
/// about exactness: the right bytes at the right offsets, nothing persisted
/// without a burn, and a verifiable CRC afterwards.
void main() {
  late FakeSpeeduino ecu;
  late SocketEcuLink link;
  late EcuClient client;

  setUp(() async {
    ecu = FakeSpeeduino();
    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2));
  });

  tearDown(() async {
    await client.close();
    await link.close();
    await ecu.stop();
  });

  group('writePage', () {
    test('writes bytes at the requested offset', () async {
      final data = List<int>.generate(16, (i) => 0xA0 + i);
      await client.writePage(1, data: data, offset: 8, blockingFactor: 251);

      expect(ecu.pages[0].sublist(8, 24), data);
    });

    test('leaves the rest of the page untouched', () async {
      final before = Uint8List.fromList(ecu.pages[0]);
      await client.writePage(1,
          data: [1, 2, 3], offset: 4, blockingFactor: 251);

      expect(ecu.pages[0].sublist(0, 4), before.sublist(0, 4));
      expect(ecu.pages[0].sublist(7), before.sublist(7));
    });

    test('chunks a write larger than the blocking factor', () async {
      // Page 2 is 288 bytes, larger than the 251-byte blocking factor.
      final data = List<int>.generate(288, (i) => i & 0xFF);
      await client.writePage(2, data: data, blockingFactor: 251);

      expect(ecu.pages[1], data);
      final writes = ecu.requests
          .where((r) => r[0] == SpeeduinoCommand.pageWrite)
          .toList();
      expect(writes, hasLength(2), reason: 'must split into 251 + 37');
      expect(writes[0][5] | (writes[0][6] << 8), 251);
      expect(writes[1][3] | (writes[1][4] << 8), 251, reason: 'second offset');
      expect(writes[1][5] | (writes[1][6] << 8), 37);
    });

    test('sends the page identifier, then offset and count little-endian',
        () async {
      await client.writePage(1, data: [0xFF], offset: 2, blockingFactor: 251);
      final write =
          ecu.requests.firstWhere((r) => r[0] == SpeeduinoCommand.pageWrite);
      // CAN id, then page - the firmware reads the page from byte 2, so this
      // is not a little-endian page number.
      expect(
          write.sublist(0, 7), [SpeeduinoCommand.pageWrite, 0, 1, 2, 0, 1, 0]);
    });

    test('rejects an out-of-range page', () async {
      await expectLater(
        client.writePage(99, data: [1], blockingFactor: 251),
        throwsA(isA<EcuProtocolException>()
            .having((e) => e.response, 'response', SerialResponse.rangeError)),
      );
    });

    test('rejects a write past the end of a page', () async {
      await expectLater(
        client.writePage(1, data: [1, 2], offset: 127, blockingFactor: 251),
        throwsA(isA<EcuProtocolException>()),
      );
    });

    test('does not persist anything without a burn', () async {
      await client.writePage(1, data: [1, 2, 3], blockingFactor: 251);

      expect(ecu.ramDirty, contains(1));
      expect(ecu.burnedPages, isEmpty,
          reason: 'a write alone must never commit to EEPROM');
    });
  });

  group('burnPage', () {
    test('commits a page and reports success', () async {
      await client.writePage(1, data: [9], blockingFactor: 251);
      await client.burnPage(1);

      expect(ecu.burnedPages, contains(1));
      expect(ecu.ramDirty, isEmpty);
    });

    test('accepts the COMMS_COMPAT variant', () async {
      await client.burnPage(2, burnCommand: SpeeduinoCommand.burnCompat);
      expect(ecu.burnedPages, contains(2));
    });

    test('treats burnOk as success rather than an error', () async {
      // The firmware answers 0x04, not 0x00, so a client that only accepts
      // 0x00 would report every successful burn as a failure.
      await expectLater(client.burnPage(1), completes);
    });

    test('rejects an out-of-range page', () async {
      await expectLater(
        client.burnPage(99),
        throwsA(isA<EcuProtocolException>()),
      );
    });
  });

  group('page identifier', () {
    test('a little-endian page number is rejected, not silently accepted',
        () async {
      // The regression: we sent the page as a little-endian integer, which
      // puts it in the CAN id slot and leaves the firmware reading page 0.
      // Realtime worked, so it looked fine - only the pages came back wrong.
      // The simulator must refuse this, or it cannot catch a recurrence.
      await expectLater(
        // 'p', page 1 little-endian, offset 0, count 4.
        client.send([SpeeduinoCommand.pageRead, 1, 0, 0, 0, 4, 0]),
        throwsA(isA<EcuProtocolException>()),
      );
    });

    test('the right identifier is accepted', () async {
      // 'p', CAN id 0, page 1, offset 0, count 4.
      final data =
          await client.send([SpeeduinoCommand.pageRead, 0, 1, 0, 0, 4, 0]);
      expect(data, hasLength(4));
      expect(data, ecu.pages[0].sublist(0, 4));
    });

    test('a mismatched CAN id is refused', () async {
      await expectLater(
        client.send([SpeeduinoCommand.pageRead, 9, 1, 0, 0, 4, 0]),
        throwsA(isA<EcuProtocolException>()),
      );
    });
  });

  group('pageCrc', () {
    test('matches a locally computed CRC of the same bytes', () async {
      final reported = await client.pageCrc(1);
      expect(reported, crc32(ecu.pages[0]));
    });

    test('changes when the page changes', () async {
      final before = await client.pageCrc(1);
      await client.writePage(1, data: [0xDE, 0xAD], blockingFactor: 251);
      final after = await client.pageCrc(1);

      expect(after, isNot(before));
      expect(after, crc32(ecu.pages[0]));
    });

    test('verifies a full write round trip', () async {
      // This is the real workflow: write, then confirm the ECU holds exactly
      // what we intended before burning it.
      final data = List<int>.generate(128, (i) => (i * 3) & 0xFF);
      await client.writePage(1, data: data, blockingFactor: 251);

      final expected = crc32(data);
      expect(await client.pageCrc(1), expected,
          reason: 'page 1 is 128 bytes, so the whole page was replaced');

      await client.burnPage(1);
      expect(ecu.burnedPages, contains(1));
    });

    test('rejects an out-of-range page', () async {
      await expectLater(
          client.pageCrc(99), throwsA(isA<EcuProtocolException>()));
    });
  });
}
