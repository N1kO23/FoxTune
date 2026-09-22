import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
import 'package:foxtune_app/src/dashboard/gauge_catalog.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// Renders the dashboard from a snapshot decoded against the real bundled
/// definition, so the whole display path is exercised: byte layout, scaling,
/// computed channels and widget layout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _definitionUnitTests();

  late IniDocument doc;
  late Directory storage;

  setUpAll(() async {
    final source = await rootBundle.loadString('assets/speeduino.ini');
    doc = IniParser(defined: {'CELSIUS'}).parse(source);
  });

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_dash'));
  tearDown(() => storage.deleteSync(recursive: true));

  /// Builds a realtime block with the given raw values at their real offsets.
  Uint8List blockWith(Map<String, int> raws) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);
    raws.forEach((name, value) {
      final field = channels.channelNamed(name)! as IniScalarField;
      final offset = field.offset!;
      switch (field.type) {
        case IniDataType.u08:
          view.setUint8(offset, value);
        case IniDataType.s08:
          view.setInt8(offset, value);
        case IniDataType.u16:
          view.setUint16(offset, value, Endian.little);
        case IniDataType.s16:
          view.setInt16(offset, value, Endian.little);
        case IniDataType.u32:
        case IniDataType.s32:
        case IniDataType.f32:
          throw UnsupportedError('not needed here');
      }
    });
    return block;
  }

  EcuConnected connectionFor() => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  /// What every dashboard test needs: the connection the screen shows, and a
  /// storage folder of its own so no saved layout leaks between tests.
  List<Override> baseOverrides() => [
    connectionProvider.overrideWith(() => _Connected(connectionFor())),
    appStorageDirectoryProvider.overrideWith((ref) async => storage),
    realtimeMonitorProvider.overrideWithValue(null),
  ];

  Future<void> pumpDashboard(
    WidgetTester tester,
    Uint8List block, {
    Size size = const Size(1200, 1000),
  }) async {
    final snapshot = RealtimeDecoder(doc.outputChannels).decode(block);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(),
          realtimeProvider.overrideWith(
            (ref) => Stream<RealtimeSnapshot>.value(snapshot),
          ),
        ],
        child: MaterialApp(
          theme: brandTheme(Brightness.light),
          home: Scaffold(body: DashboardScreen(connection: connectionFor())),
        ),
      ),
    );
    // The layout loads asynchronously; let it arrive.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders the primary gauges with decoded values', (tester) async {
    await pumpDashboard(
      tester,
      blockWith({
        'rpm': 3500,
        'map': 95,
        'coolantRaw': 130, // 90 C once the definition's offset is applied
        'batteryVoltage': 138,
        'tps': 84,
        'afr': 147,
      }),
    );

    expect(find.text('3500'), findsOneWidget);
    expect(find.text('95'), findsOneWidget);
    // Only available because the computed-channel expression was evaluated.
    expect(find.text('90'), findsOneWidget);
    // The tachometer's own title and units, from the definition.
    expect(find.text('Engine Speed'), findsOneWidget);
    expect(find.text('RPM'), findsWidgets);
  });

  testWidgets('renders readouts at the definition\'s precision', (
    tester,
  ) async {
    await pumpDashboard(
      tester,
      blockWith({
        'rpm': 1000,
        'batteryVoltage': 138, // scale 0.1 -> 13.8
        'tps': 84, // scale 0.5 -> 42
        'afr': 147, // scale 0.1 -> 14.7
      }),
    );

    // Each gauge's own decimal places, from `[GaugeConfigurations]`.
    expect(find.text('13.80'), findsOneWidget);
    expect(find.text('42.0'), findsOneWidget);
    expect(find.text('14.70'), findsOneWidget);
  });

  testWidgets('raises a labelled alarm past the redline', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 7400}));

    expect(find.text('7400'), findsOneWidget);
    // The alarm must be legible without relying on colour.
    expect(find.text('DANGER'), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.error_rounded), findsAtLeastNWidgets(1));
  });

  testWidgets('flags low battery voltage', (tester) async {
    // The definition's battery gauge calls danger at 8 V and below.
    await pumpDashboard(tester, blockWith({'rpm': 800, 'batteryVoltage': 75}));

    expect(find.text('7.50'), findsOneWidget);
    expect(find.text('DANGER'), findsAtLeastNWidgets(1));
  });

  testWidgets('offers a record control when connected', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 1200}));
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('shows status lamps in their real state', (tester) async {
    // Bit 0 of the status byte is "running". The lamps read the definition's
    // own labels for each state rather than one fixed caption.
    await pumpDashboard(tester, blockWith({'rpm': 900, 'engine': 1}));
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Not Cranking'), findsOneWidget);
  });

  testWidgets('a stopped engine reads zero without dividing by zero', (
    tester,
  ) async {
    await pumpDashboard(tester, blockWith({'rpm': 0}));

    expect(find.text('0'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out at phone width without overflowing', (tester) async {
    await pumpDashboard(
      tester,
      blockWith({'rpm': 2500}),
      size: const Size(400, 900),
    );

    // A RenderFlex overflow would surface here.
    expect(tester.takeException(), isNull);
    expect(find.text('2500'), findsOneWidget);
  });

  testWidgets('shows a waiting state before the first sample', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(),
          realtimeProvider.overrideWith(
            (ref) => const Stream<RealtimeSnapshot>.empty(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: DashboardScreen(connection: connectionFor())),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('Waiting for the first realtime sample'),
      findsOneWidget,
    );
  });
}

