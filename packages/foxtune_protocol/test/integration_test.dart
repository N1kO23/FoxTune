@TestOn('vm')
library;

import 'dart:convert';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// End-to-end tests: a real [EcuClient] talking to a simulated Speeduino over a
/// real socket. Nothing is stubbed between them, so the envelope, CRC, chunking
/// and command encoding all have to be right for these to pass.
/// The signature, by the command Speeduino answers it to.
Future<String> signature(EcuClient client) async =>
    ascii.decode(await client.send([SpeeduinoCommand.query]));

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

  test('completes the handshake', () async {
    final id = await client.identify();
    expect(id.signature, 'speeduino 202504-dev');
    expect(id.version, startsWith('Speeduino'));
  });

  test('reads a whole page, chunked to the blocking factor', () async {
    // Page 2 is 288 bytes, larger than the 251-byte blocking factor.
    final data = await client.readPage(2, count: 288, blockingFactor: 251);

    expect(data, hasLength(288));
    expect(data, ecu.pages[1],
        reason: 'chunks must reassemble into the exact page contents');

    final reads =
        ecu.requests.where((r) => r[0] == SpeeduinoCommand.pageRead).toList();
    expect(reads, hasLength(2));
  });

  test('reads every page at its declared size', () async {
    for (var page = 1; page <= ecu.pageSizes.length; page++) {
      final size = ecu.pageSizes[page - 1];
      final data =
          await client.readPage(page, count: size, blockingFactor: 251);
      expect(data, ecu.pages[page - 1], reason: 'page $page mismatched');
    }
  });

  test('reads the realtime block', () async {
    final data = await client.readRealtime(count: 139);
    expect(data, ecu.realtime);
  });

  test('polls realtime repeatedly without desynchronising', () async {
    // The failure this guards against is a decoder that leaves residue between
    // frames: it shows up as drift after many round trips, not on the first.
    for (var i = 0; i < 50; i++) {
      final data = await client.readRealtime(count: 139);
      expect(data, ecu.realtime, reason: 'poll $i returned wrong data');
    }
  });

  test('rejects an out-of-range page with a range error', () async {
    await expectLater(
      client.readPage(99, count: 16, blockingFactor: 251),
      throwsA(isA<EcuProtocolException>()
          .having((e) => e.response, 'response', SerialResponse.rangeError)),
    );
  });

  test('an ECU that goes away fails commands rather than crashing', () async {
    // Commands sent as the ECU stops, before the link has noticed. The reset
    // case - a write failing through the socket's `done` - is pinned down
    // deterministically in socket_link_test.dart.
    expect(await signature(client), 'speeduino 202504-dev');
    final stopping = ecu.stop();
    final outcomes = await Future.wait([
      for (var i = 0; i < 10; i++)
        client.send([SpeeduinoCommand.query]).then<Object>((_) => 'answered',
            onError: (Object e) => e),
    ]);
    await stopping;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Any that went unanswered failed as protocol errors, not crashes.
    for (final outcome in outcomes) {
      expect(outcome, anyOf('answered', isA<EcuProtocolException>()));
    }
    expect(link.isOpen, isFalse);
  });

  test('recovers after a corrupted response', () async {
    ecu.corruptNextResponse = true;

    // The corrupted reply must not be accepted; the command times out.
    await expectLater(signature(client), throwsA(isA<EcuProtocolException>()));

    // The link must still be usable afterwards.
    expect(await signature(client), 'speeduino 202504-dev');
  });

  test('retries through busy replies', () async {
    ecu.busyRepliesRemaining = 2;
    expect(await signature(client), 'speeduino 202504-dev');
  });

  test('serialises concurrent commands over one socket', () async {
    final results = await Future.wait([
      signature(client),
      signature(client),
      client.readPage(1, count: 128, blockingFactor: 251),
      client.readRealtime(count: 139),
    ]);

    expect(results[0], 'speeduino 202504-dev');
    expect(results[2], ecu.pages[0]);
    expect(results[3], ecu.realtime);
  });
}
