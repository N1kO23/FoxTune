import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/dashboard/time_graph.dart';
import 'package:foxtune_app/src/motion/motion.dart';
import 'package:foxtune_app/src/motion/readout_text.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

final _definition = IniParser().parse('''
[OutputChannels]
ochBlockSize = 2
value = scalar, U16, 0, "", 1.000, 0.000
''');
final _decoder = RealtimeDecoder(_definition.outputChannels);
final _start = DateTime(2026);

/// A sample reading [value], taken [ms] after the start.
RealtimeSnapshot _sample(int ms, [int value = 0]) {
  final block = Uint8List(2);
  ByteData.sublistView(block).setUint16(0, value, Endian.little);
  return _decoder.decode(
    block,
    timestamp: _start.add(Duration(milliseconds: ms)),
  );
}

void main() {
  group('the live feed for widgets', () {
    late StreamController<RealtimeSnapshot> feed;
    setUp(() => feed = StreamController<RealtimeSnapshot>.broadcast());
    tearDown(() => feed.close());

    /// A widget watching [provider], counting its builds and keeping the
    /// sample it last saw.
    Future<(List<RealtimeSnapshot?>,)> pumpWatcher(
      WidgetTester tester,
      ProviderListenable<RealtimeSnapshot?> provider,
    ) async {
      final seen = <RealtimeSnapshot?>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [realtimeProvider.overrideWith((ref) => feed.stream)],
          child: Consumer(
            builder: (context, ref, _) {
              seen.add(ref.watch(provider));
              return const SizedBox();
            },
          ),
        ),
      );
      return (seen,);
    }

    testWidgets('hands over the newest sample once a frame', (tester) async {
      final (seen,) = await pumpWatcher(tester, liveProvider);
      expect(seen, [null]);

      // A burst between two frames: one rebuild, with the last of it.
      for (var i = 0; i < 5; i++) {
        feed.add(_sample(i * 5, i));
      }
      await tester.idle();
      expect(seen, hasLength(1), reason: 'nothing until the frame');
      await tester.pump();
      expect(seen, hasLength(2));
      expect(seen.last!['value'], 4);

      // No samples, no frames asked for.
      await tester.pump();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(seen, hasLength(2));
    });

    testWidgets('calmly: at once, then at most every 100 ms', (tester) async {
      final (seen,) = await pumpWatcher(tester, calmLiveProvider);

      feed.add(_sample(0, 1));
      await tester.idle();
      await tester.pump();
      expect(seen.last!['value'], 1, reason: 'the first at once');

      feed.add(_sample(5, 2));
      feed.add(_sample(10, 3));
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 50));
      expect(seen.last!['value'], 1, reason: 'held back');

      await tester.pump(const Duration(milliseconds: 60));
      expect(seen.last!['value'], 3, reason: 'then the newest');
    });
  });

  group('the table grid', () {
    testWidgets('moves its marker without rebuilding its cells', (
      tester,
    ) async {
      final doc = IniParser().parse('''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 16
page = 1
  zTable = array, U08, 0, [2x3], "%",   1.0, 0.0, 0.0, 255.0, 0
  xAxis  = array, U08, 6, [3],   "RPM", 1.0, 0.0, 0.0, 255.0, 0
  yAxis  = array, U08, 9, [2],   "kPa", 1.0, 0.0, 0.0, 255.0, 0
[TableEditor]
  table = t, tMap, "Table", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''');
      final tune = TuneState.empty(doc);
      final z = tune.locate('zTable')!;
      final x = tune.locate('xAxis')!;
      final y = tune.locate('yAxis')!;
      for (final (i, value) in [11, 12, 13, 21, 22, 23].indexed) {
        tune.writeRaw(z.page, z.field, value, i);
      }
      for (var i = 0; i < 3; i++) {
        tune.writeRaw(x.page, x.field, 10 * (i + 1), i);
      }
      for (var i = 0; i < 2; i++) {
        tune.writeRaw(y.page, y.field, 10 * (i + 1), i);
      }
      final view = TableView.of(tune, doc.tables.single)!;
      final precise = ValueNotifier<({double row, double column})?>((
        row: 0.2,
        column: 0.2,
      ));
      addTearDown(precise.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [Motion(liveData: true)]),
          home: Scaffold(
            body: TableGrid(
              view: view,
              selection: const CellSelection.single(0, 0),
              cursor: (row: 0, column: 0),
              preciseCursor: precise,
              onSelectionChanged: (_) {},
              onEdit: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cell = tester.widget(find.text('12'));

      precise.value = (row: 0.4, column: 0.6);
      await tester.pumpAndSettle();
      expect(
        identical(tester.widget(find.text('12')), cell),
        isTrue,
        reason: 'the cells were built again',
      );
    });
  });

  group('calm readouts', () {
    Widget readout(String text, {bool calm = true}) => MaterialApp(
      theme: ThemeData(extensions: [Motion(calmReadouts: calm)]),
      home: ReadoutText(text),
    );

    testWidgets('change at once after a quiet spell, then once a tick', (
      tester,
    ) async {
      await tester.pumpWidget(readout('100'));
      await tester.pump(ReadoutClock.period);

      await tester.pumpWidget(readout('101'));
      expect(find.text('101'), findsOneWidget, reason: 'after a quiet spell');

      await tester.pumpWidget(readout('102'));
      await tester.pumpWidget(readout('103'));
      expect(find.text('101'), findsOneWidget, reason: 'held to the tick');

      await tester.pump(ReadoutClock.period);
      expect(find.text('103'), findsOneWidget, reason: 'the newest on it');
    });

    testWidgets('follow every reading when off', (tester) async {
      await tester.pumpWidget(readout('100', calm: false));
      await tester.pumpWidget(readout('101', calm: false));
      await tester.pumpWidget(readout('102', calm: false));
      expect(find.text('102'), findsOneWidget);
      expect(ReadoutClock.instance.running, isFalse);
    });

    testWidgets('keep one clock, running only while needed', (tester) async {
      await tester.pumpWidget(readout('100'));
      expect(ReadoutClock.instance.running, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(ReadoutClock.instance.running, isFalse);
    });
  });

  group('graph history', () {
    test('keeps at most fifty samples a second for the dashboard', () {
      final history = SampleHistory.forDashboard();
      for (var ms = 0; ms < 1000; ms += 5) {
        history.add(_sample(ms));
      }
      expect(history.length, 50);
    });

    test("keeps a channel's column in step with its samples", () {
      final history = SampleHistory(span: const Duration(seconds: 1));
      final column = history.column('value');
      for (var ms = 0; ms < 3000; ms += 10) {
        history.add(_sample(ms, ms ~/ 10));
      }
      expect(column.length, history.length);
      for (var i = 0; i < column.length; i++) {
        final sample = history.samples.elementAt(i);
        expect(column.valueAt(i), sample['value']);
        expect(
          column.timeAt(i),
          sample.timestamp.microsecondsSinceEpoch.toDouble(),
        );
      }

      // Asked for later, a column starts from what is already held.
      expect(history.column('value'), same(column));
      history.clear();
      expect(column.length, 0);
    });

    test('a lane draws what thinning its every reading would', () {
      final history = SampleHistory();
      for (var ms = 0; ms < 60000; ms += 5) {
        // A wave, with a gap now and then.
        history.add(
          ms % 7000 < 40
              ? _decoder.decode(
                  Uint8List(0),
                  timestamp: _start.add(Duration(milliseconds: ms)),
                )
              : _sample(ms, 500 + (ms ~/ 37) % 300),
        );
      }
      for (final hasRange in [true, false]) {
        for (final edge in [null, _start.add(const Duration(seconds: 50))]) {
          final at = ValueNotifier<DateTime?>(edge);
          addTearDown(at.dispose);
          final painter = LanePainter(
            spec: GaugeSpec(
              channel: 'value',
              label: 'Value',
              units: '',
              min: 0,
              max: 1000,
              hasRange: hasRange,
            ),
            history: history,
            window: const Duration(seconds: 30),
            edge: at,
            line: Colors.blue,
            grid: Colors.grey,
            label: Colors.black,
          );
          const size = Size(240, 60);
          expect(
            painter.pointsDrawn(size),
            decimate(painter.points(), size.width.ceil()),
            reason: 'range: $hasRange, edge: $edge',
          );
          expect(painter.points().whereType<Offset>(), isNotEmpty);
        }
      }
    });
  });
}