void _definitionUnitTests() {
  group('definition temperature scale', () {
    /// The definition the app builds for [unit].
    Future<IniDocument> definitionFor(TemperatureUnit unit) async {
      final container = ProviderContainer(
        overrides: [temperatureUnitProvider.overrideWith((ref) => unit)],
      );
      addTearDown(container.dispose);
      return container.read(definitionProvider.future);
    }

    /// Decodes a coolant reading through the definition the app actually
    /// builds, rather than one the test parsed itself.
    Future<double?> coolantFor(TemperatureUnit unit) async {
      final container = ProviderContainer(
        overrides: [temperatureUnitProvider.overrideWith((ref) => unit)],
      );
      addTearDown(container.dispose);

      final definition = await container.read(definitionProvider.future);
      final channels = definition.outputChannels;
      final block = Uint8List(channels.blockSize!);
      // 130 raw is 90 C once the definition's 40 degree offset is applied.
      ByteData.sublistView(block)
          .setUint8(channels.channelNamed('coolantRaw')!.offset!, 130);
      return RealtimeDecoder(channels).decode(block)['coolant'];
    }

    test('defaults to Celsius, matching the gauge limits', () async {
      // The regression: the app parsed with no symbols at all, so the
      // definition fell through to Fahrenheit while the gauges kept Celsius
      // limits - a healthy engine read 226 and pegged at DANGER.
      final reading = await coolantFor(TemperatureUnit.celsius);
      expect(reading, closeTo(90, 1e-9));

      final gauge =
          GaugeCatalog(definition: await definitionFor(TemperatureUnit.celsius))
              .specFor(
                (await definitionFor(TemperatureUnit.celsius))
                    .gaugeNamed('cltGauge')!,
              );
      expect(gauge.statusFor(reading), GaugeStatus.normal);
      expect(gauge.fractionFor(reading), lessThan(1.0));
    });

    test('selecting Fahrenheit changes the decoded value too', () async {
      // Proof the setting picks a definition branch, not just a label.
      final reading = await coolantFor(TemperatureUnit.fahrenheit);
      expect(reading, closeTo(194, 1e-6));

      final definition = await definitionFor(TemperatureUnit.fahrenheit);
      final gauge = GaugeCatalog(definition: definition)
          .specFor(definition.gaugeNamed('cltGauge')!);
      expect(
        gauge.statusFor(reading),
        GaugeStatus.normal,
        reason: '194 F is 90 C - still a healthy engine',
      );
      expect(gauge.fractionFor(reading), lessThan(1.0));
    });
  });
}

/// A connection held as connected, as the dashboard only ever is shown.
class _Connected extends ConnectionController {
  _Connected(this._state);

  final EcuConnectionState _state;

  @override
  EcuConnectionState build() => _state;
}
