import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/dashboard/bar_gauge.dart';
import 'package:foxtune_app/src/dashboard/gauge_appearance.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/dashboard/stat_tile.dart';
import 'package:foxtune_app/src/dashboard/time_graph.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

Widget wrap(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brandTheme(brightness),
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

    // The dashboard lays a dial out at its design size: 154 across for a new
    // one, 114 for the smallest it can be resized to.
    for (final side in [154.0, 114.0]) {
      testWidgets('keeps its text inside the arc at $side across', (
        tester,
      ) async {
        const long = GaugeSpec(
          channel: 'warmupEnrich',
          label: 'Warmup Enrichment',
          units: '%',
          min: 100,
          max: 200,
          warnAbove: 150,
          dangerAbove: 170,
        );
        await tester.pumpWidget(
          wrap(
            SizedBox.square(
              dimension: side,
              child: const MeterGauge(spec: long, value: 185),
            ),
          ),
        );

        final dial = find.byType(MeterGauge);
        final centre = tester.getCenter(dial);
        // The inner edge of the track, as the painter draws it.
        final stroke = side * 0.085;
        final inner = (side - stroke) / 2 - 2 - stroke / 2;

        final marks = find.descendant(
          of: dial,
          // An icon draws its glyph as text too, so this catches the badge's.
          matching: find.byType(RichText),
        );
        // Title, value, units, and the badge's icon and word.
        expect(marks, findsNWidgets(5));
        for (final element in marks.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          for (final corner in [
            rect.topLeft,
            rect.topRight,
            rect.bottomLeft,
            rect.bottomRight,
          ]) {
            expect(
              (corner - centre).distance,
              lessThanOrEqualTo(inner),
              reason: '${element.widget} reaches the arc at $corner',
            );
          }
        }
      });
    }

    testWidgets('sets its text in the dashboard\'s sizes', (tester) async {
      await tester.pumpWidget(
        wrap(
          const SizedBox.square(
            dimension: 154,
            child: MeterGauge(spec: rpm, value: 3500),
          ),
        ),
      );
      final theme = Theme.of(tester.element(find.byType(MeterGauge)));
      // Captions like a lamp's label, the value like a digital readout's.
      expect(
        tester.widget<Text>(find.text('RPM')).style?.fontSize,
        theme.textTheme.labelSmall?.fontSize,
      );
      expect(
        tester.widget<Text>(find.text('3500')).style?.fontSize,
        theme.textTheme.titleLarge?.fontSize,
      );
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

  group('looks', () {
    const warm = GaugeSpec(
      channel: 'coolant',
      label: 'Coolant',
      units: '°C',
      min: -40,
      max: 120,
      warnBelow: 20,
      dangerBelow: 0,
      warnAbove: 95,
      dangerAbove: 105,
    );

    // Every corner of every piece of text on the dial, as far from its
    // centre as it reaches.
    void expectTextInside(WidgetTester tester, DialLook look) {
      final dial = find.byType(MeterGauge);
      final box = tester.getRect(dial);
      final room = MeterGauge.textRoom(box.size, look);
      final centre = box.topLeft + room.centre;
      final inner = room.clear;
      final marks = find.descendant(of: dial, matching: find.byType(RichText));
      expect(marks, findsWidgets);
      for (final element in marks.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        for (final corner in [
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
        ]) {
          expect(
            (corner - centre).distance,
            lessThanOrEqualTo(inner + 0.01),
            reason: '${element.widget} reaches the scale at $corner',
          );
        }
      }
    }

    for (final face in DialFace.values) {
      for (final sweep in dialSweeps) {
        for (final scale in ScaleMarks.values) {
          final dial = DialLook(
            face: face,
            sweep: sweep,
            scale: scale,
            alarms: AlarmMarks.bands,
          );
          testWidgets('a ${face.name} dial, $sweep°, ${scale.name} marked, '
              'keeps its text clear and its alarm in words', (tester) async {
            for (final brightness in Brightness.values) {
              await tester.pumpWidget(
                wrap(
                  SizedBox.square(
                    dimension: 154,
                    child: MeterGauge(
                      spec: warm,
                      value: 110,
                      look: GaugeAppearance(dial: dial),
                    ),
                  ),
                  brightness: brightness,
                ),
              );
              expect(tester.takeException(), isNull);
              expect(find.text('DANGER'), findsOneWidget);
              expect(find.byIcon(Icons.error_rounded), findsOneWidget);
              expectTextInside(tester, dial);
            }
          });
        }
      }
    }

    testWidgets('a needle in alarm draws its whole scale in the alarm '
        'colour', (tester) async {
      const look = GaugeAppearance(dial: DialLook(face: DialFace.needle));
      final scheme = brandTheme(Brightness.light).colorScheme;

      /// The colour at the top of the scale: the middle of a 270° sweep,
      /// clear of the needle and of any alarm mark.
      Future<Color> topOfScale(double value) async {
        final key = GlobalKey();
        await tester.pumpWidget(
          wrap(
            Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox.square(
                  dimension: 154,
                  child: MeterGauge(spec: warm, value: value, look: look),
                ),
              ),
            ),
          ),
        );
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final pixels = (await image.toByteData())!;
          image.dispose();
          // The track runs along the top edge, a few pixels down.
          final at = (3 * image.width + image.width ~/ 2) * 4;
          return Color.fromARGB(
            pixels.getUint8(at + 3),
            pixels.getUint8(at),
            pixels.getUint8(at + 1),
            pixels.getUint8(at + 2),
          );
        }))!;
      }

      void expectNear(Color actual, Color expected) {
        for (final (a, e) in [
          (actual.r, expected.r),
          (actual.g, expected.g),
          (actual.b, expected.b),
        ]) {
          expect(a, closeTo(e, 0.04), reason: '$actual is not $expected');
        }
      }

      expectNear(await topOfScale(110), StatusPalette.critical);
      expectNear(await topOfScale(100), StatusPalette.warning);
      expectNear(await topOfScale(80), scheme.outline);
    });

    testWidgets('a needle with no reading shows no reading', (tester) async {
      await tester.pumpWidget(
        wrap(
          const MeterGauge(
            spec: warm,
            value: null,
            look: GaugeAppearance(dial: DialLook(face: DialFace.needle)),
          ),
        ),
      );
      expect(find.text('--'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('alarms wear the colours chosen for them, and still their '
        'words', (tester) async {
      const purple = Color(0xFF8E24AA);
      const blue = Color(0xFF1E88E5);
      const look = GaugeAppearance(
        colours: GaugeColours(warning: blue, danger: purple),
      );
      await tester.pumpWidget(
        wrap(const MeterGauge(spec: warm, value: 110, look: look)),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.error_rounded)).color,
        purple,
      );
      expect(find.text('DANGER'), findsOneWidget);

      await tester.pumpWidget(
        wrap(const MeterGauge(spec: warm, value: 100, look: look)),
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded)).color,
        blue,
      );
      expect(find.text('WARN'), findsOneWidget);
    });

    testWidgets('the value is set in the colour chosen for text', (
      tester,
    ) async {
      const text = Color(0xFF00897B);
      await tester.pumpWidget(
        wrap(
          const MeterGauge(
            spec: warm,
            value: 80,
            look: GaugeAppearance(colours: GaugeColours(text: text)),
          ),
        ),
      );
      expect(tester.widget<Text>(find.text('80')).style?.color, text);
    });

    group('bar', () {
      bool drawnUpright(WidgetTester tester) => tester
          .widgetList<CustomPaint>(
            find.descendant(
              of: find.byType(BarGauge),
              matching: find.byType(CustomPaint),
            ),
          )
          .map((paint) => paint.painter)
          .whereType<BarPainter>()
          .single
          .vertical;

      for (final orientation in BarOrientation.values) {
        for (final (width, height) in [(160.0, 40.0), (40.0, 160.0)]) {
          testWidgets('runs ${orientation.name} in a ${width}x$height space', (
            tester,
          ) async {
            await tester.pumpWidget(
              wrap(
                // Centred, so the space is the size given it.
                Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: BarGauge(
                      spec: warm,
                      value: 110,
                      look: GaugeAppearance(
                        bar: BarLook(
                          orientation: orientation,
                          segmented: true,
                          alarms: AlarmMarks.bands,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            expect(tester.takeException(), isNull);
            expect(drawnUpright(tester), switch (orientation) {
              BarOrientation.auto => height > width,
              BarOrientation.horizontal => false,
              BarOrientation.vertical => true,
            });
            expect(find.text('DANGER'), findsOneWidget);
          });
        }
      }

      test('paints every way it can be drawn', () {
        for (final segmented in [false, true]) {
          for (final alarms in AlarmMarks.values) {
            for (final vertical in [false, true]) {
              final recorder = ui.PictureRecorder();
              BarPainter(
                fraction: 0.7,
                vertical: vertical,
                fill: Colors.orange,
                hasValue: true,
                segmented: segmented,
                alarms: alarms,
                ranges: const [(0.8, 1, Colors.red), (0, 0.1, Colors.amber)],
              ).paint(Canvas(recorder), const Size(160, 12));
              recorder.endRecording().dispose();
            }
          }
        }
      });
    });

    group('readout', () {
      const battery = GaugeSpec(
        channel: 'batteryVoltage',
        label: 'Battery',
        units: 'V',
        min: 8,
        max: 16,
        decimals: 1,
        warnBelow: 12,
        dangerBelow: 11,
      );

      testWidgets('without its card or bar still words its alarm', (
        tester,
      ) async {
        await tester.pumpWidget(
          wrap(
            const StatTile(
              spec: battery,
              value: 10.5,
              look: GaugeAppearance(
                readout: ReadoutLook(framed: false, magnitudeBar: false),
              ),
            ),
          ),
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('DANGER'), findsOneWidget);
        expect(find.byIcon(Icons.error_rounded), findsOneWidget);
      });

      testWidgets('sets a large number larger', (tester) async {
        await tester.pumpWidget(
          wrap(
            const StatTile(
              spec: battery,
              value: 13.8,
              look: GaugeAppearance(
                readout: ReadoutLook(valueSize: ValueSize.large),
              ),
            ),
          ),
        );
        final theme = Theme.of(tester.element(find.byType(StatTile)));
        expect(
          tester.widget<Text>(find.text('13.8')).style?.fontSize,
          theme.textTheme.headlineMedium?.fontSize,
        );
      });
    });

    group('lamp', () {
      for (final shape in LampShape.values) {
        testWidgets('a ${shape.name} lamp still tells on from off by shape', (
          tester,
        ) async {
          final look = GaugeAppearance(lamp: LampLook(shape: shape));
          await tester.pumpWidget(
            wrap(
              Column(
                children: [
                  FlagLamp(label: 'Running', on: true, look: look),
                  FlagLamp(label: 'Cranking', on: false, look: look),
                ],
              ),
            ),
          );
          expect(find.byIcon(Icons.circle), findsOneWidget);
          expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('lights in the colour chosen over the definition\'s', (
        tester,
      ) async {
        const blue = Color(0xFF1E88E5);
        await tester.pumpWidget(
          wrap(
            const FlagLamp(
              label: 'Running',
              on: true,
              onColor: Colors.red,
              look: GaugeAppearance(lamp: LampLook(onColour: blue)),
            ),
          ),
        );
        expect(tester.widget<Icon>(find.byIcon(Icons.circle)).color, blue);
      });
    });

    group('graph', () {
      final definition = IniParser().parse('''
[OutputChannels]
ochBlockSize = 2
value = scalar, U16, 0, "", 1.000, 0.000
''');

      SampleHistory history() {
        final samples = SampleHistory();
        final decoder = RealtimeDecoder(definition.outputChannels);
        final start = DateTime(2026);
        for (var i = 0; i < 100; i++) {
          final block = Uint8List(2);
          ByteData.sublistView(block)
              .setUint16(0, 50 + (i % 40) * 2, Endian.little);
          samples.add(
            decoder.decode(
              block,
              timestamp: start.add(Duration(milliseconds: i * 100)),
            ),
          );
        }
        return samples;
      }

      test('paints its trace, shading and alarm marks', () {
        const spec = GaugeSpec(
          channel: 'value',
          label: 'Value',
          units: '',
          min: 0,
          max: 200,
          warnAbove: 100,
          dangerAbove: 120,
        );
        for (final fill in [false, true]) {
          for (final alarms in AlarmMarks.values) {
            final recorder = ui.PictureRecorder();
            final painter = LanePainter(
              spec: spec,
              history: history(),
              window: const Duration(seconds: 10),
              line: Colors.blue,
              grid: Colors.grey,
              label: Colors.black,
              lineWidth: 3.5,
              fill: fill,
              alarms: alarms,
              ranges: alarmRanges(spec, const GaugeColours()),
            );
            painter.paint(Canvas(recorder), const Size(240, 60));
            recorder.endRecording().dispose();
            expect(painter.points().whereType<Offset>(), isNotEmpty);
          }
        }
      });

      test('repaints when its look changes', () {
        final samples = history();
        LanePainter lane({bool fill = false, double lineWidth = 2}) =>
            LanePainter(
              spec: const GaugeSpec(
                channel: 'value',
                label: 'Value',
                units: '',
                min: 0,
                max: 200,
              ),
              history: samples,
              window: const Duration(seconds: 10),
              line: Colors.blue,
              grid: Colors.grey,
              label: Colors.black,
              fill: fill,
              lineWidth: lineWidth,
            );
        expect(lane().shouldRepaint(lane()), isFalse);
        expect(lane(fill: true).shouldRepaint(lane()), isTrue);
        expect(lane(lineWidth: 1).shouldRepaint(lane()), isTrue);
      });
    });
  });

  group('scale', () {
    test('steps round numbers across the range', () {
      expect(scaleDivisions(0, 8000).majors, [0, 2000, 4000, 6000, 8000]);
      expect(scaleDivisions(-40, 120).majors, [-40, 0, 40, 80, 120]);
      expect(scaleDivisions(0, 1).majors, [0, 0.2, 0.4, 0.6, 0.8, 1]);
    });

    test('puts minor steps between the majors', () {
      final (:majors, :minors) = scaleDivisions(0, 100);
      expect(majors, [0, 20, 40, 60, 80, 100]);
      expect(minors.take(4), [5, 10, 15, 25]);
    });

    test('has nothing to mark on a range that is not one', () {
      expect(scaleDivisions(5, 5).majors, isEmpty);
      expect(scaleDivisions(double.nan, 5).majors, isEmpty);
    });
  });
}
