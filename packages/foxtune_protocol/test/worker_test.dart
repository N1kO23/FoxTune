@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// The connection on an isolate of its own: the real client and poller on an
/// [EcuWorker], against a simulated Speeduino over a real socket.
void main() {
  late FakeSpeeduino ecu;
  late int port;
  late EcuWorker worker;
  late EcuClient client;

  // The fake's realtime block, as a definition sees it.
  final channels = IniParser().parse('''
[OutputChannels]
ochBlockSize = 139
secl = scalar, U08, 0, "s", 1.000, 0.000
''').outputChannels;

  setUp(() async {
    ecu = FakeSpeeduino();
    port = await ecu.start();
    worker = await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', port));
    client = EcuClient.withRunner(
      worker.commands,
      timeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async {
    await client.close();
    await worker.close();
    await ecu.stop();
  });

  RealtimeSource poll({Duration interval = const Duration(milliseconds: 5)}) =>
      worker.realtime(
        channels: channels,
        decoder: RealtimeDecoder(channels),
        commands: client.commands,
        interval: interval,
      );

  test('carries out commands, replies and all', () async {
    final id = await client.identify();
    expect(id.signature, 'speeduino 202504-dev');
    expect(
      await client.readPage(2, count: 288, blockingFactor: 251),
      ecu.pages[1],
    );
  });

  test('retries a busy ECU, as the client on this isolate does', () async {
    ecu.busyRepliesRemaining = 2;
    expect((await client.identify()).signature, 'speeduino 202504-dev');
  });

  test('fails a command the ECU never answers, after its timeout', () async {
    final silent = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(silent.close);
    final sockets = <Socket>[];
    silent.listen(sockets.add);
    final mute = await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', silent.port));
    addTearDown(mute.close);

    final asking = EcuClient.withRunner(
      mute.commands,
      timeout: const Duration(milliseconds: 100),
    );
    await expectLater(
      asking.send(const [0x51]),
      throwsA(
        isA<EcuProtocolException>().having(
          (e) => e.response,
          'response',
          SerialResponse.timeout,
        ),
      ),
    );
    for (final socket in sockets) {
      socket.destroy();
    }
  });

  test('fails as opening the link failed, in its own words', () async {
    final unused = await ServerSocket.bind('127.0.0.1', 0);
    final closedPort = unused.port;
    await unused.close();
    await expectLater(
      EcuWorker.spawn(TcpLinkOpener('127.0.0.1', closedPort)),
      throwsA(isA<SocketException>()),
    );
  });

  test('says when it cannot be started at all', () async {
    // An opener holding what cannot go to another isolate.
    final port = ReceivePort();
    addTearDown(port.close);
    await expectLater(
      EcuWorker.spawn(_UnsendableOpener(port)),
      throwsA(isA<IsolateSpawnException>()),
    );
  });

  test('polls live data on its own isolate', () async {
    final source = poll();
    addTearDown(source.dispose);
    final samples = <RealtimeSnapshot>[];
    final subscription = source.snapshots.listen(samples.add);
    addTearDown(subscription.cancel);

    source.start();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(samples.length, greaterThan(20));
    expect(samples.last.block, ecu.realtime);
    expect(source.latest, same(samples.last));
    expect(source.pollCount, greaterThanOrEqualTo(samples.length));
    expect(source.isRunning, isTrue);

    await source.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final stopped = samples.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(samples.length, stopped);
  });

  test(
      'keeps polling while this isolate is busy, and hands over what it '
      'polled meanwhile', () async {
    // The ECU on an isolate of its own, so the stall here stalls only us.
    final away = await _SpawnedSpeeduino.start();
    addTearDown(away.stop);
    final distant =
        await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', away.port));
    addTearDown(distant.close);
    final source = distant.realtime(
      channels: channels,
      decoder: RealtimeDecoder(channels),
      commands: client.commands,
      interval: const Duration(milliseconds: 5),
    );
    addTearDown(source.dispose);
    final samples = <RealtimeSnapshot>[];
    final subscription = source.snapshots.listen(samples.add);
    addTearDown(subscription.cancel);
    source.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Stalled, as a janky frame stalls the UI: nothing here runs.
    final stall = Stopwatch()..start();
    while (stall.elapsedMilliseconds < 300) {}
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The worker read on through the stall: no gap in when samples were read
    // anywhere near as long as the stall.
    var longest = Duration.zero;
    for (var i = 1; i < samples.length; i++) {
      final gap = samples[i].timestamp.difference(samples[i - 1].timestamp);
      if (gap > longest) longest = gap;
    }
    expect(longest, lessThan(const Duration(milliseconds: 100)));
    expect(samples.length, greaterThan(50));
  });

  test('lets go of the oldest samples a stalled isolate has not taken',
      () async {
    final away = await _SpawnedSpeeduino.start();
    addTearDown(away.stop);
    final distant =
        await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', away.port));
    addTearDown(distant.close);
    final source = distant.realtime(
      channels: channels,
      decoder: RealtimeDecoder(channels),
      commands: client.commands,
      interval: const Duration(milliseconds: 5),
    );
    addTearDown(source.dispose);
    final samples = <RealtimeSnapshot>[];
    final subscription = source.snapshots.listen(samples.add);
    addTearDown(subscription.cancel);
    source.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = samples.length;

    // Longer than the two seconds the worker holds on to.
    final stall = Stopwatch()..start();
    while (stall.elapsedMilliseconds < 2600) {}
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // What was read during the stall reaches back no further than two
    // seconds: somewhere in it, a gap where the oldest were let go.
    expect(samples.length, greaterThan(before));
    var longest = Duration.zero;
    for (var i = 1; i < samples.length; i++) {
      final gap = samples[i].timestamp.difference(samples[i - 1].timestamp);
      if (gap > longest) longest = gap;
    }
    expect(longest, greaterThan(const Duration(milliseconds: 300)));
    expect(longest, lessThan(const Duration(milliseconds: 1500)));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('reports a lost link while polling', () async {
    final source = poll(interval: const Duration(milliseconds: 20));
    addTearDown(source.dispose);
    final errors = <Object>[];
    final subscription = source.errors.listen(errors.add);
    addTearDown(subscription.cancel);
    source.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await ecu.stop();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(errors.whereType<RealtimeLinkLost>(), isNotEmpty);
    expect(source.isRunning, isFalse);
  });

  test('records every sample on its own isolate', () async {
    final dir = await Directory.systemTemp.createTemp('foxtune_worker');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/blocks.txt';

    final source = poll();
    addTearDown(source.dispose);
    source.start();
    final recording = worker.startRecording(_LineSinkFactory(path));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final count = await recording.stop();

    expect(count, greaterThan(20));
    expect(File(path).readAsLinesSync(), hasLength(count));
  });

  test('relays a link this isolate holds', () async {
    final link = await SocketEcuLink.connect('127.0.0.1', port);
    final relayed = await EcuWorker.relay(link);
    final relayedClient = EcuClient.withRunner(
      relayed.commands,
      timeout: const Duration(seconds: 2),
    );
    expect(
      (await relayedClient.identify()).signature,
      'speeduino 202504-dev',
    );
    await relayedClient.close();
    await relayed.close();
    await link.close();
  });

  test('fails commands once closed', () async {
    await worker.close();
    await expectLater(
      client.send(const [0x51]),
      throwsA(isA<EcuProtocolException>()),
    );
  });
}

/// A simulated Speeduino on an isolate of its own.
class _SpawnedSpeeduino {
  _SpawnedSpeeduino._(this.port, this._isolate, this._stop);

  final int port;
  final Isolate _isolate;
  final SendPort _stop;

  static Future<_SpawnedSpeeduino> start() async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, ready.sendPort);
    final [port as int, stop as SendPort] = await ready.first as List<Object?>;
    return _SpawnedSpeeduino._(port, isolate, stop);
  }

  Future<void> stop() async {
    _stop.send(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill();
  }

  static Future<void> _serve(SendPort ready) async {
    await runZonedGuarded(() async {
      final ecu = FakeSpeeduino();
      final port = await ecu.start();
      final stop = ReceivePort();
      ready.send([port, stop.sendPort]);
      await stop.first;
      await ecu.stop();
    }, (error, stack) {});
  }
}

class _UnsendableOpener implements LinkOpener {
  const _UnsendableOpener(this.port);

  final ReceivePort port;

  @override
  Future<EcuLink> open() => throw UnimplementedError();
}

/// Writes a line per block - on the worker's isolate, where it is opened.
class _LineSinkFactory implements BlockSinkFactory {
  const _LineSinkFactory(this.path);

  final String path;

  @override
  Future<BlockSink> open() async => _LineSink(File(path).openWrite());
}

class _LineSink implements BlockSink {
  _LineSink(this._sink);

  final IOSink _sink;

  @override
  int count = 0;

  @override
  void add(Uint8List block, DateTime timestamp) {
    _sink.writeln('${timestamp.microsecondsSinceEpoch} ${block.length}');
    count++;
  }

  @override
  Future<void> close() => _sink.close();
}
