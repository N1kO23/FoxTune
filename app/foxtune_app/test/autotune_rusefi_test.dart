import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/autotune/autotune_controller.dart';
import 'package:foxtune_app/src/autotune/autotune_screen.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:foxtune_tune/simulation.dart';

/// Supplies a ready-made tune instead of reading one from an ECU.
class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);

  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

/// VE autotuning on a rusEFI, driven through the screen against rusEFI's own
/// definition.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;
  late StreamController<RealtimeSnapshot> feed;
  late DateTime clock;

  setUpAll(() {
    doc = IniParser().parse(
      File('../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini')
          .readAsStringSync(),
    );
  });

  setUp(() {
    // A base tune autotuning will arm on: Metric, speed density, a CAN
    // wideband, no long-term trims, the display in AFR.
    final pages = [for (final size in doc.constants.pageSizes) Uint8List(size)];
    TunedEngineSimulation(definition: doc, pages: pages).seedTune();
    tune = TuneState.fromPages(doc, pages);
    feed = StreamController<RealtimeSnapshot>.broadcast();
    clock = DateTime(2026, 1, 1);
  });

  tearDown(() => feed.close());

  void choose(String name, String label) {
    final setting = SettingView.of(tune, name)!;
    setting.setOptionIndex(setting.options.indexOf(label));
    tune.markClean();
  }

  /// A realtime block holding everything rusEFI's `[VeAnalyze]` reads, stored
  /// the way the definition says each channel is.
  RealtimeSnapshot sample({
    double rpm = 3000,
    double load = 68,
    double afr = 14.7,
    double coolant = 85,
    double deltaTps = 0,
  }) {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);

    void put(String name, double value) {
      final field = channels.channelNamed(name)! as IniScalarField;
      final raw = rawFromScaled(
        value,
        field.scale.literalValue!,
        field.translate.literalValue!,
      );
      final at = field.offset!;
      switch (field.type) {
        case IniDataType.u16:
          view.setUint16(at, raw.round(), Endian.little);
        case IniDataType.s16:
          view.setInt16(at, raw.round(), Endian.little);
        case IniDataType.f32:
          view.setFloat32(at, raw, Endian.little);
        default:
          fail('Unexpected storage for $name');
      }
    }

    put('RPMValue', rpm);
    put('veTableYAxis', load);
    put('afrTableYAxis', load);
    put('coolant', coolant);
    put('deltaTps', deltaTps);
    put('VBatt', 13.8);
    put('TPSValue', 30);
    // One mixture, on both of the channels rusEFI reports it on.
    put('afrGasolineScale', afr);
    put('lambdaValue', afr / 14.7);
    put('Gego', 100);

    return RealtimeDecoder(
      channels,
      constantResolver: TuneValueResolver(tune).resolve,
    ).decode(block, timestamp: clock);
  }

  Future<ProviderContainer> pumpAutotune(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(
      overrides: [
        tuneProvider.overrideWith(() => _FakeTuneController(tune)),
        writePermissionProvider.overrideWithValue(
          const WritePermission.granted(),
        ),
        realtimeMonitorProvider.overrideWithValue(null),
        realtimeProvider.overrideWith((ref) => feed.stream),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brandTheme(Brightness.light),
          home: Scaffold(
            body: AutotuneScreen(
              connection: EcuConnected(
                port: const EcuPort(address: '127.0.0.1:29001'),
                identification: EcuIdentification(
                  signature: doc.identity.signature!,
                  version: 'rusEFI test',
                ),
                signatureStatus: SignatureStatus.matched,
                expectedSignature: doc.identity.signature,
                definition: doc,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('Start autotune'));
    await tester.pumpAndSettle();
  }

  /// Pushes [count] samples through, letting the operating point settle.
  Future<void> drive(
    WidgetTester tester, {
    required double afr,
    int count = 30,
    double coolant = 85,
    double deltaTps = 0,
  }) async {
    RealtimeSnapshot next() =>
        sample(afr: afr, coolant: coolant, deltaTps: deltaTps);
    feed.add(next());
    await tester.pump();
    clock = clock.add(const Duration(milliseconds: 600));

    for (var i = 0; i < count; i++) {
      feed.add(next());
      await tester.pump();
      clock = clock.add(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('is offered, and arms', (tester) async {
    final container = await pumpAutotune(tester);
    expect(find.textContaining('not yet available'), findsNothing);

    await start(tester);
    expect(tester.takeException(), isNull);
    expect(container.read(autotuneProvider).armed, isTrue);
  });

  testWidgets('a lean run raises the cells it visited, awaiting a burn', (
    tester,
  ) async {
    final container = await pumpAutotune(tester);
    await start(tester);
    await drive(tester, afr: 15.5);

    final session = container.read(autotuneProvider);
    expect(session.accepted, greaterThan(0));
    expect(session.moved, greaterThan(0));

    final ve = TableView.of(tune, doc.tableNamed('veTableTbl')!)!;
    final cell = ve.cellFor(3000, 68)!;
    final seeded =
        TunedEngineSimulation.defaultAirflow(
          ve.xAt(cell.column)!,
          ve.yAt(cell.row)!,
        ) *
        0.92;
    expect(ve.valueAt(cell.row, cell.column), greaterThan(seeded + 0.5));
    expect(tune.isDirty, isTrue);
    expect(find.text('Burn to ECU'), findsOneWidget);
  });

  testWidgets('will not arm on a MAP axis shown in psi', (tester) async {
    choose('useMetricOnInterface', 'Imperial');
    final container = await pumpAutotune(tester);
    await start(tester);

    expect(container.read(autotuneProvider).armed, isFalse);
    expect(find.textContaining('Imperial'), findsOneWidget);
  });

  testWidgets('names the definition\'s filters when they reject', (
    tester,
  ) async {
    await pumpAutotune(tester);
    await start(tester);

    await drive(tester, afr: 15.5, coolant: 40, count: 2);
    expect(find.textContaining('Minimum CLT'), findsOneWidget);

    await drive(tester, afr: 15.5, deltaTps: 80, count: 2);
    expect(find.textContaining('dTPS'), findsOneWidget);
  });
}
