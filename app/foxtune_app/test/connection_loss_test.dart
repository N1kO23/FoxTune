import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/tune/recovered_edits.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// A USB transport whose one device is a simulated Speeduino on loopback.
///
/// Hot-plug events are pushed by the test, which is how a phone reports a
/// pulled cable.
class _TestTransport implements EcuTransport {
  _TestTransport(this.ecuPort);

  final int ecuPort;
  final events = StreamController<EcuPortEvent>.broadcast();
  int listed = 0;
  int opened = 0;

  static const port = EcuPort(
    address: '/dev/bus/usb/001/004',
    description: 'Arduino Mega 2560',
    vendorId: 0x2341,
  );

  @override
  String get name => 'test';

  @override
  Stream<EcuPortEvent> get portEvents => events.stream;

  @override
  Future<List<EcuPort>> listPorts() async {
    listed++;
    return const [port];
  }

  @override
  Future<EcuLink> open(EcuPort port, {int baudRate = kSpeeduinoBaudRate}) {
    opened++;
    return SocketEcuLink.connect('127.0.0.1', ecuPort);
  }
}

/// Supplies a ready-made tune instead of reading one from the ECU.
class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);

  final TuneState _tune;

  @override
  Future<TuneState?> build() async {
    // Tied to the connection exactly as the real one is, which is what makes
    // unburned edits vanish when the connection goes.
    final connection = ref.watch(connectionProvider);
    return connection is EcuConnected ? _tune : null;
  }
}

class _RecordingWake implements ScreenWake {
  final calls = <String>[];

  @override
  Future<void> hold() async => calls.add('hold');

  @override
  Future<void> release() async => calls.add('release');
}

void main() {
  late IniDocument doc;
  late FakeSpeeduino ecu;
  late _TestTransport transport;
  late TuneState tune;
  late _RecordingWake wake;
  late ProviderContainer container;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  setUp(() async {
    ecu = FakeSpeeduino(
      signature: doc.identity.signature!,
      pageSizes: doc.constants.pageSizes,
      realtimeBlockSize: doc.outputChannels.blockSize!,
      blockingFactor: doc.constants.blockingFactor!,
      channels: doc.outputChannels,
    );
    transport = _TestTransport(await ecu.start());
    tune = TuneState.empty(doc)..markClean();
    wake = _RecordingWake();

    container = ProviderContainer(
      overrides: [
        transportProvider.overrideWithValue(transport),
        definitionProvider.overrideWith((ref) async => doc),
        tuneProvider.overrideWith(() => _FakeTuneController(tune)),
        screenWakeProvider.overrideWithValue(wake),
      ],
    );
    // Keep the watchers alive, as the app shell does.
    container
      ..listen(connectionWatchdogProvider, (_, _) {})
      ..listen(screenWakeWatcherProvider, (_, _) {})
      ..listen(unburnedEditsGuardProvider, (_, _) {})
      ..listen(tuneProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await ecu.stop();
    await transport.events.close();
  });

  EcuConnectionState state() => container.read(connectionProvider);

  Future<void> connect() async {
    await container
        .read(connectionProvider.notifier)
        .connect(_TestTransport.port);
    expect(state(), isA<EcuConnected>());
    // Let the tune load, as the tabs would.
    await container.read(tuneProvider.future);
  }

  Future<void> waitFor(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Makes an edit that has not been burned.
  void edit() {
    SettingView.of(tune, 'reqFuel')!.setValue(9.5);
    expect(tune.isDirty, isTrue);
  }

  group('noticing the connection end', () {
    test('an ECU that stops answering ends the session as lost', () async {
      await connect();

      await ecu.stop();
      await waitFor(() => state() is EcuConnectionLost);

      final lost = state() as EcuConnectionLost;
      expect(lost.reason, contains('stopped responding'));
      expect(lost.port.address, _TestTransport.port.address);
    });

    test('unplugging the connected ECU ends the session at once', () async {
      await connect();

      transport.events.add(EcuPortEvent.detached(_TestTransport.port.address));
      await waitFor(() => state() is EcuConnectionLost);

      expect((state() as EcuConnectionLost).reason, contains('unplugged'));
    });

    test('unplugging some other device leaves the session alone', () async {
      await connect();

      transport.events.add(const EcuPortEvent.detached('/dev/bus/usb/001/009'));
      // A detach that does not say which device it was is not acted on
      // either: the realtime monitor catches a real loss on its own.
      transport.events.add(const EcuPortEvent.detached(null));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(state(), isA<EcuConnected>());
    });

    test('plugging or unplugging anything refreshes the port list', () async {
      final subscription = container.listen(portsProvider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(portsProvider.future);
      final before = transport.listed;

      transport.events.add(const EcuPortEvent.attached('/dev/bus/usb/001/005'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await container.read(portsProvider.future);

      expect(transport.listed, greaterThan(before));
    });

    test('reconnecting goes back through the same transport', () async {
      await connect();
      transport.events.add(EcuPortEvent.detached(_TestTransport.port.address));
      await waitFor(() => state() is EcuConnectionLost);

      await container.read(connectionProvider.notifier).reconnect();

      expect(state(), isA<EcuConnected>());
      expect(transport.opened, 2);
    });
  });

  group('unburned edits', () {
    test('survive the connection being lost', () async {
      await connect();
      edit();

      transport.events.add(EcuPortEvent.detached(_TestTransport.port.address));
      await waitFor(() => state() is EcuConnectionLost);

      final recovered = container.read(recoveredEditsProvider);
      expect(recovered, isNotNull);
      expect(recovered!.pages, isNotEmpty);
      expect(
        SettingView.of(recovered.tune, 'reqFuel')!.value,
        closeTo(9.5, 0.05),
      );
      // The loaded tune itself went with the connection.
      expect(container.read(tuneProvider).value, isNull);
    });

    test('survive a manual disconnect', () async {
      await connect();
      edit();

      await container.read(connectionProvider.notifier).disconnect();

      expect(state(), isA<EcuDisconnected>());
      expect(container.read(recoveredEditsProvider), isNotNull);
    });

    test('save as a tune file that carries the edit', () async {
      await connect();
      edit();
      await container.read(connectionProvider.notifier).disconnect();

      final recovered = container.read(recoveredEditsProvider)!;
      final reloaded = TuneState.empty(doc);
      MsqCodec.decode(MsqCodec.encode(recovered.tune), reloaded);

      expect(SettingView.of(reloaded, 'reqFuel')!.value, closeTo(9.5, 0.05));
    });

    test('are not invented when nothing was changed', () async {
      await connect();
      expect(tune.isDirty, isFalse);

      await container.read(connectionProvider.notifier).disconnect();

      expect(container.read(recoveredEditsProvider), isNull);
    });
  });

  group('screen', () {
    test('stays on while connected, and only then', () async {
      expect(wake.calls, isEmpty);

      await connect();
      expect(wake.calls, ['hold']);

      await container.read(connectionProvider.notifier).disconnect();
      expect(wake.calls, ['hold', 'release']);
    });
  });
}
