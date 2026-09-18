import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
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

  setUpAll(() async {
    final source = await rootBundle.loadString('assets/speeduino.ini');
    doc = IniParser(defined: {'CELSIUS'}).parse(source);
  });

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

  Future<void> pumpDashboard(WidgetTester tester, Uint8List block) async {
    final snapshot = RealtimeDecoder(doc.outputChannels).decode(block);
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => Stream<RealtimeSnapshot>.value(snapshot),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC75B12),
            ),
          ),
          home: Scaffold(body: DashboardScreen(connection: connectionFor())),
        ),
      ),
    );
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
    expect(find.text('RPM'), findsOneWidget);
  });

  testWidgets('renders secondary tiles with scaling applied', (tester) async {
    await pumpDashboard(
      tester,
      blockWith({
        'rpm': 1000,
        'batteryVoltage': 138, // scale 0.1 -> 13.8
        'tps': 84, // scale 0.5 -> 42
        'afr': 147, // scale 0.1 -> 14.7
      }),
    );

    expect(find.text('13.8'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('14.7'), findsOneWidget);
  });

  testWidgets('raises a labelled alarm past the redline', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 7400}));

    expect(find.text('7400'), findsOneWidget);
    // The alarm must be legible without relying on colour.
    expect(find.text('DANGER'), findsAtLeastNWidgets(1));
    expect(find.byIcon(Icons.error_rounded), findsAtLeastNWidgets(1));
  });

  testWidgets('flags low battery voltage', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 800, 'batteryVoltage': 105}));

    expect(find.text('10.5'), findsOneWidget);
    expect(find.text('DANGER'), findsAtLeastNWidgets(1));
  });

  testWidgets('offers a record control when connected', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 1200}));
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('shows status lamps', (tester) async {
    await pumpDashboard(tester, blockWith({'rpm': 900}));
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Cranking'), findsOneWidget);
  });

  testWidgets('a stopped engine reads zero without dividing by zero', (
    tester,
  ) async {
    await pumpDashboard(tester, blockWith({'rpm': 0}));

    expect(find.text('0'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out at phone width without overflowing', (tester) async {
    final snapshot = RealtimeDecoder(doc.outputChannels)
        .decode(blockWith({'rpm': 2500}));
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => Stream<RealtimeSnapshot>.value(snapshot),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: DashboardScreen(connection: connectionFor())),
        ),
      ),
    );
    await tester.pump();

    // A RenderFlex overflow would surface here.
    expect(tester.takeException(), isNull);
    expect(find.text('2500'), findsOneWidget);
  });

  testWidgets('shows a waiting state before the first sample', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          realtimeMonitorProvider.overrideWithValue(null),
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

      final gauge = DefaultGauges.coolant(TemperatureUnit.celsius);
      expect(gauge.statusFor(reading), GaugeStatus.normal);
      expect(gauge.fractionFor(reading), lessThan(1.0));
    });

    test('selecting Fahrenheit changes the decoded value too', () async {
      // Proof the setting picks a definition branch, not just a label.
      final reading = await coolantFor(TemperatureUnit.fahrenheit);
      expect(reading, closeTo(194, 1e-6));

      final gauge = DefaultGauges.coolant(TemperatureUnit.fahrenheit);
      expect(
        gauge.statusFor(reading),
        GaugeStatus.normal,
        reason: '194 F is 90 C - still a healthy engine',
      );
      expect(gauge.fractionFor(reading), lessThan(1.0));
    });
  });
}
