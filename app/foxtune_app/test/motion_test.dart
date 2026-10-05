import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/grid_wallpaper.dart';
import 'package:foxtune_app/src/app_settings/motion_settings.dart';
import 'package:foxtune_app/src/dashboard/bar_gauge.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/dashboard/time_graph.dart';
import 'package:foxtune_app/src/motion/demo_drive.dart';
import 'package:foxtune_app/src/motion/gliding_value.dart';
import 'package:foxtune_app/src/motion/motion.dart';
import 'package:foxtune_app/src/motion/transitions.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

const _lively = Motion(
  liveData: true,
  transitions: true,
  glow: true,
  drift: true,
  glide: Duration(milliseconds: 100),
);

/// [child] in an app whose theme carries [motion].
Widget _app(Widget child, {Motion motion = _lively, bool reduced = false}) =>
    MaterialApp(
      theme: ThemeData(extensions: [motion]),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Material(child: child),
      ),
    );

void main() {
  group('MotionSettings', () {
    test('are all on unless turned off', () {
      const motion = MotionSettings();
      expect(motion.liveData && motion.transitions && motion.glow, isTrue);
      expect(MotionSettings.fromJson(null), motion);
    });

    test('read back what they write, and keep a default for a bad switch', () {
      const settings = MotionSettings(liveData: false, glow: false);
      expect(MotionSettings.fromJson(settings.toJson()), settings);
      expect(
        MotionSettings.fromJson({'liveData': 'yes', 'transitions': false}),
        const MotionSettings(transitions: false),
      );
    });
  });

  group('Motion', () {
    testWidgets('is still where the theme carries none', (tester) async {
      late Motion seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = Motion.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, Motion.still);
    });

    testWidgets('keeps the glow, but nothing moving, where the system asks '
        'for reduced motion', (tester) async {
      late Motion seen;
      await tester.pumpWidget(
        _app(
          reduced: true,
          Builder(
            builder: (context) {
              seen = Motion.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen.liveData, isFalse);
      expect(seen.transitions, isFalse);
      expect(seen.drift, isFalse);
      expect(seen.glow, isTrue);
    });

    test('glides a little longer than the time between readings', () {
      // 10 a second: just over the gap, so the next reading lands mid-glide.
      expect(
        Motion.glideFor(const Duration(milliseconds: 100)),
        const Duration(milliseconds: 125),
      );
      // Never so short it is a jump, nor so long it lags a slow link far.
      expect(
        Motion.glideFor(const Duration(milliseconds: 20)),
        const Duration(milliseconds: 60),
      );
      expect(
        Motion.glideFor(const Duration(seconds: 1)),
        const Duration(milliseconds: 250),
      );
    });

    test('decides how screens come and go, and whether buttons glow', () {
      final base = ThemeData();
      final lively = applyMotion(base, _lively);
      expect(lively.extension<Motion>(), _lively);
      expect(
        lively.pageTransitionsTheme.builders[TargetPlatform.linux],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
      expect(lively.filledButtonTheme.style, isNotNull);

      final still = applyMotion(base, Motion.still);
      expect(
        still
            .pageTransitionsTheme
            .builders[TargetPlatform.android]!
            .transitionDuration,
        Duration.zero,
      );
      expect(still.filledButtonTheme.style, isNull);
    });
  });

  group('GlidingValue', () {
    Widget gliding(double value, List<double> seen, {Motion? motion}) => _app(
      motion: motion ?? _lively,
      GlidingValue<double>(
        value: value,
        builder: (context, shown, _) {
          seen.add(shown);
          return const SizedBox();
        },
      ),
    );

    testWidgets('glides to a new value over the glide', (tester) async {
      final seen = <double>[];
      await tester.pumpWidget(gliding(0, seen));
      await tester.pumpWidget(gliding(1, seen));
      await tester.pump(const Duration(milliseconds: 50));
      expect(seen.last, greaterThan(0));
      expect(seen.last, lessThan(1));

      await tester.pump(const Duration(milliseconds: 60));
      expect(seen.last, 1);
    });

    testWidgets('jumps to it with live data motion off', (tester) async {
      final seen = <double>[];
      await tester.pumpWidget(gliding(0, seen, motion: Motion.still));
      await tester.pumpWidget(gliding(1, seen, motion: Motion.still));
      expect(seen.last, 1);
    });

    testWidgets('carries the dial and the bar', (tester) async {
      const spec = GaugeSpec(
        channel: 'rpm',
        label: 'RPM',
        units: 'rpm',
        min: 0,
        max: 8000,
      );
      await tester.pumpWidget(
        _app(
          const Row(
            children: [
              Expanded(child: MeterGauge(spec: spec, value: 3000)),
              Expanded(child: BarGauge(spec: spec, value: 3000)),
            ],
          ),
        ),
      );
      expect(find.byType(GlidingValue<double>), findsNWidgets(2));
      // The number is the reading, never the glide.
      expect(find.text('3000'), findsNWidgets(2));
    });
  });

  group('FadeIndexedStack', () {
    Widget stack(int index, {Motion motion = _lively}) => _app(
      motion: motion,
      FadeIndexedStack(
        index: index,
        children: const [
          _Counter(key: Key('a')),
          _Counter(key: Key('b')),
        ],
      ),
    );

    double opacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
          find
              .ancestor(
                of: find.byType(IndexedStack),
                matching: find.byType(FadeTransition),
              )
              .first,
        )
        .opacity
        .value;

    testWidgets('fades the child it switches to in, and keeps each child', (
      tester,
    ) async {
      await tester.pumpWidget(stack(0));
      await tester.tap(find.byKey(const Key('a')));
      await tester.pump();
      expect(opacity(tester), 1);

      await tester.pumpWidget(stack(1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(tester), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);

      await tester.pumpWidget(stack(0));
      await tester.pumpAndSettle();
      // Still counted once: switching away did not start it over.
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('switches at once with transitions off', (tester) async {
      await tester.pumpWidget(stack(0, motion: Motion.still));
      await tester.pumpWidget(stack(1, motion: Motion.still));
      await tester.pump();
      expect(opacity(tester), 1);
    });
  });

  group('StaggeredEntrance', () {
    Widget page({Motion motion = _lively, int count = 3}) => _app(
      motion: motion,
      StaggeredEntrance(
        child: Column(
          children: [
            for (var i = 0; i < count; i++)
              EntranceItem(index: i, child: Text('gauge $i')),
          ],
        ),
      ),
    );

    List<double> opacities(WidgetTester tester) => [
      for (final fade in tester.widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(StaggeredEntrance),
          matching: find.byType(FadeTransition),
        ),
      ))
        fade.opacity.value,
    ];

    testWidgets('brings each item in after the one before', (tester) async {
      await tester.pumpWidget(page());
      expect(opacities(tester), everyElement(0));

      await tester.pump(const Duration(milliseconds: 100));
      final partway = opacities(tester);
      expect(partway[0], greaterThan(partway[2]));

      await tester.pumpAndSettle();
      expect(opacities(tester), everyElement(1));

      // Once: built again, it does not come in again.
      await tester.pumpWidget(page());
      expect(opacities(tester), everyElement(1));
    });

    testWidgets('shows everything at once with transitions off', (
      tester,
    ) async {
      await tester.pumpWidget(page(motion: Motion.still));
      expect(opacities(tester), everyElement(1));
    });
  });

  group('LiveEdge', () {
    final definition = IniParser().parse('''
[OutputChannels]
ochBlockSize = 2
value = scalar, U16, 0, "", 1.000, 0.000
''');
    final decoder = RealtimeDecoder(definition.outputChannels);
    final start = DateTime(2026);
    RealtimeSnapshot sample(int ms) => decoder.decode(
      Uint8List(2),
      timestamp: start.add(Duration(milliseconds: ms)),
    );

    testWidgets('scrolls on between samples, and stops when they do', (
      tester,
    ) async {
      final history = SampleHistory();
      var now = DateTime(2030);
      DateTime? edge;
      await tester.pumpWidget(
        _app(
          LiveEdge(
            history: history,
            clock: () => now,
            builder: (context, listenable) => ValueListenableBuilder(
              valueListenable: listenable,
              builder: (context, value, _) {
                edge = value;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(edge, isNull);

      // Samples 100 ms apart, each arriving as it is taken.
      for (var ms = 0; ms <= 1000; ms += 100) {
        history.add(sample(ms));
        await tester.pump();
      }
      final arrived = edge!;

      // Half way to the next: the window has moved on half a sample.
      now = now.add(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 16));
      expect(edge!.isAfter(arrived), isTrue);

      // The next is late: the window holds at the newest sample.
      now = now.add(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 16));
      final held = edge;
      expect(held, start.add(const Duration(milliseconds: 1000)));

      // None come: it stops, and stays where it was.
      now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(edge, held);

      // One comes: it scrolls again.
      history.add(sample(1100));
      await tester.pump();
      now = now.add(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 16));
      expect(edge!.isAfter(held!), isTrue);
    });

    test('the trace runs to the edge of a window scrolled on', () {
      final history = SampleHistory();
      for (var ms = 0; ms <= 2000; ms += 100) {
        history.add(sample(ms));
      }
      final edge = ValueNotifier<DateTime?>(
        start.add(const Duration(milliseconds: 1950)),
      );
      final painter = LanePainter(
        spec: const GaugeSpec(
          channel: 'value',
          label: 'Value',
          units: '',
          min: 0,
          max: 10,
        ),
        history: history,
        window: const Duration(seconds: 1),
        edge: edge,
        line: Colors.blue,
        grid: Colors.grey,
        label: Colors.black,
      );
      final xs = [for (final p in painter.points()) p!.dx];
      // One sample past the edge, for the trace to run off to; no more.
      expect(xs.where((x) => x > 1), hasLength(1));
      expect(xs.first, greaterThanOrEqualTo(0));

      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), const Size(200, 40));
      recorder.endRecording().dispose();
      edge.dispose();
    });
  });

  group('GridWallpaper', () {
    testWidgets('drifts only with glow on and nothing over it', (tester) async {
      bool drifting() =>
          tester.state<GridWallpaperState>(find.byType(GridWallpaper)).drifting;
      Widget wallpaper({bool covered = false}) => _app(
        TickerMode(
          enabled: !covered,
          child: const GridWallpaper(strength: 0.15),
        ),
      );

      await tester.pumpWidget(wallpaper());
      expect(drifting(), isTrue);
      await tester.pump(GridWallpaper.driftStep * 3);

      // Covered by another screen, it stops - and starts again uncovered.
      await tester.pumpWidget(wallpaper(covered: true));
      expect(drifting(), isFalse);
      await tester.pumpWidget(wallpaper());
      expect(drifting(), isTrue);
    });

    testWidgets('holds still with glow off', (tester) async {
      await tester.pumpWidget(
        _app(motion: Motion.still, const GridWallpaper(strength: 0.15)),
      );
      expect(
        tester.state<GridWallpaperState>(find.byType(GridWallpaper)).drifting,
        isFalse,
      );
    });
  });

  test("the demo drive idles, pulls to redline and cuts fuel on the "
      'overrun', () {
    expect(demoDriveAt(1).rpm, closeTo(860, 40));
    expect(demoDriveAt(6).rpm, greaterThan(6000));
    expect(demoDriveAt(7).dfco, isTrue);
    expect(demoDriveAt(1).dfco, isFalse);
    // And round again.
    expect(
      demoDriveAt(1 + demoDriveLength).rpm,
      closeTo(demoDriveAt(1).rpm, 30),
    );
  });
}

/// Counts its taps: state to lose, were it built afresh.
class _Counter extends StatefulWidget {
  const _Counter({super.key});

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  var _count = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => _count++),
    child: Text('$_count'),
  );
}
