// Frame times of the live dashboard, on a real device in profile mode:
//
//   flutter drive --profile -d linux \
//     --driver=test_driver/perf_driver.dart \
//     --target=integration_test/dashboard_perf_test.dart
//
// The summary lands in build/integration_response_data.json. It draws a real
// user's layout (fixtures/speeduino_dashboard.dart) from a synthetic 30 Hz
// feed, with the whole connected shell up - the other tabs included, since
// what they do while hidden is part of what the dashboard costs.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/main.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/sample_history.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:integration_test/integration_test.dart';

import 'fixtures/speeduino_dashboard.dart';

/// How long each measurement runs.
const _measured = Duration(seconds: 15);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Draw every frame the app asks for, as it would outside a test.
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('dashboard frame times', (tester) async {
    final doc = IniParser(defined: {'CELSIUS'})
        .parse(await rootBundle.loadString('assets/speeduino.ini'));

    final storage = Directory.systemTemp.createTempSync('foxtune_perf');
    addTearDown(() => storage.deleteSync(recursive: true));
    File('${storage.path}/FoxTune/dashboards/speeduino.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(speeduinoDashboard);

    final feed = _SyntheticFeed(doc);
    final connected = EcuConnected(
      port: const EcuPort(address: '/dev/ttyACM0'),
      identification: EcuIdentification(
        signature: doc.identity.signature!,
        version: 'Speeduino benchmark',
      ),
      signatureStatus: SignatureStatus.matched,
      expectedSignature: doc.identity.signature,
      definition: doc,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _Connected(connected)),
          tuneProvider.overrideWith(() => _FixedTune(TuneState.empty(doc))),
          screenWakeProvider.overrideWithValue(_NoWake()),
          appStorageDirectoryProvider.overrideWith(
            (ref) async => Directory('${storage.path}/FoxTune'),
          ),
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith((ref) => feed.live()),
          // Graphs at their worst: the full two minutes of history already
          // held, as after a while connected.
          sampleHistoryProvider.overrideWith((ref) {
            final history = SampleHistory();
            feed.backfill(history.span).forEach(history.add);
            ref.listen<AsyncValue<RealtimeSnapshot>>(realtimeProvider, (
              previous,
              next,
            ) {
              final sample = next.valueOrNull;
              if (sample != null) history.add(sample);
            });
            ref.onDispose(history.dispose);
            return history;
          }),
        ],
        child: const FoxTuneApp(),
      ),
    );
    // Let the layout load and the first samples arrive before measuring.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(find.byType(NavigationBar), findsOneWidget);

    await binding.watchPerformance(
      () => Future<void>.delayed(_measured),
      reportKey: 'dashboard_tab',
    );

    // The same feed with the dashboard hidden behind another tab.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Tables'),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await binding.watchPerformance(
      () => Future<void>.delayed(_measured),
      reportKey: 'tables_tab',
    );
  });
}

/// A running engine, as a stream of realtime blocks.
///
/// The continuous channels move all the time, as they do on a real engine;
/// the status bits change every few seconds, so most lamps hold steady from
/// one sample to the next - as they do on a real engine too.
class _SyntheticFeed {
  _SyntheticFeed(this.doc) : _decoder = RealtimeDecoder(doc.outputChannels);

  final IniDocument doc;
  final RealtimeDecoder _decoder;

  static const _interval = Duration(milliseconds: 33);

  RealtimeSnapshot at(DateTime time) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);

    void set(String name, num value) {
      final field = channels.channelNamed(name);
      final offset = field?.offset;
      if (field is! IniScalarField || offset == null) return;
      final raw = value.round();
      switch (field.type) {
        case IniDataType.u08:
          view.setUint8(offset, raw.clamp(0, 0xFF));
        case IniDataType.s08:
          view.setInt8(offset, raw.clamp(-0x80, 0x7F));
        case IniDataType.u16:
          view.setUint16(offset, raw.clamp(0, 0xFFFF), Endian.little);
        case IniDataType.s16:
          view.setInt16(offset, raw.clamp(-0x8000, 0x7FFF), Endian.little);
        case IniDataType.u32:
        case IniDataType.s32:
        case IniDataType.f32:
          break;
      }
    }

    final t = time.millisecondsSinceEpoch / 1000;
    // Throttle blips every few seconds, and the rest following them.
    final load = (math.sin(t * 0.9) + 1) / 2;
    final ripple = math.sin(t * 7);

    set('rpm', 900 + load * 5200 + ripple * 40);
    set('map', 30 + load * 70);
    set('tps', load * 200);
    set('afr', 147 - load * 20 + ripple * 6);
    set('egoCorrection', 100 + ripple * 6);
    set('advance', 12 + load * 22);
    set('VE1', 45 + load * 45);
    set('pulseWidth', 1800 + load * 9000);
    set('gammaEnrich', 100 + (1 - load) * 20);
    set('coolantRaw', 128 + math.sin(t * 0.05) * 3);
    set('iatRaw', 70);
    set('batteryVoltage', 138 + ripple * 2);
    // Running and synced, with warmup switching on and off every 5 s.
    set('engine', ((t ~/ 5).isEven) ? 0x01 : 0x09);
    set('status1', 0x80);
    set('secl', t % 256);
    return _decoder.decode(block, timestamp: time);
  }

  /// Samples covering [span] up to now, oldest first.
  Iterable<RealtimeSnapshot> backfill(Duration span) sync* {
    final now = DateTime.now();
    final count = span.inMicroseconds ~/ _interval.inMicroseconds;
    for (var i = count; i > 0; i--) {
      yield at(now.subtract(_interval * i));
    }
  }

  Stream<RealtimeSnapshot> live() =>
      Stream.periodic(_interval, (_) => at(DateTime.now()));
}

class _Connected extends ConnectionController {
  _Connected(this._state);
  final EcuConnectionState _state;

  @override
  EcuConnectionState build() => _state;
}

class _FixedTune extends TuneController {
  _FixedTune(this._tune);
  final TuneState? _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

class _NoWake implements ScreenWake {
  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}
}
