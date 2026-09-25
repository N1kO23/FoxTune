import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/loggers/trigger_logger_controller.dart';
import 'package:foxtune_app/src/loggers/trigger_logger_screen.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _FixedConnection extends ConnectionController {
  _FixedConnection(this._initial);
  final EcuConnectionState _initial;

  @override
  EcuConnectionState build() => _initial;

  @override
  Future<void> disconnect() async => state = const EcuDisconnected();
}

class _FixedTune extends TuneController {
  @override
  Future<TuneState?> build() async => null;
}

class _NoWake implements ScreenWake {
  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}
}

/// A logger that only records what it is asked to do.
class _StubLogger extends TriggerLoggerController {
  _StubLogger(this._initial);
  final TriggerLoggerState _initial;
  int starts = 0;
  int stops = 0;

  @override
  TriggerLoggerState build() => _initial;

  @override
  Future<void> start() async {
    starts++;
    state = state.copyWith(running: true, captures: 0);
  }

  @override
  Future<void> stop() async {
    stops++;
    state = state.copyWith(running: false);
  }
}

/// The trigger loggers: what their captures look like on screen, where the
/// tab is, and a real one run against a simulated Speeduino.
void main() {
  late IniDocument doc;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  IniLogger logger(String label) =>
      doc.loggers.firstWhere((l) => l.label == label);

  List<int> be32(int value) => [
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  /// Two turns of a 36-1 wheel at 900 rpm.
  TriggerLog toothLog() => TriggerLog.decode(logger('Tooth Logger'), [
    for (var turn = 0; turn < 2; turn++)
      for (var tooth = 0; tooth < 35; tooth++)
        ...be32(tooth == 0 ? 3704 : 1852),
  ]);

  EcuConnected connected() => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  Future<_StubLogger> pumpScreen(
    WidgetTester tester,
    TriggerLoggerState state, {
    Size size = const Size(1200, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final stub = _StubLogger(state);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _FixedConnection(connected())),
          triggerLoggerProvider.overrideWith(() => stub),
        ],
        child: MaterialApp(
          home: Scaffold(body: TriggerLoggerScreen(connection: connected())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return stub;
  }

  group('the screen', () {
    testWidgets('offers the tooth and composite loggers the definition has', (
      tester,
    ) async {
      await pumpScreen(tester, const TriggerLoggerState());
      await tester.tap(find.byType(DropdownButton<int>));
      await tester.pumpAndSettle();
      for (final label in [
        'Tooth Logger',
        'Composite Logger',
        'Composite Logger 2nd Cam',
        'Composite Logger Both cams',
      ]) {
        expect(find.text(label), findsWidgets, reason: label);
      }
    });

    testWidgets('shows a tooth log as bars, with the gap picked out', (
      tester,
    ) async {
      await pumpScreen(tester, TriggerLoggerState(latest: toothLog()));
      expect(find.byType(ToothLogChart), findsOneWidget);
      expect(find.text('70 teeth'), findsOneWidget);
      expect(find.text('Typical 1.85 ms'), findsOneWidget);
      expect(find.text('Longest 3.70 ms (2.0 x typical)'), findsOneWidget);
      expect(find.text('2 long'), findsOneWidget, reason: 'once a turn');
    });

    testWidgets('shows a composite log as a trace per input that changes', (
      tester,
    ) async {
      final log = TriggerLog.decode(logger('Composite Logger'), [
        ...be32(1000000), 0x11, // crank high, in sync
        ...be32(1000926), 0x10, // crank low
        ...be32(1001300), 0x1B, // cam high, from the cam
        ...be32(1001852), 0x13, // crank high
        ...be32(1002778), 0x12, // crank low
        ...be32(1003100), 0x18, // cam low
      ]);
      await pumpScreen(tester, TriggerLoggerState(latest: log));
      expect(find.byType(CompositeLogChart), findsOneWidget);
      expect(find.text('PriLevel'), findsOneWidget);
      expect(find.text('SecLevel'), findsOneWidget);
      expect(find.text('Sync'), findsNothing, reason: 'held throughout');
      expect(find.text('6 edges over 3.10 ms'), findsOneWidget);
    });

    testWidgets('says so when nothing reached the ECU', (tester) async {
      final empty = TriggerLog.decode(logger('Tooth Logger'), [
        for (var i = 0; i < 127; i++) ...be32(0),
      ]);
      await pumpScreen(tester, TriggerLoggerState(latest: empty));
      expect(find.textContaining('no trigger edges reached'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Save CSV'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('fits a phone', (tester) async {
      await pumpScreen(
        tester,
        TriggerLoggerState(latest: toothLog()),
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Start and Stop run the chosen logger', (tester) async {
      final stub = await pumpScreen(tester, const TriggerLoggerState());
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(stub.starts, 1);
      expect(find.text('Waiting for the ECU to fill a capture...'), findsOne);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(stub.stops, 1);
      expect(find.text('Start'), findsOneWidget);
    });
  });

  group('the tab', () {
    Future<_StubLogger> pumpShell(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final stub = _StubLogger(const TriggerLoggerState());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(
              () => _FixedConnection(connected()),
            ),
            tuneProvider.overrideWith(_FixedTune.new),
            screenWakeProvider.overrideWithValue(_NoWake()),
            realtimeProvider.overrideWith(
              (ref) => const Stream<RealtimeSnapshot>.empty(),
            ),
            triggerLoggerProvider.overrideWith(() => stub),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pump();
      return stub;
    }

    testWidgets('leaving it stops a running logger', (tester) async {
      final stub = await pumpShell(tester);
      await tester.tap(find.text('Triggers'));
      await tester.pump();
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(stub.starts, 1);

      await tester.tap(find.text('Dashboard'));
      await tester.pump();
      expect(stub.stops, 1);
    });

    testWidgets('disconnecting stops a running logger first', (tester) async {
      final stub = await pumpShell(tester);
      await tester.tap(find.byTooltip('Disconnect'));
      await tester.pump();
      expect(stub.stops, 1);
    });
  });

  group('against a simulated Speeduino', () {
    Future<void> waitFor(bool Function() condition) async {
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!condition()) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('reads captures while running, and stops the ECU logging', () async {
      final ecu = FakeSpeeduino()..triggerRpm = 4000;
      final port = await ecu.start();
      final storage = Directory.systemTemp.createTempSync('foxtune_loggers');
      final container = ProviderContainer(
        overrides: [
          bundledDefinitionProvider.overrideWith((ref) async => doc),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
          definitionFetcherProvider.overrideWithValue((url) async => null),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await ecu.stop();
        storage.deleteSync(recursive: true);
      });

      await container
          .read(connectionProvider.notifier)
          .connectToNetwork('127.0.0.1:$port');
      expect(container.read(connectionProvider), isA<EcuConnected>());
      // The live data, which says when a capture is ready.
      container.listen(realtimeProvider, (_, _) {});

      final controller = container.read(triggerLoggerProvider.notifier);
      await controller.start();
      expect(ecu.runningLogger, SpeeduinoCommand.toothLoggerStart);

      await waitFor(() => container.read(triggerLoggerProvider).captures >= 2);
      final latest = container.read(triggerLoggerProvider).latest!;
      expect(latest.records, hasLength(FakeSpeeduino.toothLogSize));
      expect(
        latest.toothTimes.reduce((a, b) => a > b ? a : b),
        closeTo(0.833, 0.001),
      );

      await controller.stop();
      expect(container.read(triggerLoggerProvider).running, isFalse);
      expect(ecu.runningLogger, isNull);
    });
  });
}
