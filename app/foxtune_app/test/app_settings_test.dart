import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/main.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/app_settings/app_settings_screen.dart';
import 'package:foxtune_app/src/app_settings/wallpaper.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/definitions/definitions_screen.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/window/window_controls.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/testing.dart';
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

/// Notes how each port was asked to be opened, and opens none.
class _RecordingTransport implements EcuTransport {
  final opened = <(int, Duration)>[];

  @override
  String get name => 'recording';

  @override
  Stream<EcuPortEvent> get portEvents => const Stream.empty();

  @override
  Future<List<EcuPort>> listPorts() async => const [];

  @override
  Future<EcuLink> open(
    EcuPort port, {
    int baudRate = kSpeeduinoBaudRate,
    Duration delayAfterOpen = kDelayAfterPortOpen,
  }) async {
    opened.add((baudRate, delayAfterOpen));
    throw EcuTransportException('not a real port', port: port);
  }
}

/// A one-pixel PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// Hands out [next] when asked for a file.
class _Files extends FileSaving {
  _Files() : super(mobile: false);

  PickedFile? next;

  @override
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async => next;
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
        downloadDefinitionsFor: {EcuFamily.rusefi},
        keepScreenOn: false,
        baudRate: 57600,
        delayAfterOpen: Duration.zero,
        liveDataRate: 15,
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
          'downloadDefinitions': {'rusefi': false, 'speeduino': 'maybe'},
          'baudRate': -9600,
          'delayAfterOpenMs': 'long',
          'liveDataRate': 0,
        }),
        const AppSettings(downloadDefinitionsFor: {EcuFamily.speeduino}),
      );
    });

    test('reads the one switch for every download it once had', () {
      expect(
        AppSettings.fromJson({'downloadDefinitions': false})
            .downloadDefinitionsFor,
        isEmpty,
      );
      expect(
        AppSettings.fromJson({'downloadDefinitions': true})
            .downloadDefinitionsFor,
        AppSettings.downloadable,
      );
    });

    test('turns a live data rate into the time between reads', () {
      expect(
        const AppSettings(liveDataRate: 20).liveDataInterval,
        const Duration(milliseconds: 50),
      );
    });
  });

  group('screen', () {
    late _Files files;
    setUp(() => files = _Files());

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
            fileSavingProvider.overrideWithValue(files),
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
      await tester.pumpAndSettle();

      /// Opens the setting called [title] and picks [choice] from its list.
      Future<void> pick(String title, String choice) async {
        final setting = find.text(title);
        await tester.scrollUntilVisible(setting, 100);
        await tester.pumpAndSettle();
        await tester.tap(setting);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.text(choice),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pick('Baud rate', '57600');
      await pick('Wait after opening a port', 'None');
      await pick('Live data rate', '15 times a second');

      final keepOn = find.text('Keep the screen on while connected');
      await tester.scrollUntilVisible(keepOn, 100);
      await tester.pumpAndSettle();
      await tester.tap(keepOn);
      await tester.pumpAndSettle();

      const expected = AppSettings(
        themeMode: ThemeMode.dark,
        temperatureUnit: TemperatureUnit.fahrenheit,
        keepScreenOn: false,
        baudRate: 57600,
        delayAfterOpen: Duration.zero,
        liveDataRate: 15,
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
      // Far enough down that the list has not built it yet.
      final tile = find.widgetWithText(ListTile, 'ECU definitions');
      await tester.scrollUntilVisible(tile, 100);
      await tester.pumpAndSettle();
      expect(find.text('1 built in, 0 on this device'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(DefinitionsScreen), findsOneWidget);
    });

    group('wallpaper', () {
      Wallpaper wallpaperOf(ProviderContainer container) =>
          container.read(appSettingsProvider).wallpaper;

      testWidgets('an image is chosen, kept, and laid out as set', (
        tester,
      ) async {
        final container = await pumpSettings(tester);
        files.next = PickedFile(name: 'dash.png', bytes: _png);

        await tester.tap(find.text('Image'));
        await tester.pumpAndSettle();
        final chosen = wallpaperOf(container);
        expect(chosen.kind, WallpaperKind.image);
        expect(chosen.imageName, 'dash.png');
        expect(File(chosen.image!).parent.path, '${storage.path}/wallpapers');
        expect(find.text('dash.png'), findsOneWidget);

        final tile = find.text('Tile');
        await tester.scrollUntilVisible(tile, 100);
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Top left'));
        await tester.pumpAndSettle();

        final laidOut = wallpaperOf(container);
        expect(laidOut.fit, WallpaperFit.tile);
        expect(laidOut.alignment, Alignment.topLeft);
        final saved = AppSettings.fromJson(
          jsonDecode(File('${storage.path}/settings.json').readAsStringSync()),
        );
        expect(saved.wallpaper, laidOut);
      });

      testWidgets('a file that is no image is refused', (tester) async {
        final container = await pumpSettings(tester);
        files.next = PickedFile(
          name: 'notes.png',
          bytes: Uint8List.fromList(utf8.encode('not a picture')),
        );

        await tester.tap(find.text('Image'));
        await tester.pumpAndSettle();
        expect(
          find.text('notes.png is not an image FoxTune can show.'),
          findsOneWidget,
        );
        expect(wallpaperOf(container).kind, WallpaperKind.branding);
      });

      testWidgets('none leaves nothing to set', (tester) async {
        final container = await pumpSettings(tester);
        expect(find.text('Strength'), findsOneWidget);

        await tester.tap(find.text('None'));
        await tester.pumpAndSettle();
        expect(wallpaperOf(container).kind, WallpaperKind.none);
        expect(find.text('Strength'), findsNothing);
        expect(find.byType(WallpaperView), findsNothing);
      });

      testWidgets('the preview follows the slider as it is dragged', (
        tester,
      ) async {
        final container = await pumpSettings(tester);
        final slider = find.byType(Slider);
        await tester.scrollUntilVisible(slider, 100);
        await tester.pumpAndSettle();
        double previewed() => tester
            .widget<WallpaperView>(find.byType(WallpaperView))
            .wallpaper
            .strength;

        final drag = await tester.startGesture(tester.getCenter(slider));
        await drag.moveBy(const Offset(100, 0));
        await tester.pump();
        final dragged = previewed();
        expect(dragged, isNot(Wallpaper.defaultStrength));
        // Kept to the preview until the slider is let go.
        expect(wallpaperOf(container).strength, Wallpaper.defaultStrength);

        await drag.up();
        await tester.pumpAndSettle();
        expect(wallpaperOf(container).strength, dragged);
        expect(previewed(), dragged);
      });

      testWidgets('its strength steps by whole percents - from a keyboard or '
          'a screen reader as well as a drag', (tester) async {
        final semantics = tester.ensureSemantics();
        final container = await pumpSettings(tester);
        await tester.scrollUntilVisible(find.byType(Slider), 100);
        await tester.pumpAndSettle();

        tester.semantics.performAction(
          find.semantics.byAction(SemanticsAction.increase),
          SemanticsAction.increase,
        );
        await tester.pumpAndSettle();
        // Saved as it is, one step on - not held for a drag to end.
        expect(wallpaperOf(container).strength, closeTo(0.16, 1e-9));
        expect(find.text('16%'), findsOneWidget);
        semantics.dispose();
      });

      testWidgets('its strength is saved once the slider is let go', (
        tester,
      ) async {
        final container = await pumpSettings(tester);
        final slider = find.byType(Slider);
        await tester.scrollUntilVisible(slider, 100);
        await tester.pumpAndSettle();

        await tester.drag(slider, const Offset(200, 0));
        await tester.pumpAndSettle();
        final strength = wallpaperOf(container).strength;
        expect(strength, greaterThan(Wallpaper.defaultStrength));
        expect(find.text('${(strength * 100).round()}%'), findsOneWidget);
      });
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

  test(
    'a serial port is opened at the speed and with the wait chosen',
    () async {
      final transport = _RecordingTransport();
      final container = ProviderContainer(
        overrides: [
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(
              baudRate: 57600,
              delayAfterOpen: Duration(milliseconds: 500),
            ),
          ),
          transportProvider.overrideWithValue(transport),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(connectionProvider.notifier)
          .connect(const EcuPort(address: '/dev/ttyUSB0'));
      expect(transport.opened, [(57600, const Duration(milliseconds: 500))]);
    },
  );

  test(
    'live data is read at the chosen rate, and a new one applies at once',
    () async {
      final ecu = FakeSpeeduino(
        signature: speeduino.identity.signature!,
        pageSizes: speeduino.constants.pageSizes,
        realtimeBlockSize: speeduino.outputChannels.blockSize!,
        blockingFactor: speeduino.constants.blockingFactor!,
        channels: speeduino.outputChannels,
      );
      final port = await ecu.start();
      final container = ProviderContainer(
        overrides: [
          initialAppSettingsProvider.overrideWithValue(
            const AppSettings(liveDataRate: 10),
          ),
          bundledDefinitionProvider.overrideWith((ref) async => speeduino),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await ecu.stop();
      });

      await container
          .read(connectionProvider.notifier)
          .connectToNetwork('127.0.0.1:$port');
      expect(
        container.read(realtimeMonitorProvider)!.interval,
        const Duration(milliseconds: 100),
      );

      container
          .read(appSettingsProvider.notifier)
          .update((s) => s.copyWith(liveDataRate: 20));
      expect(
        container.read(realtimeMonitorProvider)!.interval,
        const Duration(milliseconds: 50),
      );
    },
  );

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
