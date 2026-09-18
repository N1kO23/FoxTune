import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/stat_tile.dart';

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC75B12),
          brightness: brightness,
        ),
      ),
      home: Scaffold(
        body: Center(child: SizedBox(width: 200, child: child)),
      ),
    );

const rpm = GaugeSpec(
  channel: 'rpm',
  label: 'RPM',
  units: 'rpm',
  min: 0,
  max: 8000,
  warnAbove: 6000,
  dangerAbove: 7000,
);

void main() {
  group('MeterGauge', () {
    testWidgets('shows the value and label', (tester) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: 3500)));
      expect(find.text('3500'), findsOneWidget);
      expect(find.text('RPM'), findsOneWidget);
    });

    testWidgets('shows a placeholder when the reading is unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: null)));
      expect(find.text('--'), findsOneWidget);
    });

    testWidgets('an alarm carries text, not colour alone', (tester) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: 7200)));
      // The requirement is that the state survives a colour-blind reading.
      expect(find.text('DANGER'), findsOneWidget);
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    });

    testWidgets('warning state is labelled too', (tester) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: 6200)));
      expect(find.text('WARN'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('no badge in the normal range', (tester) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: 2000)));
      expect(find.text('WARN'), findsNothing);
      expect(find.text('DANGER'), findsNothing);
    });

    testWidgets('renders in dark mode', (tester) async {
      await tester.pumpWidget(
        wrap(
          const MeterGauge(spec: rpm, value: 3500),
          brightness: Brightness.dark,
        ),
      );
      expect(find.text('3500'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('exposes a screen-reader description', (tester) async {
      await tester.pumpWidget(wrap(const MeterGauge(spec: rpm, value: 7200)));
      expect(
        find.bySemanticsLabel(RegExp(r'RPM: 7200 rpm, DANGER')),
        findsOneWidget,
      );
    });
  });

  group('StatTile', () {
    const battery = GaugeSpec(
      channel: 'batteryVoltage',
      label: 'Battery',
      units: 'V',
      min: 8,
      max: 16,
      decimals: 1,
      warnBelow: 12.0,
      dangerBelow: 11.0,
    );

    testWidgets('shows value and units', (tester) async {
      await tester.pumpWidget(wrap(const StatTile(spec: battery, value: 13.8)));
      expect(find.text('13.8'), findsOneWidget);
      expect(find.text('V'), findsOneWidget);
    });

    testWidgets('labels a low-voltage alarm', (tester) async {
      await tester.pumpWidget(wrap(const StatTile(spec: battery, value: 10.5)));
      expect(find.text('DANGER'), findsOneWidget);
    });

    testWidgets('handles an unavailable reading', (tester) async {
      await tester.pumpWidget(wrap(const StatTile(spec: battery, value: null)));
      expect(find.text('--'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FlagLamp', () {
    testWidgets('distinguishes on and off by shape as well as colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            children: [
              FlagLamp(label: 'Running', on: true),
              FlagLamp(label: 'Cranking', on: false),
            ],
          ),
        ),
      );

      expect(find.byIcon(Icons.circle), findsOneWidget);
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    });

    testWidgets('treats an unknown flag as off', (tester) async {
      await tester.pumpWidget(wrap(const FlagLamp(label: 'Sync', on: null)));
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    });
  });
}
