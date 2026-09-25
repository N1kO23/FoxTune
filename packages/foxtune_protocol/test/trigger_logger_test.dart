@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

void main() {
  late IniDocument speeduino;
  late IniDocument rusEfi;

  String fixture(String name) => [
        File('packages/foxtune_ini/test/fixtures/$name'),
        File('../foxtune_ini/test/fixtures/$name'),
      ].firstWhere((f) => f.existsSync()).readAsStringSync();

  setUpAll(() {
    speeduino = IniParser(defined: {'CELSIUS'}).parse(fixture('speeduino.ini'));
    rusEfi = IniParser().parse(fixture('rusefi_uaefi.ini'));
  });

  IniLogger logger(IniDocument definition, String label) =>
      definition.loggers.firstWhere((l) => l.label == label);

  List<int> be32(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];

  group('decoding', () {
    test("Speeduino's tooth log: a big-endian time a tooth, padding dropped",
        () {
      final log = TriggerLog.decode(logger(speeduino, 'Tooth Logger'), [
        ...be32(3704),
        ...be32(1852),
        ...be32(1851),
        ...be32(0),
        ...be32(0),
      ]);
      expect(log.records, hasLength(3));
      expect(log.toothTimes, [3.704, 1.852, 1.851]);
      expect(log.times, [3.704, closeTo(5.556, 1e-9), closeTo(7.407, 1e-9)]);
    });

    test(
        "Speeduino's composite log: flags in the last byte, the time before "
        'it', () {
      final log = TriggerLog.decode(logger(speeduino, 'Composite Logger'), [
        ...be32(1000000), 0x11, // primary high, sync
        ...be32(1000926), 0x10, // primary low
        ...be32(1001300), 0x1B, // cam edge: both high, from the secondary
        ...be32(1001300), 0x00, // padding: the last time again, no flags
        ...be32(1001300), 0x00,
      ]);
      expect(log.records, hasLength(3));
      expect(log.times, [0, closeTo(0.926, 1e-9), closeTo(1.3, 1e-9)]);
      expect(log.records[2].isSet('secLevel'), isTrue);
      expect(log.records[2].isSet('trigger'), isTrue);
      expect(log.records[1].isSet('priLevel'), isFalse);
      expect(
        log.changingFlags.map((f) => f.name),
        ['priLevel', 'secLevel', 'trigger'],
        reason: 'sync never changes, and the third input is not in use',
      );
      expect(log.toothTimes.map((t) => t.toStringAsFixed(3)), [
        '0.926',
        '0.374',
      ]);
    });

    test('a capture of nothing but padding is empty', () {
      final log = TriggerLog.decode(logger(speeduino, 'Composite Logger'), [
        for (var i = 0; i < 127; i++) ...[0, 0, 0, 0, 0],
      ]);
      expect(log.isEmpty, isTrue);
    });

    test("rusEFI's record: the whole eight bytes one big-endian number", () {
      // Time in the low 32 bits, then a byte of flags: priLevel is bit 32.
      final log = TriggerLog.decode(logger(rusEfi, 'Composite Logger'), [
        0, 0, 0, 0x01, ...be32(500), //
        0, 0, 0, 0x00, ...be32(1500),
      ]);
      expect(log.records.map((r) => r.isSet('priLevel')), [true, false]);
      expect(log.times, [0, 1.0]);
    });

    test('as CSV: the definition labels, then a row a record', () {
      final log = TriggerLog.decode(logger(speeduino, 'Tooth Logger'), [
        ...be32(3704),
        ...be32(1852),
      ]);
      expect(log.toCsv(), 'ToothTime\n3704\n1852\n');
    });
  });

  group('running a logger', () {
    late FakeSpeeduino ecu;
    late SocketEcuLink link;
    late EcuClient client;
    late RealtimeMonitor monitor;

    setUp(() async {
      ecu = FakeSpeeduino();
      final port = await ecu.start();
      link = await SocketEcuLink.connect('127.0.0.1', port);
      client = EcuClient(link, timeout: const Duration(seconds: 2))
        ..useDefinition(speeduino);
      monitor = RealtimeMonitor(
        client: client,
        decoder: RealtimeDecoder(speeduino.outputChannels),
      )..start();
    });

    tearDown(() async {
      await monitor.dispose();
      await client.close();
      await link.close();
      await ecu.stop();
    });

    TriggerLogger run(String label, {Duration? readTimeout}) => TriggerLogger(
          client: client,
          logger: logger(speeduino, label),
          snapshots: monitor.snapshots,
          readTimeout: readTimeout,
        );

    test('reads a tooth log once the ECU flags it full, then stops it',
        () async {
      // Fast, so a capture fills in about 50 ms.
      ecu.triggerRpm = 4000;
      final tooth = run('Tooth Logger');
      final first = tooth.captures.first;
      await tooth.start();
      expect(ecu.runningLogger, SpeeduinoCommand.toothLoggerStart);

      final log = await first.timeout(const Duration(seconds: 3));
      expect(log.records, hasLength(FakeSpeeduino.toothLogSize));
      // A 36-1 wheel at 4000 rpm: 417 us a tooth, twice that over the gap.
      final times = log.toothTimes;
      final longest = times.reduce((a, b) => a > b ? a : b);
      final shortest = times.reduce((a, b) => a < b ? a : b);
      expect(shortest, closeTo(0.417, 0.001));
      expect(longest, closeTo(0.833, 0.001));

      await tooth.stop();
      expect(ecu.runningLogger, isNull);
      expect(ecu.requests.last, [SpeeduinoCommand.toothLoggerStop]);
      await tooth.dispose();
    });

    test('keeps reading while it runs', () async {
      ecu.triggerRpm = 6000;
      final composite = run('Composite Logger');
      final three = composite.captures.take(3).toList();
      await composite.start();
      final logs = await three.timeout(const Duration(seconds: 5));
      for (final log in logs) {
        expect(log.records, hasLength(FakeSpeeduino.toothLogSize));
        expect(
          log.changingFlags.map((f) => f.name),
          containsAll(['priLevel']),
        );
      }
      await composite.dispose();
      expect(ecu.runningLogger, isNull);
    });

    test('reads what there is once its time is up, from a still engine',
        () async {
      ecu.triggerRpm = 0;
      final tooth = run(
        'Tooth Logger',
        readTimeout: const Duration(milliseconds: 300),
      );
      final first = tooth.captures.first;
      await tooth.start();
      final log = await first.timeout(const Duration(seconds: 3));
      expect(log.isEmpty, isTrue);
      await tooth.dispose();
    });
  });
}
