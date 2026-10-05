@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// How fast live data can be polled from a simulated rusEFI at 200 Hz - and how
/// much an isolate kept busy, as the UI's is by drawing frames, takes off that.
///
/// A benchmark rather than a test of behaviour: timings depend on the machine,
/// so it only runs when asked for:
///
///     FOXTUNE_BENCH=1 dart test packages/foxtune_protocol/test/throughput_test.dart
void main() {
  late String ini;
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('../foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
    ];
    ini = candidates.firstWhere((f) => f.existsSync()).readAsStringSync();
    doc = IniParser().parse(ini);
  });

  final skip = Platform.environment['FOXTUNE_BENCH'] == null
      ? 'A benchmark: set FOXTUNE_BENCH=1 to run it'
      : null;

  test('in-process polling, idle and under load', () async {
    final ecu = await _SpawnedEcu.start(ini);
    addTearDown(ecu.stop);

    for (final load in Load.values) {
      final link = await SocketEcuLink.connect('127.0.0.1', ecu.port);
      final client = EcuClient(link, timeout: const Duration(seconds: 2))
        ..useDefinition(doc);
      final monitor = RealtimeMonitor(
        client: client,
        decoder: RealtimeDecoder(doc.outputChannels),
        interval: const Duration(milliseconds: 5),
      );
      final result =
          await measure(monitor.snapshots, monitor.start, load: load);
      await monitor.dispose();
      await client.close();
      await link.close();
      printOnFailure('$result');
      // ignore: avoid_print
      print('in-process, ${load.name}: $result');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('polling on a worker, idle and under load', () async {
    final ecu = await _SpawnedEcu.start(ini);
    addTearDown(ecu.stop);

    for (final load in Load.values) {
      final worker =
          await EcuWorker.spawn(TcpLinkOpener('127.0.0.1', ecu.port));
      final client = EcuClient.withRunner(worker.commands)..useDefinition(doc);
      final source = worker.realtime(
        channels: doc.outputChannels,
        decoder: RealtimeDecoder(doc.outputChannels),
        commands: client.commands,
        interval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 2),
      );
      // When samples were read, not when they got here: the busy isolate
      // only delays the handing over.
      final read = <RealtimeSnapshot>[];
      final result = await measure(
        source.snapshots.map((s) {
          read.add(s);
          return s;
        }),
        source.start,
        load: load,
      );
      await source.dispose();
      await client.close();
      await worker.close();

      var longest = Duration.zero;
      for (var i = 1; i < read.length; i++) {
        final gap = read[i].timestamp.difference(read[i - 1].timestamp);
        if (gap > longest) longest = gap;
      }
      // ignore: avoid_print
      print('worker, ${load.name}: $result as handed over; read at '
          '${(read.length / 5).toStringAsFixed(1)} Hz, longest gap '
          '${(longest.inMicroseconds / 1000).toStringAsFixed(1)} ms');
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}

/// What else the polling isolate is made to do meanwhile.
enum Load {
  /// Nothing.
  idle,

  /// Busy for 10 ms of every 16, as drawing frames keeps the UI's isolate.
  frames,

  /// A 150 ms stall every second, as opening a heavy screen causes.
  jank,
}

/// Polls for [duration], starting with [start], and reports the rate samples
/// arrived at and the longest wait between two of them, with the isolate kept
/// as busy as [load] says.
Future<ThroughputResult> measure(
  Stream<RealtimeSnapshot> samples,
  void Function() start, {
  required Load load,
  Duration duration = const Duration(seconds: 5),
}) async {
  final clock = Stopwatch()..start();
  final arrivals = <int>[];
  final subscription = samples.listen((_) {
    arrivals.add(clock.elapsedMicroseconds);
  });
  void spin(int milliseconds) {
    final spin = Stopwatch()..start();
    while (spin.elapsedMilliseconds < milliseconds) {}
  }

  final busy = switch (load) {
    Load.idle => null,
    Load.frames =>
      Timer.periodic(const Duration(milliseconds: 16), (_) => spin(10)),
    Load.jank => Timer.periodic(const Duration(seconds: 1), (_) => spin(150)),
  };
  start();
  await Future<void>.delayed(duration);
  busy?.cancel();
  await subscription.cancel();

  var longest = 0;
  for (var i = 1; i < arrivals.length; i++) {
    final gap = arrivals[i] - arrivals[i - 1];
    if (gap > longest) longest = gap;
  }
  return ThroughputResult(
    hz: arrivals.length / (duration.inMicroseconds / 1e6),
    longestGap: Duration(microseconds: longest),
  );
}

class ThroughputResult {
  const ThroughputResult({required this.hz, required this.longestGap});

  final double hz;
  final Duration longestGap;

  @override
  String toString() => '${hz.toStringAsFixed(1)} Hz, longest gap '
      '${(longestGap.inMicroseconds / 1000).toStringAsFixed(1)} ms';
}

/// A simulated rusEFI on an isolate of its own, so the load put on the test's
/// isolate slows the client and not the ECU.
class _SpawnedEcu {
  _SpawnedEcu._(this.port, this._isolate, this._stop);

  final int port;
  final Isolate _isolate;
  final SendPort _stop;

  static Future<_SpawnedEcu> start(String ini) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serve, (ini, ready.sendPort));
    final [port as int, stop as SendPort] = await ready.first as List<Object?>;
    return _SpawnedEcu._(port, isolate, stop);
  }

  Future<void> stop() async {
    _stop.send(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill();
  }

  static Future<void> _serve((String, SendPort) args) =>
      // A client hanging up mid-reply is routine here, not a failure.
      runZonedGuarded(() async {
        final (ini, ready) = args;
        final ecu = FakeRusEfi.fromDefinition(IniParser().parse(ini));
        final port = await ecu.start();
        final stop = ReceivePort();
        ready.send([port, stop.sendPort]);
        await stop.first;
        await ecu.stop();
      }, (error, stack) {}) ??
      Future<void>.value();
}
