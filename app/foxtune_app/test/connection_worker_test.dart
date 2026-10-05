import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/live_demand.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/logging/log_controller.dart';
import 'package:foxtune_app/src/logging/log_files.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// The connection on an isolate of its own, as the app makes it: commands,
/// live data and logging all on an `EcuWorker`, against a simulated Speeduino
/// over a real socket.
void main() {
  late IniDocument speeduino;
  late Directory storage;
  late FakeSpeeduino ecu;
  late int port;

  setUpAll(() {
    speeduino = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  setUp(() async {
    storage = Directory.systemTemp.createTempSync('foxtune_worker');
    ecu = FakeSpeeduino(
      signature: speeduino.identity.signature!,
      pageSizes: speeduino.constants.pageSizes,
      realtimeBlockSize: speeduino.outputChannels.blockSize!,
      blockingFactor: speeduino.constants.blockingFactor!,
      channels: speeduino.outputChannels,
    );
    port = await ecu.start();
  });

  tearDown(() async {
    await ecu.stop();
    storage.deleteSync(recursive: true);
  });

  ProviderContainer containerFor({Set<String>? dashboard}) {
    final container = ProviderContainer(
      overrides: [
        if (dashboard != null)
          dashboardChannelsProvider.overrideWithValue(dashboard),
        initialAppSettingsProvider.overrideWithValue(
          const AppSettings(liveDataRate: 100),
        ),
        bundledDefinitionProvider.overrideWith((ref) async => speeduino),
        appStorageDirectoryProvider.overrideWith((ref) async => storage),
        logDirectoryProvider.overrideWith(
          (ref) async => Directory('${storage.path}/logs'),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Connects, and collects the live data that follows.
  Future<List<RealtimeSnapshot>> connect(ProviderContainer container) async {
    await container
        .read(connectionProvider.notifier)
        .connectToNetwork('127.0.0.1:$port');
    expect(container.read(connectionProvider), isA<EcuConnected>());
    final samples = <RealtimeSnapshot>[];
    container.listen(realtimeProvider, (_, next) {
      if (next.value case final sample?) samples.add(sample);
    });
    await _waitFor(() => samples.length >= 10);
    return samples;
  }

  test('a network ECU runs on a worker, and live data comes from it', () async {
    final container = containerFor();
    final samples = await connect(container);
    final connection = container.read(connectionProvider.notifier);

    expect(connection.worker, isNotNull);
    expect(samples.last.block, ecu.realtime);
    // The worker's own count of what it polled comes over with the samples.
    expect(
      container.read(realtimeMonitorProvider)!.pollCount,
      greaterThanOrEqualTo(samples.length),
    );

    await connection.disconnect();
    expect(connection.worker, isNull);
  });

  test('a log is written on the worker, a row per sample', () async {
    final container = containerFor();
    await connect(container);
    final log = container.read(logSessionProvider.notifier);

    await log.start();
    expect(
      container.read(logSessionProvider).recording,
      isTrue,
      reason: container.read(logSessionProvider).error,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await log.stop();

    final session = container.read(logSessionProvider);
    expect(session.error, isNull);
    expect(session.rows, greaterThan(5));
    expect(File(session.path!).readAsLinesSync(), hasLength(4 + session.rows));
  });

  /// The live data reads the ECU has answered, as (offset, count).
  List<(int, int)> reads() => [
    for (final r in ecu.requests)
      if (r.first == SpeeduinoCommand.realtime)
        (r[3] | r[4] << 8, r[5] | r[6] << 8),
  ];

  test('only the parts of the block in use are read', () async {
    final container = containerFor(dashboard: {'rpm', 'map'});
    final samples = await connect(container);
    // Past the half second the whole block is read for at first.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    // map at 4 and rpm at 14, in one read - of the 139 bytes there are.
    expect(reads().last, (4, 12));
    final latest = samples.last;
    expect(latest.coverage, [const BlockSpan(4, 16)]);
    expect(latest['rpm'], isNotNull);
    // Barometric pressure, at 41: not read, and not made up.
    expect(latest['baro'], isNull);

    // A channel read that the polls left out is read from then on.
    await _waitFor(() => samples.last['baro'] != null);
  });

  test('a log has the whole block read while it records', () async {
    final container = containerFor(dashboard: {'rpm'});
    await connect(container);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(reads().last.$2, lessThan(139));

    final log = container.read(logSessionProvider.notifier);
    await log.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reads().last, (0, 139));

    await log.stop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(reads().last.$2, lessThan(139));
  });

  test(
    'an ECU is talked to here instead, where a worker cannot be started',
    () async {
      final container = containerFor();
      final transport = _UnsendableTransport(port);
      addTearDown(transport.close);
      final connection = container.read(connectionProvider.notifier);

      await connection.connect(
        const EcuPort(address: 'bridge'),
        transport: transport,
      );
      expect(container.read(connectionProvider), isA<EcuConnected>());
      expect(connection.worker, isNull);
    },
  );
}

Future<void> _waitFor(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A network bridge whose way of being opened elsewhere cannot be sent to
/// another isolate: a worker for it cannot be started.
class _UnsendableTransport implements IsolateTransport {
  _UnsendableTransport(this.port);

  final int port;
  final _unsendable = ReceivePort();

  void close() => _unsendable.close();

  @override
  String get name => 'unsendable';

  @override
  Future<List<EcuPort>> listPorts() async => const [];

  @override
  Stream<EcuPortEvent> get portEvents => const Stream.empty();

  @override
  Future<EcuLink> open(
    EcuPort port, {
    int baudRate = kSpeeduinoBaudRate,
    Duration delayAfterOpen = kDelayAfterPortOpen,
  }) => SocketEcuLink.connect('127.0.0.1', this.port);

  @override
  LinkOpener openerFor(
    EcuPort port, {
    required int baudRate,
    required Duration delayAfterOpen,
  }) => _Opener(_unsendable);
}

class _Opener implements LinkOpener {
  const _Opener(this.port);

  final ReceivePort port;

  @override
  Future<EcuLink> open() => throw UnimplementedError();
}
