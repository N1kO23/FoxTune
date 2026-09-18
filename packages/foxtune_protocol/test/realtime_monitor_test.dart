@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// Drives the polling loop against the simulator over a real socket.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  late FakeSpeeduino ecu;
  late SocketEcuLink link;
  late EcuClient client;
  late RealtimeMonitor monitor;

  setUp(() async {
    ecu = FakeSpeeduino();
    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2));
    monitor = RealtimeMonitor(
      client: client,
      decoder: RealtimeDecoder(doc.outputChannels),
      interval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await monitor.dispose();
    await client.close();
    await link.close();
    await ecu.stop();
  });

  test('emits decoded snapshots while running', () async {
    final received = <RealtimeSnapshot>[];
    final sub = monitor.snapshots.listen(received.add);
    addTearDown(sub.cancel);

    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await monitor.stop();

    expect(received, isNotEmpty);
    expect(received.first.block, hasLength(doc.outputChannels.blockSize));
    // Channels must actually resolve, not just arrive as bytes.
    expect(received.first['rpm'], isNotNull);
    expect(received.first.timestamp, isNotNull);
  });

  test('sustains a realistic poll rate', () async {
    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final polls = monitor.pollCount;
    await monitor.stop();

    // Over a loopback socket this should manage far more than 10 polls in
    // half a second; the assertion is deliberately loose so it does not turn
    // into a flaky benchmark of the CI machine.
    expect(polls, greaterThan(10));
  });

  test('stops emitting after stop()', () async {
    final received = <RealtimeSnapshot>[];
    final sub = monitor.snapshots.listen(received.add);
    addTearDown(sub.cancel);

    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await monitor.stop();

    final countAtStop = received.length;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(received.length, countAtStop);
    expect(monitor.isRunning, isFalse);
  });

  test('start() is idempotent', () async {
    monitor
      ..start()
      ..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(monitor.isRunning, isTrue);
    await monitor.stop();
  });

  test('survives an occasional dropped frame', () async {
    final received = <RealtimeSnapshot>[];
    final errors = <Object>[];
    final subA = monitor.snapshots.listen(received.add);
    final subB = monitor.errors.listen(errors.add);
    addTearDown(subA.cancel);
    addTearDown(subB.cancel);

    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    ecu.corruptNextResponse = true;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await monitor.stop();

    // One bad frame must not end the session.
    expect(monitor.isRunning, isFalse,
        reason: 'stopped by the test, not by error');
    expect(received, isNotEmpty);
  });

  test('gives up when the link dies', () async {
    final errors = <Object>[];
    final sub = monitor.errors.listen(errors.add);
    addTearDown(sub.cancel);

    monitor.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Pull the ECU out from under it.
    await ecu.stop();
    await link.close();

    await Future<void>.delayed(const Duration(seconds: 3));

    expect(monitor.isRunning, isFalse,
        reason: 'a dead link must stop the loop rather than hammer it');
    expect(errors, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('refuses to poll when the definition declares no block size', () async {
    final channels = IniParser()
        .parse('[OutputChannels]\n  x = scalar, U08, 0, "", 1, 0')
        .outputChannels;
    final blind = RealtimeMonitor(
      client: client,
      decoder: RealtimeDecoder(channels),
    );
    addTearDown(blind.dispose);

    final errors = <Object>[];
    final sub = blind.errors.listen(errors.add);
    addTearDown(sub.cancel);

    blind.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(blind.isRunning, isFalse);
    expect(errors, isNotEmpty);
  });
}
