@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// The real client against a simulated rusEFI, over a real socket, with the
/// commands taken from rusEFI's own definition.
void main() {
  late IniDocument doc;
  late FakeRusEfi ecu;
  late SocketEcuLink link;
  late EcuClient client;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('../foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
    ];
    doc = IniParser().parse(
      candidates.firstWhere((f) => f.existsSync()).readAsStringSync(),
    );
  });

  setUp(() async {
    ecu = FakeRusEfi.fromDefinition(doc);
    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2));
  });

  tearDown(() async {
    await client.close();
    await link.close();
    await ecu.stop();
  });

  test('identifies itself as rusEFI', () async {
    final id = await client.identify();
    expect(id.family, EcuFamily.rusefi);
    expect(doc.matchesSignature(id.signature), isTrue);
    // Never asked Speeduino's question.
    expect(ecu.requests.map((r) => r.first), isNot(contains(0x51)));
  });

  test('reads every page, in pieces no larger than a transfer', () async {
    client.useDefinition(doc);
    final sizes = doc.constants.pageSizes;
    for (var i = 0; i < sizes.length; i++) {
      final data = await client.readPage(i + 1, count: sizes[i]);
      expect(data, ecu.pages[i], reason: 'page ${i + 1}');
    }
    final reads = ecu.requests.where((r) => r.first == 0x52).toList();
    expect(
      reads.length,
      sizes.fold<int>(0, (n, size) => n + (size + 1023) ~/ 1024),
    );
  });

  test('writes, verifies and burns a settings page', () async {
    client.useDefinition(doc);
    await client.writePage(1, offset: 100, data: [1, 2, 3, 4]);
    expect(ecu.pages[0].sublist(100, 104), [1, 2, 3, 4]);

    expect(await client.pageCrc(1), crc32(ecu.pages[0]));
    expect(await client.burnPage(1), isTrue);
    expect(ecu.burnedPages, {1});
  });

  test('never burns a working-memory page', () async {
    client.useDefinition(doc);
    await client.writePage(3, data: [7]);
    expect(await client.burnPage(3), isFalse);
    expect(ecu.burnedPages, isEmpty);
    expect(ecu.requests.map((r) => r.first), isNot(contains(0x42)));
  });

  test('reads live data larger than one transfer, and decodes it', () async {
    client.useDefinition(doc);
    ecu.simulateEngine();
    final size = doc.outputChannels.blockSize!;
    final block = await client.readRealtime(count: size);
    expect(block, hasLength(size));
    // Three requests for a block over twice the transfer limit.
    expect(ecu.requests.where((r) => r.first == 0x4F), hasLength(3));

    final snapshot = RealtimeDecoder(doc.outputChannels).decode(block);
    expect(snapshot['RPMValue'], inInclusiveRange(100, 8000));
    // A float channel, across the wire and back.
    expect(snapshot['sparkDwell'], closeTo(3.1, 1e-5));
    expect(snapshot['lambdaValue'], inInclusiveRange(0.6, 1.4));
  });

  test('answers an oversized request with a range error', () async {
    // What a client that forgot to split the live data would get.
    await expectLater(
      client.send([0x4F, 0, 0, 0xA8, 0x08]),
      throwsA(isA<EcuProtocolException>().having(
        (e) => e.response,
        'response',
        SerialResponse.rangeError,
      )),
    );
  });
}
