import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/calibration/sensor_calibration_panel.dart';
import 'package:foxtune_app/src/calibration/tps_calibration_panel.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/settings/settings_screen.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);
  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

/// A connection held as the test sets it, speaking through [client].
class _Connected extends ConnectionController {
  _Connected(this._state, this._client);
  final EcuConnectionState _state;
  final EcuClient? _client;

  @override
  EcuConnectionState build() => _state;

  @override
  EcuClient? get client => _client;
}

/// Sensor calibrations: made from the definition's own choices, sent to a
/// simulated Speeduino over a real socket, and checked by its checksum.
void main() {
  late IniDocument doc;
  late IniReferenceTable thermistors;
  late IniReferenceTable afr;
  late TuneState tune;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
    thermistors = doc.referenceTables!.tableNamed('std_ms2gentherm')!;
    afr = doc.referenceTables!.tableNamed('std_ms2geno2')!;
  });

  setUp(() => tune = TuneState.empty(doc)..markClean());

  SensorCalibration thermistor(String name, {int target = 0}) {
    final t = thermistors.thermistors.firstWhere((t) => t.name == name);
    return SensorCalibration.thermistor(
      thermistors,
      target: target,
      biasOhms: t.biasOhms,
      curve: ThermistorCurve.fit(t.points),
    );
  }

  EcuConnected connection({String? signature}) => EcuConnected(
    port: const EcuPort(address: '127.0.0.1:2000'),
    identification: EcuIdentification(
      signature: signature ?? doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  FakeSpeeduino? ecu;
  SocketEcuLink? link;
  EcuClient? client;

  Future<void> startEcu(WidgetTester tester) async {
    await tester.runAsync(() async {
      final fake = ecu = FakeSpeeduino();
      final port = await fake.start();
      final socket = link = await SocketEcuLink.connect('127.0.0.1', port);
      client = EcuClient(socket, timeout: const Duration(seconds: 2));
    });
  }

  Future<void> stopEcu(WidgetTester tester) async {
    await tester.runAsync(() async {
      await client?.close();
      await link?.close();
      await ecu?.stop();
    });
    ecu = null;
    link = null;
    client = null;
  }

  /// Lets replies cross the real socket, and the screen catch up with them.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    EcuConnected? connected,
    WritePermission permission = const WritePermission.granted(),
    RealtimeSnapshot? live,
    Size size = const Size(1400, 1100),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(
            () => _Connected(connected ?? connection(), client),
          ),
          tuneProvider.overrideWith(() => _FakeTuneController(tune)),
          writePermissionProvider.overrideWithValue(permission),
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => live == null
                ? const Stream<RealtimeSnapshot>.empty()
                : Stream.value(live),
          ),
        ],
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );
    await tester.pump();
    await settle(tester);
  }

  Widget detail(String target, {EcuConnected? connected}) =>
      SettingDetail(target: target, connection: connected ?? connection());

  Future<void> choose(WidgetTester tester, Type field, String option) async {
    await tester.tap(find.byType(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> sendAndConfirm(WidgetTester tester) async {
    await tester.tap(find.text('Send to ECU'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pump();
    await settle(tester);
  }

  test('reads the release a Speeduino signature names', () {
    expect(speeduinoRelease('speeduino 202501'), 202501);
    expect(speeduinoRelease('speeduino 202504-dev'), 202504);
    expect(speeduinoRelease('rusEFI master.2026.09.21.uaefi.419928595'), null);
  });

  testWidgets('the Tools menu offers the calibrations, the throttle\'s after '
      'them', (tester) async {
    SettingView.of(tune, 'egoType')!.setOptionIndex(2);
    await pump(tester, SettingsScreen(connection: connection()));
    await tester.enterText(find.byType(TextField).first, 'calibrate');
    await tester.pumpAndSettle();

    double top(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(
      top('Calibrate Temperature Sensors'),
      lessThan(top('Calibrate AFR Sensor')),
    );
    expect(
      top('Calibrate AFR Sensor'),
      lessThan(top(TpsCalibrationPanel.title)),
    );
  });

  group('thermistor tables', () {
    testWidgets('start from the one the ECU has, told by its checksum', (
      tester,
    ) async {
      await startEcu(tester);
      ecu!.sensorTableCrcs[0] = thermistor('Bosch CLT/IAT').crc;
      await pump(tester, detail('std_ms2gentherm'));

      expect(
        find.text('On the ECU now: Bosch CLT/IAT, as shown here.'),
        findsOneWidget,
      );
      expect(find.text('Bosch CLT/IAT'), findsOneWidget);
      await stopEcu(tester);
    });

    testWidgets('send the chosen thermistor\'s table, checked by the ECU\'s '
        'checksum', (tester) async {
      await startEcu(tester);
      await pump(tester, detail('std_ms2gentherm'));
      expect(
        find.textContaining('a table none of these choices makes'),
        findsOneWidget,
      );

      await choose(tester, DropdownButtonFormField<String>, 'GM');
      await sendAndConfirm(tester);

      expect(ecu!.sensorTables[0], thermistor('GM').encode());
      expect(find.textContaining('Sent and saved'), findsOneWidget);
      expect(find.text('On the ECU now: GM, as shown here.'), findsOneWidget);
      await stopEcu(tester);
    });

    testWidgets('the air sensor has its own fallback', (tester) async {
      await startEcu(tester);
      await pump(tester, detail('std_ms2gentherm'));
      await choose(
        tester,
        DropdownButtonFormField<int>,
        'Air Temperature Sensor',
      );
      await choose(tester, DropdownButtonFormField<String>, 'GM');
      await sendAndConfirm(tester);

      expect(ecu!.sensorTables[1], thermistor('GM', target: 1).encode());
      expect(ecu!.sensorTables, isNot(contains(0)));
      await stopEcu(tester);
    });

    testWidgets('are not sent without write mode', (tester) async {
      await pump(
        tester,
        detail('std_ms2gentherm'),
        permission: const WritePermission.refused('Write mode is off.'),
      );
      expect(find.text('Write mode is off.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send to ECU'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('refuse points no thermistor could have', (tester) async {
      await pump(tester, detail('std_ms2gentherm'));
      // The first point's resistance, made lower than the second's.
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(2), '100');
      await tester.pump();

      expect(find.textContaining('has to fall as the temperature'), findsOne);
      expect(find.text('My own values'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send to ECU'),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('the O2 table', () {
    testWidgets('is made from the sensor\'s formula and sent in pieces', (
      tester,
    ) async {
      await startEcu(tester);
      await pump(tester, detail('std_ms2geno2'));
      await choose(tester, DropdownButtonFormField<int>, '14Point7');
      await sendAndConfirm(tester);

      final expected = SensorCalibration.formula(
        afr,
        target: 2,
        expression: afr.solutions
            .firstWhere((s) => s.label == '14Point7')
            .expression!,
      ).encode();
      expect(ecu!.sensorTables[2], expected);
      final writes = [
        for (final r in ecu!.requests)
          if (r[0] == SpeeduinoCommand.tableWrite) r,
      ];
      expect(writes, hasLength(4), reason: '1024 bytes, 256 at a time');
      expect(find.textContaining('Sent and saved'), findsOneWidget);
      await stopEcu(tester);
    });

    testWidgets('is not checked on firmware whose checksum of it is broken', (
      tester,
    ) async {
      final older = connection(signature: 'speeduino 202402');
      await pump(
        tester,
        detail('std_ms2geno2', connected: older),
        connected: older,
      );
      expect(
        find.textContaining('keeps no usable checksum of its O2 table'),
        findsOneWidget,
      );
    });

    testWidgets('marks the formulas that need an .inc file', (tester) async {
      await pump(tester, detail('std_ms2geno2'));
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      expect(find.text('Narrowband (needs an .inc file)'), findsWidgets);
    });
  });

  testWidgets('every calibration fits a phone', (tester) async {
    for (final target in [
      'std_ms2gentherm',
      'std_ms2geno2',
      TpsCalibrationPanel.target,
    ]) {
      await pump(tester, detail(target), size: const Size(360, 780));
      expect(tester.takeException(), isNull, reason: target);
    }
  });

  group('the throttle', () {
    RealtimeSnapshot reading(int adc) {
      final block = Uint8List(doc.outputChannels.blockSize!);
      final field = doc.outputChannels.channelNamed('tpsADC')!;
      block[field.offset!] = adc;
      return RealtimeDecoder(doc.outputChannels).decode(block);
    }

    test('is offered where the readings are kept in the sensor\'s units', () {
      expect(TpsCalibrationPanel.availableFor(doc), isTrue);
      final rusEfi = IniParser().parse(
        File('../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini')
            .readAsStringSync(),
      );
      expect(TpsCalibrationPanel.availableFor(rusEfi), isFalse);
    });

    testWidgets('takes the closed and wide-open readings from the sensor', (
      tester,
    ) async {
      await pump(tester, detail(TpsCalibrationPanel.target), live: reading(37));
      expect(find.text('37'), findsOneWidget);

      await tester.tap(find.text('Use the reading').first);
      await tester.pump();
      expect(SettingView.of(tune, 'tpsMin')!.value, 37);
      expect(find.widgetWithText(TextField, '37'), findsOneWidget);
      expect(tune.isDirty, isTrue, reason: 'burned like any other change');
    });

    SettingView tps(String name) => SettingView.of(tune, name)!;

    Future<void> pumpStored(WidgetTester tester, {int? live}) async {
      tps('tpsMin').setValue(30);
      tps('tpsMax').setValue(220);
      tune.markClean();
      await pump(
        tester,
        detail(TpsCalibrationPanel.target),
        live: live == null ? null : reading(live),
      );
    }

    testWidgets('shows both in fields, which can be typed into', (
      tester,
    ) async {
      await pumpStored(tester);
      final closed = find.widgetWithText(TextField, '30');
      expect(closed, findsOneWidget);
      expect(find.widgetWithText(TextField, '220'), findsOneWidget);

      await tester.enterText(closed, '25');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tps('tpsMin').value, 25);
      expect(tune.isDirty, isTrue);
    });

    testWidgets('a reading taken replaces what was being typed into its '
        'field, and only its field', (tester) async {
      await pumpStored(tester, live: 37);

      // Half-typed into both, neither committed yet.
      await tester.enterText(find.widgetWithText(TextField, '220'), '200');
      await tester.enterText(find.widgetWithText(TextField, '30'), '50');
      await tester.tap(find.text('Use the reading').first);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(tps('tpsMin').value, 37, reason: 'not the 50 typed over it');
      expect(find.widgetWithText(TextField, '37'), findsOneWidget);
      expect(tps('tpsMax').value, 200, reason: 'typed, and left alone');
    });

    testWidgets('neither is editable without write mode', (tester) async {
      await pump(
        tester,
        detail(TpsCalibrationPanel.target),
        permission: const WritePermission.refused('Write mode is off.'),
        live: reading(37),
      );
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(field.enabled, isFalse);
      }
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Use the reading').first,
            )
            .onPressed,
        isNull,
      );
    });
  });
}
