@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// Reading only the parts of the live data block that are used.
void main() {
  final small = IniParser().parse(r'''
[OutputChannels]
ochGetCommand = "O%2o%2c"
ochBlockSize = 64
a = scalar, U08, 0, "", 1, 0
b = scalar, U16, 10, "", 1, 0
c = scalar, U08, 40, "", 1, 0
far = scalar, U08, 60, "", 1, 0
scaled = scalar, U16, 20, "", { factor }, 0
e = scalar, U08, 30, "", 1, 0
factor = { e * 2 }
sum = { a + b }
nested = { sum + reqFuel }
''').outputChannels;
  IniField field(String name) => small.channelNamed(name)!;

  group('spans', () {
    test('close channels are read as one, far ones apart', () {
      expect(
        planSpans(
          {field('a'), field('b'), field('far')},
          blockSize: 64,
          chunk: 64,
          mergeGap: 16,
        ),
        // Two requests would be more than the whole block's one: joined.
        [const BlockSpan(0, 61)],
      );
      expect(
        planSpans(
          {field('a'), field('b'), field('far')},
          blockSize: 64,
          chunk: 32,
          mergeGap: 16,
        ),
        [const BlockSpan(0, 12), const BlockSpan(60, 61)],
      );
    });

    test('never take more requests than the whole block would', () {
      // rusEFI's shape: a block of three transfers, channels all over it.
      final scattered = {
        for (var i = 0; i < 10; i++)
          IniScalarField(
            name: 'c$i',
            type: IniDataType.u16,
            offset: i * 220,
            units: '',
            scale: const IniLiteral(1),
            translate: const IniLiteral(0),
          ),
      };
      final spans = planSpans(scattered, blockSize: 2216, chunk: 1024)!;
      final requests = spans.fold(
        0,
        (sum, span) => sum + (span.length + 1023) ~/ 1024,
      );
      expect(requests, lessThanOrEqualTo(3));
      // Every channel still read.
      for (final channel in scattered) {
        expect(
          spans.any((s) => s.covers(channel.offset!, 2)),
          isTrue,
          reason: channel.name,
        );
      }
    });

    test('everything wanted is the whole block, and nothing is a byte', () {
      expect(
        planSpans(small.channels.toSet(), blockSize: 61, chunk: 64),
        isNull,
      );
      expect(planSpans({}, blockSize: 64, chunk: 64), [
        const BlockSpan(0, 1),
      ]);
    });
  });

  group('what a channel needs', () {
    final fields = ChannelFields(small);
    Set<String> of(List<String> names) =>
        {for (final f in fields.of(names)) f.name};

    test('a field itself', () => expect(of(['b']), {'b'}));

    test('what a computed channel reads, followed through', () {
      expect(of(['sum']), {'a', 'b'});
      // reqFuel is a tune constant: nothing from the block.
      expect(of(['nested']), {'a', 'b'});
    });

    test('what the expression it is scaled by reads', () {
      expect(of(['scaled']), {'scaled', 'e'});
    });

    test('nothing for a name the block does not hold', () {
      expect(of(['reqFuel', 'nonsense']), isEmpty);
    });
  });

  group('demand', () {
    test('wants what is read until it goes unread for long enough', () {
      final demand = ChannelDemand(keep: const Duration(seconds: 1))
        ..standing = {'always'};
      demand.wanted(Duration.zero);
      demand.note('read');
      expect(demand.wanted(const Duration(milliseconds: 500)), {
        'always',
        'read',
      });
      expect(demand.wanted(const Duration(seconds: 2)), {'always'});
    });

    test('says when a read was missed, once', () {
      final demand = ChannelDemand()..missed('x');
      expect(demand.takeMissed(), isTrue);
      expect(demand.takeMissed(), isFalse);
      expect(demand.wanted(Duration.zero), {'x'});
    });
  });

  group('a snapshot of parts of the block', () {
    final block = Uint8List(64)
      ..[0] = 7
      ..[10] = 3
      ..[40] = 9;

    test('reads what was read, and nothing standing in for the rest', () {
      final demand = ChannelDemand();
      final sample = RealtimeDecoder(small, demand: demand).decode(
        block,
        coverage: const [BlockSpan(0, 12)],
      );
      expect(sample['a'], 7);
      expect(sample['b'], 3);
      expect(sample['sum'], 10);
      expect(sample['c'], isNull);
      expect(demand.takeMissed(), isTrue);
      expect(demand.wanted(Duration.zero), containsAll(['a', 'b', 'sum', 'c']));
    });

    test('reads everything where all of it was read', () {
      final sample = RealtimeDecoder(small).decode(block);
      expect(sample['c'], 9);
      expect(sample.coverage, isNull);
    });
  });

  group('a plan', () {
    final rusefiCommands = EcuCommandSet(realtimeCommand: 'O%2o%2c');

    DemandReadPlan planFor(
      ChannelDemand demand, {
      EcuCommandSet? commands,
      Duration warmUp = Duration.zero,
      Duration refresh = const Duration(hours: 1),
    }) =>
        DemandReadPlan(
          channels: small,
          demand: demand,
          commands: commands ?? rusefiCommands,
          warmUp: warmUp,
          refresh: refresh,
        );

    test('reads the whole block while warming up', () {
      final plan = planFor(
        ChannelDemand()..note('b'),
        warmUp: const Duration(hours: 1),
      );
      expect(plan.next(), isNull);
    });

    test('reads what is wanted, and more as soon as more is missed', () {
      final demand = ChannelDemand()..note('b');
      final plan = planFor(demand);
      expect(plan.next(), [const BlockSpan(10, 12)]);

      // Read, and not polled: wanted from the very next poll.
      RealtimeDecoder(small, demand: demand)
          .decode(Uint8List(64), coverage: plan.next())['far'];
      final next = plan.next()!;
      expect(next.any((s) => s.covers(60, 1)), isTrue);
    });

    test('reads the whole block when asked to', () {
      final plan = planFor(ChannelDemand()..note('b'))..readWholeBlock = true;
      expect(plan.next(), isNull);
    });

    test('reads the whole block from an ECU that cannot be asked for less', () {
      final plan = planFor(
        ChannelDemand()..note('b'),
        commands: EcuCommandSet(realtimeCommand: 'A'),
      );
      expect(plan.next(), isNull);
    });
  });

  group('polling a simulated rusEFI', () {
    late IniDocument doc;
    late FakeRusEfi ecu;
    late int port;

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
      ecu.simulateEngine(tick: const Duration(milliseconds: 5));
      port = await ecu.start();
    });
    tearDown(() => ecu.stop());

    /// The live data reads the fake answered: (offset, count).
    List<(int, int)> reads() => [
          for (final r in ecu.requests)
            if (r.first == 0x4F) (r[1] | r[2] << 8, r[3] | r[4] << 8),
        ];

    /// Reads RPM and MAP from every sample, as a dashboard would, until
    /// [enough] samples have come.
    Future<List<RealtimeSnapshot>> watch(
      RealtimeSource source, {
      int enough = 20,
    }) async {
      final samples = <RealtimeSnapshot>[];
      final done = Completer<void>();
      final subscription = source.snapshots.listen((sample) {
        sample['RPMValue'];
        sample['MAPValue'];
        samples.add(sample);
        if (samples.length == enough && !done.isCompleted) done.complete();
      });
      source.start();
      await done.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      return samples;
    }

    void expectOnlyTheUsedParts(List<RealtimeSnapshot> samples) {
      final last = samples.last;
      expect(last.coverage, isNotNull);
      // Read, and right: as the whole block decodes them.
      final whole = RealtimeDecoder(doc.outputChannels).decode(ecu.realtime);
      expect(last['RPMValue'], closeTo(whole['RPMValue']!, 50));
      expect(last['MAPValue'], isNotNull);
      // And far from all of the block - rusEFI's is 2216 bytes, in three
      // requests.
      final latest = reads().reversed.take(3).toList();
      expect(
        latest.every((r) => r.$2 < 200),
        isTrue,
        reason: 'reads were $latest',
      );
    }

    test('on this isolate', () async {
      final link = await SocketEcuLink.connect('127.0.0.1', port);
      final client = EcuClient(link)..useDefinition(doc);
      final demand = ChannelDemand();
      final monitor = RealtimeMonitor(
        client: client,
        decoder: RealtimeDecoder(doc.outputChannels, demand: demand),
        interval: const Duration(milliseconds: 5),
        plan: DemandReadPlan(
          channels: doc.outputChannels,
          demand: demand,
          commands: client.commands,
          warmUp: const Duration(milliseconds: 50),
        ),
      );
      final samples = await watch(monitor, enough: 40);
      expectOnlyTheUsedParts(samples);

      // Asked for everything: the whole block again.
      monitor.readWholeBlock = true;
      final whole = await watch(monitor, enough: 5);
      expect(whole.last.coverage, isNull);
      expect(reads().last, (2048, 168));

      await monitor.dispose();
      await client.close();
      await link.close();
    });

    test('on a worker, and the whole block while it records', () async {
      final worker = await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', port));
      addTearDown(worker.close);
      final client = EcuClient.withRunner(worker.commands)..useDefinition(doc);
      final source = worker.realtime(
        channels: doc.outputChannels,
        decoder: RealtimeDecoder(doc.outputChannels, demand: ChannelDemand()),
        commands: client.commands,
        interval: const Duration(milliseconds: 5),
      );
      addTearDown(source.dispose);
      // Past the plan's warm-up.
      final samples = await watch(source, enough: 200);
      expectOnlyTheUsedParts(samples);

      final dir = await Directory.systemTemp.createTemp('foxtune_plan');
      addTearDown(() => dir.delete(recursive: true));
      final recording = worker.startRecording(
        _CountingSinkFactory('${dir.path}/blocks'),
      );
      final recorded = await watch(source, enough: 10);
      await recording.stop();
      expect(recorded.last.coverage, isNull);
      expect(reads().last, (2048, 168));
    });
  });
}

class _CountingSinkFactory implements BlockSinkFactory {
  const _CountingSinkFactory(this.path);

  final String path;

  @override
  Future<BlockSink> open() async => _CountingSink();
}

class _CountingSink implements BlockSink {
  @override
  int count = 0;

  @override
  void add(Uint8List block, DateTime timestamp) => count++;

  @override
  Future<void> close() async {}
}
