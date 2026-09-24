import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/dashboard/stat_tile.dart';
import 'package:foxtune_app/src/dashboard/time_graph.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

// Live data arrives 30 times a second. What each sample is allowed to cost:
// only what shows it, only while it is on screen.

class _Connected extends ConnectionController {
  _Connected(this._state);
  final EcuConnectionState _state;

  @override
  EcuConnectionState build() => _state;
}

/// Counts its builds, and shows the rpm it last saw.
class _Probe extends ConsumerWidget {
  const _Probe(this.builds);
  final List<double?> builds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rpm = watchWhileVisible(ref, context, realtimeProvider).value?['rpm'];
    builds.add(rpm);
    return Text('rpm $rpm');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late Directory storage;

  setUpAll(() async {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(await rootBundle.loadString('assets/speeduino.ini'));
  });

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_live'));
  tearDown(() => storage.deleteSync(recursive: true));

  RealtimeSnapshot sample({int rpm = 0, bool running = false, DateTime? at}) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);
    view.setUint16(channels.channelNamed('rpm')!.offset!, rpm, Endian.little);
    view.setUint8(channels.channelNamed('engine')!.offset!, running ? 1 : 0);
    return RealtimeDecoder(channels).decode(block, timestamp: at);
  }

  EcuConnected connection() => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  group('hidden screens', () {
    testWidgets('follow the feed only while shown', (tester) async {
      final feed = StreamController<RealtimeSnapshot>();
      addTearDown(feed.close);
      final builds = <double?>[];
      var index = 0;
      late StateSetter show;

      final container = ProviderContainer(
        overrides: [realtimeProvider.overrideWith((ref) => feed.stream)],
      );
      addTearDown(container.dispose);
      // As the connected shell keeps the feed running, whatever is shown.
      container.listen(realtimeProvider, (_, _) {});

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                show = setState;
                // As the connected shell holds its tabs.
                return IndexedStack(
                  index: index,
                  children: [_Probe(builds), const SizedBox()],
                );
              },
            ),
          ),
        ),
      );

      feed.add(sample(rpm: 1000));
      await tester.pump();
      expect(builds.last, 1000);

      show(() => index = 1);
      await tester.pump();
      final hiddenAt = builds.length;
      for (final rpm in [2000, 3000, 4000]) {
        feed.add(sample(rpm: rpm));
        await tester.pump();
      }
      expect(builds.length, hiddenAt, reason: 'hidden, it must not rebuild');

      // Shown again, it catches up with the latest sample at once.
      show(() => index = 0);
      await tester.pump();
      expect(builds.last, 4000);
      expect(find.text('rpm 4000.0'), findsOneWidget);

      feed.add(sample(rpm: 5000));
      await tester.pump();
      expect(builds.last, 5000, reason: 'and follows the feed again');
    });
  });

  group('dashboard', () {
    testWidgets('rebuilds a gauge only when what it shows changes', (
      tester,
    ) async {
      File('${storage.path}/dashboards/speeduino.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'version': 3,
            'pages': [
              {
                'id': 'p',
                'name': 'Main',
                'items': [
                  {
                    'id': 'rpm',
                    'style': 'dial',
                    'x': 0,
                    'y': 0,
                    'w': 6,
                    'h': 6,
                    'gauges': ['tachometer'],
                  },
                  {
                    'id': 'lamp',
                    'style': 'lamp',
                    'x': 6,
                    'y': 0,
                    'w': 4,
                    'h': 2,
                    'indicator': 'running',
                  },
                ],
              },
            ],
          }),
        );

      final feed = StreamController<RealtimeSnapshot>();
      addTearDown(feed.close);
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => _Connected(connection())),
            appStorageDirectoryProvider.overrideWith((ref) async => storage),
            realtimeMonitorProvider.overrideWithValue(null),
            realtimeProvider.overrideWith((ref) => feed.stream),
          ],
          child: MaterialApp(
            home: Scaffold(body: DashboardScreen(connection: connection())),
          ),
        ),
      );
      // A sample reaches the gauges a frame after it arrives.
      Future<void> deliver(RealtimeSnapshot sample) async {
        feed.add(sample);
        await tester.pump();
        await tester.pump();
      }

      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await deliver(sample(rpm: 1000, running: true));

      final dial = tester.widget<MeterGauge>(find.byType(MeterGauge));
      final lamp = tester.widget<FlagLamp>(find.byType(FlagLamp));
      expect(dial.value, 1000);
      expect(lamp.on, isTrue);

      // The engine speeds up; it is still running.
      await deliver(sample(rpm: 2500, running: true));
      final faster = tester.widget<MeterGauge>(find.byType(MeterGauge));
      expect(faster.value, 2500);
      expect(
        tester.widget<FlagLamp>(find.byType(FlagLamp)),
        same(lamp),
        reason: 'a lamp whose state held is not rebuilt',
      );

      // The engine stops at the same speed reading: now only the lamp has
      // something new to show.
      await deliver(sample(rpm: 2500, running: false));
      expect(tester.widget<FlagLamp>(find.byType(FlagLamp)).on, isFalse);
      expect(
        tester.widget<MeterGauge>(find.byType(MeterGauge)),
        same(faster),
        reason: 'a dial whose reading held is not rebuilt',
      );
    });
  });

  group('SampleHistory.since', () {
    test('returns exactly the samples at or after the start', () {
      final history = SampleHistory();
      final start = DateTime(2026, 1, 1);
      for (var ms = 0; ms <= 1000; ms += 100) {
        history.add(
          sample(
            rpm: ms,
            at: start.add(Duration(milliseconds: ms)),
          ),
        );
      }

      List<double?> rpmsSince(int ms) => [
        for (final s in history.since(start.add(Duration(milliseconds: ms))))
          s['rpm'],
      ];

      expect(rpmsSince(-50), hasLength(11), reason: 'before the oldest');
      expect(rpmsSince(0), hasLength(11), reason: 'on the oldest');
      expect(rpmsSince(450), [500, 600, 700, 800, 900, 1000]);
      expect(rpmsSince(500), [500, 600, 700, 800, 900, 1000]);
      expect(rpmsSince(1000), [1000]);
      expect(rpmsSince(1001), isEmpty, reason: 'after the newest');
      expect(SampleHistory().since(start), isEmpty);
    });
  });

  group('decimate', () {
    // A trace with far more points than the lane has pixels.
    List<Offset?> wave(int count, {double Function(int i)? y}) => [
      for (var i = 0; i < count; i++)
        Offset(i / (count - 1), y?.call(i) ?? 0.5 + 0.4 * (i.isEven ? 1 : -1)),
    ];

    test('leaves a trace alone when it already fits', () {
      final points = wave(20);
      expect(decimate(points, 100), same(points));
    });

    test('keeps at most two points per column', () {
      final thinned = decimate(wave(1800), 300);
      expect(thinned.length, lessThanOrEqualTo(600));

      final perColumn = <int, int>{};
      for (final p in thinned.whereType<Offset>()) {
        final column = (p.dx * 300).floor().clamp(0, 299);
        perColumn[column] = (perColumn[column] ?? 0) + 1;
      }
      expect(perColumn.values.every((n) => n <= 2), isTrue);
    });

    test('keeps a spike one sample wide', () {
      // Flat, but for one sample at the very top of the lane.
      final points = wave(1800, y: (i) => i == 901 ? 0.0 : 0.8);
      final thinned = decimate(points, 300).whereType<Offset>();
      expect(thinned.map((p) => p.dy), contains(0.0));
      expect(thinned.map((p) => p.dy).reduce((a, b) => a > b ? a : b), 0.8);
    });

    test('keeps a gap a gap', () {
      // Two runs of readings, with a stretch the ECU did not send between.
      final points = <Offset?>[
        for (var i = 0; i < 900; i++) Offset(i / 1800, 0.5),
        null,
        null,
        for (var i = 900; i < 1800; i++) Offset(i / 1800, 0.3),
      ];
      final thinned = decimate(points, 100);
      expect(thinned.where((p) => p == null), hasLength(1));
      final gap = thinned.indexOf(null);
      expect(thinned.take(gap).every((p) => p!.dy == 0.5), isTrue);
      expect(thinned.skip(gap + 1).every((p) => p!.dy == 0.3), isTrue);
    });
  });
}
