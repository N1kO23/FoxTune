import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

/// A scripted stand-in for a Speeduino, driven by whatever the client sends.
///
/// It decodes the client's frames the same way the firmware would, so these
/// tests exercise the real envelope in both directions rather than a
/// simplified stub.
class ScriptedEcu {
  ScriptedEcu({this.latency = Duration.zero}) {
    link = FakeEcuLink(onSend: _onSend);
  }

  late final FakeEcuLink link;
  final Duration latency;

  /// Payloads the ECU received, with the envelope stripped.
  final List<Uint8List> received = [];

  /// Responder keyed by the command byte.
  final Map<int, List<int> Function(Uint8List payload)> handlers = {};

  /// Commands to leave unanswered, simulating a dropped reply.
  final Set<int> silent = {};

  /// Per-command count of `busy` replies to send before the real answer.
  final Map<int, int> busyBefore = {};

  /// When set, the raw bytes to emit instead of a well-formed frame.
  List<int>? rawOverride;

  void _onSend(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    final length = (data[0] << 8) | data[1];
    final payload = Uint8List.sublistView(data, 2, 2 + length);
    received.add(Uint8List.fromList(payload));

    final command = payload[0];
    if (silent.contains(command)) return;

    scheduleMicrotask(() async {
      if (latency > Duration.zero) await Future<void>.delayed(latency);

      final override = rawOverride;
      if (override != null) {
        rawOverride = null;
        link.deliver(override);
        return;
      }

      final remainingBusy = busyBefore[command] ?? 0;
      if (remainingBusy > 0) {
        busyBefore[command] = remainingBusy - 1;
        link.deliver(EcuFrame.encode([0x85]));
        return;
      }

      final handler = handlers[command];
      if (handler == null) {
        link.deliver(EcuFrame.encode([0x83])); // unknown command
        return;
      }
      link.deliver(EcuFrame.encode([0x00, ...handler(payload)]));
    });
  }
}

