import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/main.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/app_settings/app_settings_screen.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/definitions/definitions_screen.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/window/window_controls.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

const _connected = EcuConnected(
  port: EcuPort(address: '/dev/ttyACM0'),
  identification: EcuIdentification(
    signature: 'speeduino 202501',
    version: 'test',
  ),
  signatureStatus: SignatureStatus.unknown,
  expectedSignature: null,
);

class _FixedConnection extends ConnectionController {
  _FixedConnection(this._initial);
  final EcuConnectionState _initial;

  @override
  EcuConnectionState build() => _initial;
}

class _RecordingWake implements ScreenWake {
  final calls = <String>[];

  @override
  Future<void> hold() async => calls.add('hold');

  @override
  Future<void> release() async => calls.add('release');
}

class _FakeWindow implements WindowControls {
  @override
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  @override
  Future<void> startDragging() async {}

  @override
  Future<void> minimize() async {}

  @override
  Future<void> toggleMaximize() async {}

  @override
  Future<void> close() async {}
}

void main() {
  late IniDocument speeduino;
  late Directory storage;

  setUpAll(() {
    speeduino = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_app'));
  tearDown(() => storage.deleteSync(recursive: true));

  group('AppSettings', () {
    test('reads back what it writes', () {
      const settings = AppSettings(
        themeMode: ThemeMode.dark,
        temperatureUnit: TemperatureUnit.fahrenheit,
        downloadDefinitions: false,
        keepScreenOn: false,
      );
      expect(AppSettings.fromJson(settings.toJson()), settings);
    });

    test('keeps the default for anything it cannot use, one at a time', () {
      expect(AppSettings.fromJson(null), const AppSettings());
      expect(
        AppSettings.fromJson({
          'theme': 'purple',
          'temperature': 'kelvin',
          'keepScreenOn': 'yes',
          'downloadDefinitions': false,
        }),
        const AppSettings(downloadDefinitions: false),
      );
    });
  });

  group('screen', () {
    Future<ProviderContainer> pumpSettings(
      WidgetTester tester, {
      EcuConnectionState connection = const EcuDisconnected(),
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStorageDirectoryProvider.overrideWith((ref) async => storage),
            bundledDefinitionProvider.overrideWith((ref) async => speeduino),
            connectionProvider.overrideWith(() => _FixedConnection(connection)),
          ],
          child: const MaterialApp(home: AppSettingsScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(AppSettingsScreen)),
      );
    }

    testWidgets('changes take effect at once, and are kept', (tester) async {
      final container = await pumpSettings(tester);

      await tester.tap(find.text('Dark'));
      await tester.tap(find.text('°F'));
      await tester.tap(find.text('Keep the screen on while connected'));
      await tester.tap(find.text('Download definitions automatically'));
      await tester.pumpAndSettle();

      const expected = AppSettings(
        themeMode: ThemeMode.dark,
        temperatureUnit: TemperatureUnit.fahrenheit,
        downloadDefinitions: false,
        keepScreenOn: false,
      );
      expect(container.read(appSettingsProvider), expected);
      expect(
        container.read(temperatureUnitProvider),
        TemperatureUnit.fahrenheit,
      );
      final saved = File('${storage.path}/settings.json');
      expect(
        AppSettings.fromJson(jsonDecode(saved.readAsStringSync())),
        expected,
      );
    });

    testWidgets('says a new temperature scale waits for the next connection', (
      tester,
    ) async {
      await pumpSettings(tester, connection: _connected);
      expect(
        find.textContaining('Applies from the next connection'),
        findsOneWidget,
      );
    });

    testWidgets('has nothing to wait for while disconnected', (tester) async {
      await pumpSettings(tester);
      expect(
        find.textContaining('Applies from the next connection'),
        findsNothing,
      );
    });

    testWidgets('leads to the ECU definitions', (tester) async {
      await pumpSettings(tester);
      final tile = find.widgetWithText(ListTile, 'ECU definitions');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      expect(find.text('1 built in, 0 on this device'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(DefinitionsScreen), findsOneWidget);
    });
  });

  testWidgets('the app follows the chosen theme', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(themeMode: ThemeMode.dark),
          ),
          portsProvider.overrideWith((ref) async => const []),
          screenWakeProvider.overrideWithValue(_RecordingWake()),
        ],
        child: const FoxTuneApp(),
      ),
    );
    await tester.pumpAndSettle();

    Brightness brightness() =>
        Theme.of(tester.element(find.byType(ConnectScreen))).brightness;
    expect(brightness(), Brightness.dark);

    ProviderScope.containerOf(tester.element(find.byType(ConnectScreen)))
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.light));
    await tester.pumpAndSettle();
    expect(brightness(), Brightness.light);
  });

  testWidgets('the top bar ends with App settings, just before the window '
      'buttons', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          windowControlsProvider.overrideWithValue(_FakeWindow()),
          portsProvider.overrideWith((ref) async => const []),
          screenWakeProvider.overrideWithValue(_RecordingWake()),
          bundledDefinitionProvider.overrideWith((ref) async => speeduino),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final rescan = tester.getRect(find.byTooltip('Rescan ports'));
    final settings = tester.getRect(find.byTooltip('App settings'));
    final minimize = tester.getRect(find.byTooltip('Minimize'));
    expect(rescan.right, lessThanOrEqualTo(settings.left));
    expect(settings.right, lessThanOrEqualTo(minimize.left));

    await tester.tap(find.byTooltip('App settings'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsScreen), findsOneWidget);
  });

  test('turning off keeping the screen on lets go of it at once', () {
    final wake = _RecordingWake();
    final container = ProviderContainer(
      overrides: [
        appStorageDirectoryProvider.overrideWith((ref) async => storage),
        connectionProvider.overrideWith(() => _FixedConnection(_connected)),
        screenWakeProvider.overrideWithValue(wake),
      ],
    );
    addTearDown(container.dispose);
    container.listen(screenWakeWatcherProvider, (_, _) {});
    expect(wake.calls, ['hold']);

    void keepScreenOn(bool on) {
      container
          .read(appSettingsProvider.notifier)
          .update((s) => s.copyWith(keepScreenOn: on));
      // Rebuilds it now rather than on the next frame.
      container.read(screenWakeWatcherProvider);
    }

    keepScreenOn(false);
    expect(wake.calls, ['hold', 'release']);

    keepScreenOn(true);
    expect(wake.calls, ['hold', 'release', 'hold']);
  });
}
