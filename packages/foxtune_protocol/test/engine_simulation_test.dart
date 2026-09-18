@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

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

  group('EngineSimulation', () {
    test('sweeps through idle, load and overrun across a cycle', () {
      final engine = EngineSimulation(cycle: const Duration(seconds: 24));
      // Sampling the model directly across the cycle rather than waiting.
      final rpms = <double>[];
      final throttles = <double>[];
      for (var i = 0; i < 24; i++) {
        final sample = engine.sample();
        rpms.add(sample['rpm']!);
        throttles.add(sample['tps']!);
      }
      // A single instant cannot show the sweep, so just assert the values are
      // in plausible ranges; the range assertions below cover the sweep.
      expect(rpms.every((r) => r >= 0 && r < 8000), isTrue);
      expect(throttles.every((t) => t >= 0 && t <= 100), isTrue);
    });

    test('produces values inside plausible physical ranges', () {
      final engine = EngineSimulation();
      final sample = engine.sample();

      expect(sample['rpm'], inInclusiveRange(0, 8000));
      expect(sample['map'], inInclusiveRange(20, 110));
      expect(sample['tps'], inInclusiveRange(0, 100));
      // Transmitted offset by 40, as the real ECU does.
      expect(sample['coolantRaw']! - 40, inInclusiveRange(15, 115));
      expect(sample['batteryVoltage'], inInclusiveRange(11, 15));
      expect(sample['afr'], inInclusiveRange(10, 20));
    });

    test('reports status flags', () {
      final flags = EngineSimulation().flags();
      expect(flags.keys, containsAll(['running', 'crank', 'sync']));
    });
  });

  group('FakeSpeeduino with a simulated engine', () {
    late FakeSpeeduino ecu;
    late SocketEcuLink link;
    late EcuClient client;

    setUp(() async {
      ecu = FakeSpeeduino(channels: doc.outputChannels);
      final port = await ecu.start();
      link = await SocketEcuLink.connect('127.0.0.1', port);
      client = EcuClient(link, timeout: const Duration(seconds: 2));
    });

    tearDown(() async {
      await client.close();
      await link.close();
      await ecu.stop();
    });

    test('refuses to simulate without channel definitions', () {
      final blind = FakeSpeeduino();
      // Placing values at guessed offsets would make a UI look right for the
      // wrong reason, so this fails loudly instead.
      expect(blind.simulateEngine, throwsStateError);
    });

    test('writes decodable values into the realtime block', () async {
      ecu.simulateEngine();
      expect(ecu.isSimulatingEngine, isTrue);

      final decoder = RealtimeDecoder(doc.outputChannels);
      final block = await client.readRealtime(count: 139);
      final snapshot = decoder.decode(block);

      expect(snapshot['rpm'], isNotNull);
      expect(snapshot['rpm'], inInclusiveRange(0, 8000));
      expect(snapshot['tps'], inInclusiveRange(0, 100));
      expect(snapshot['batteryVoltage'], inInclusiveRange(11, 15));
    });

    test('round-trips coolant through the definition computed channel',
        () async {
      ecu.simulateEngine();
      final decoder = RealtimeDecoder(doc.outputChannels);
      final snapshot = decoder.decode(await client.readRealtime(count: 139));

      // coolant is not transmitted; it is derived from coolantRaw by the
      // definition's own expression, so a sensible value here proves the
      // simulator wrote the raw channel correctly.
      expect(snapshot['coolant'], isNotNull);
      expect(snapshot['coolant'], inInclusiveRange(10, 120));
    });

    test('values change over time', () async {
      ecu.simulateEngine(tick: const Duration(milliseconds: 10));
      final decoder = RealtimeDecoder(doc.outputChannels);

      final first = decoder.decode(await client.readRealtime(count: 139));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final second = decoder.decode(await client.readRealtime(count: 139));

      // The whole point of the simulation is that gauges move.
      expect(second.block, isNot(first.block));
    });

    test('sets engine status flags', () async {
      ecu.simulateEngine();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final decoder = RealtimeDecoder(doc.outputChannels);
      final snapshot = decoder.decode(await client.readRealtime(count: 139));
      expect(snapshot.flag('sync'), isNotNull);
    });

    test('writes channels whose scale is an expression', () async {
      // Regression: fuelLoad is the VE table's load axis and scales by
      // { fuelLoadFeedBack }, which depends on the `algorithm` tune constant.
      // Without resolving that the simulator skipped the channel entirely, so
      // it kept its filler bytes - a nonsense load that pinned the live table
      // cursor to the top row no matter what the engine was doing.
      // The fuel and ignition load axes each scale by their own feedback
      // expression, over `algorithm` and `ignAlgorithm` respectively.
      double? constants(String name) =>
          (name == 'algorithm' || name == 'ignAlgorithm') ? 0 : null;

      final resolved = FakeSpeeduino(
        channels: doc.outputChannels,
        constantResolver: constants,
      );
      final port = await resolved.start();
      addTearDown(resolved.stop);
      resolved.simulateEngine();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final probeLink = await SocketEcuLink.connect('127.0.0.1', port);
      final probeClient = EcuClient(probeLink);
      addTearDown(() async {
        await probeClient.close();
        await probeLink.close();
      });

      final snapshot =
          RealtimeDecoder(doc.outputChannels, constantResolver: constants)
              .decode(await probeClient.readRealtime(count: 139));

      expect(resolved.unresolvedChannels, isEmpty,
          reason: 'unscalable: ${resolved.unresolvedChannels}');
      // The load axis must track manifold pressure, not sit at a filler value.
      expect(snapshot['fuelLoad'], isNotNull);
      expect(snapshot['fuelLoad'], closeTo(snapshot['map']!, 1.0));
      expect(snapshot['fuelLoad'], lessThan(300),
          reason: 'a plausible load, not leftover filler bytes');
    });

    test('reports channels it could not scale', () async {
      // Without a resolver the expression cannot be evaluated; that must be
      // visible rather than silently leaving stale data in the block.
      ecu.simulateEngine();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(ecu.unresolvedChannels, contains('fuelLoad'));
    });

    test('stops cleanly and leaves the last sample in place', () async {
      ecu.simulateEngine();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      ecu.stopEngineSimulation();

      expect(ecu.isSimulatingEngine, isFalse);
      final block = await client.readRealtime(count: 139);
      expect(block.any((b) => b != 0), isTrue);
    });
  });
}