void main() {
  late ScriptedEcu ecu;
  late EcuClient client;

  setUp(() {
    ecu = ScriptedEcu();
    client = EcuClient(ecu.link, timeout: const Duration(milliseconds: 200));
  });

  tearDown(() async {
    await client.close();
    await ecu.link.close();
  });

  group('handshake', () {
    setUp(() {
      ecu.handlers[0x53] = (_) => ascii.encode('speeduino 202504-dev');
      ecu.handlers[0x51] = (_) => ascii.encode('Speeduino 2025.04');
    });

    test('reads the signature', () async {
      expect(await client.readSignature(), 'speeduino 202504-dev');
      expect(ecu.received.single, [0x53]);
    });

    test('reads the version', () async {
      expect(await client.queryVersion(), 'Speeduino 2025.04');
    });

    test('identify() returns both strings', () async {
      final id = await client.identify();
      expect(id.signature, 'speeduino 202504-dev');
      expect(id.version, 'Speeduino 2025.04');
    });

    test('trims NUL padding the firmware adds', () async {
      ecu.handlers[0x53] =
          (_) => [...ascii.encode('speeduino 202504-dev'), 0, 0, 0, 0];
      expect(await client.readSignature(), 'speeduino 202504-dev');
    });
  });

  group('page reads', () {
    setUp(() {
      // Echo a recognisable ramp so offsets can be verified.
      ecu.handlers[0x70] = (payload) {
        final offset = payload[3] | (payload[4] << 8);
        final count = payload[5] | (payload[6] << 8);
        return [for (var i = 0; i < count; i++) (offset + i) & 0xFF];
      };
    });

    test('sends page, offset and count as little-endian pairs', () async {
      await client.readPage(1, count: 4, blockingFactor: 251);
      expect(ecu.received.single, [0x70, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00]);
    });

    test('returns the page contents', () async {
      final data = await client.readPage(1, count: 8, blockingFactor: 251);
      expect(data, [0, 1, 2, 3, 4, 5, 6, 7]);
    });

    test('chunks a read larger than the blocking factor', () async {
      // 288 bytes is page 2's real size; 251 is the standard blockingFactor.
      final data = await client.readPage(2, count: 288, blockingFactor: 251);

      expect(data, hasLength(288));
      expect(ecu.received, hasLength(2),
          reason: 'must split into 251 + 37, not one oversized request');

      int countOf(Uint8List p) => p[5] | (p[6] << 8);
      int offsetOf(Uint8List p) => p[3] | (p[4] << 8);
      expect(countOf(ecu.received[0]), 251);
      expect(offsetOf(ecu.received[0]), 0);
      expect(countOf(ecu.received[1]), 37);
      expect(offsetOf(ecu.received[1]), 251);

      // Contents must stitch back together in the right order.
      expect(data[0], 0);
      expect(data[251], 251 & 0xFF);
    });

    test('honours a starting offset', () async {
      final data =
          await client.readPage(1, count: 4, offset: 16, blockingFactor: 251);
      expect(data, [16, 17, 18, 19]);
    });

    test('rejects a non-positive blocking factor', () {
      expect(() => client.readPage(1, count: 4, blockingFactor: 0),
          throwsArgumentError);
    });

    test('fails when the ECU returns the wrong number of bytes', () {
      ecu.handlers[0x70] = (_) => [1, 2];
      expect(client.readPage(1, count: 8, blockingFactor: 251),
          throwsA(isA<EcuProtocolException>()));
    });
  });

  group('realtime', () {
    test('builds the command with CAN id and sub-command', () async {
      final canClient = EcuClient(ecu.link, canId: 3);
      addTearDown(canClient.close);
      ecu.handlers[0x72] = (_) => List<int>.filled(16, 0xAB);

      final data = await canClient.readRealtime(count: 16);

      expect(data, hasLength(16));
      // 'r', canId, 0x30, offset LE, count LE
      expect(ecu.received.single, [0x72, 0x03, 0x30, 0x00, 0x00, 0x10, 0x00]);
    });
  });

  group('error handling', () {
    test('surfaces an unknown-command reply as an exception', () {
      // No handler registered, so the scripted ECU answers 0x83.
      expect(
        client.readPage(99, count: 4, blockingFactor: 251),
        throwsA(isA<EcuProtocolException>().having(
            (e) => e.response, 'response', SerialResponse.unknownCommand)),
      );
    });

    test('surfaces a range error as an exception', () {
      ecu.handlers[0x70] = (_) => throw StateError('unreachable');
      ecu.rawOverride = EcuFrame.encode([0x84]);
      expect(
        client.readPage(99, count: 4, blockingFactor: 251),
        throwsA(isA<EcuProtocolException>()
            .having((e) => e.response, 'response', SerialResponse.rangeError)),
      );
    });

    test('times out when no reply arrives', () {
      ecu.silent.add(0x53);
      expect(
        client.readSignature(),
        throwsA(isA<EcuProtocolException>()
            .having((e) => e.response, 'response', SerialResponse.timeout)),
      );
    });

    test('times out rather than accepting a corrupted reply', () async {
      ecu.handlers[0x53] = (_) => ascii.encode('speeduino');
      ecu.rawOverride = (EcuFrame.encode([0x00, 0x41, 0x42])..last ^= 0xFF);

      await expectLater(
        client.readSignature(),
        throwsA(isA<EcuProtocolException>()),
      );
    });

    test('retries a busy response and then succeeds', () async {
      ecu.handlers[0x53] = (_) => ascii.encode('speeduino 202504-dev');
      ecu.busyBefore[0x53] = 2;

      expect(await client.readSignature(), 'speeduino 202504-dev');
      // Two busy replies plus the successful attempt.
      expect(ecu.received, hasLength(3));
    });

    test('gives up after the retry limit', () async {
      final impatient = EcuClient(ecu.link,
          timeout: const Duration(milliseconds: 200), maxRetries: 1);
      addTearDown(impatient.close);
      ecu.handlers[0x53] = (_) => ascii.encode('speeduino');
      ecu.busyBefore[0x53] = 99;

      await expectLater(
        impatient.readSignature(),
        throwsA(isA<EcuProtocolException>()
            .having((e) => e.response, 'response', SerialResponse.busy)),
      );
    });

    test('does not wedge when the link fails to write', () async {
      // Regression: a synchronous throw from send() used to leave the request
      // marked in-flight forever, so every later command queued behind one
      // that could never complete - the client died silently with the link.
      ecu.handlers[0x53] = (_) => ascii.encode('speeduino 202504-dev');
      await ecu.link.close();

      await expectLater(
          client.readSignature(), throwsA(isA<EcuProtocolException>()));

      // The next command must fail promptly too, not hang.
      await expectLater(
        client.queryVersion().timeout(const Duration(seconds: 1)),
        throwsA(isA<EcuProtocolException>()),
      );
    });

    test('rejects use after close', () async {
      await client.close();
      expect(client.readSignature(), throwsA(isA<EcuProtocolException>()));
    });
  });

  group('request serialisation', () {
    test('issues queued commands one at a time, in order', () async {
      ecu.handlers[0x53] = (_) => ascii.encode('sig');
      ecu.handlers[0x51] = (_) => ascii.encode('ver');
      ecu.handlers[0x70] = (payload) => [0xFF];

      final results = await Future.wait([
        client.readSignature(),
        client.queryVersion(),
        client.readPage(1, count: 1, blockingFactor: 251),
      ]);

      expect(results[0], 'sig');
      expect(results[1], 'ver');
      // The protocol has no request ids, so ordering is the only way replies
      // can be matched to commands.
      expect([for (final p in ecu.received) p[0]], [0x53, 0x51, 0x70]);
    });
  });
}
