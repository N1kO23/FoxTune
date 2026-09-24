import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/dashboard/dashboard_screen.dart';
import 'package:foxtune_app/src/dashboard/meter_gauge.dart';
import 'package:foxtune_app/src/settings/settings_screen.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/table_editor_screen.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);
  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

class _Connected extends ConnectionController {
  _Connected(this._state);
  final EcuConnectionState _state;

  @override
  EcuConnectionState build() => _state;
}

/// rusEFI's screens, generated from its real definition.
///
/// Every screen here is generated rather than written, so the only way to
/// know rusEFI's definition works is to render what it describes: its front
/// page as a dashboard, and every entry its menus offer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;
  late Directory storage;

  setUpAll(() {
    doc = IniParser().parse(
      File('../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini')
          .readAsStringSync(),
    );
  });

  setUp(() {
    tune = TuneState.empty(doc)..markClean();
    storage = Directory.systemTemp.createTempSync('foxtune_rusefi_screens');
  });
  tearDown(() => storage.deleteSync(recursive: true));

  EcuConnected connection() => EcuConnected(
    port: const EcuPort(address: '127.0.0.1:29001'),
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'rusEFI test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  /// A live sample with an engine idling in it.
  RealtimeSnapshot idle() {
    final channels = doc.outputChannels;
    final block = Uint8List(channels.blockSize!);
    final view = ByteData.sublistView(block);
    void put(String name, double value) {
      final field = channels.channelNamed(name)! as IniScalarField;
      final scale = field.scale.literalValue!;
      final raw = (value / scale).round();
      switch (field.type) {
        case IniDataType.u16:
          view.setUint16(field.offset!, raw, Endian.little);
        case IniDataType.s16:
          view.setInt16(field.offset!, raw, Endian.little);
        case IniDataType.f32:
          view.setFloat32(field.offset!, value, Endian.little);
        default:
          throw UnsupportedError('$name: ${field.type}');
      }
    }

    put('RPMValue', 850);
    put('VBatt', 13.9);
    put('coolant', 88);
    put('TPSValue', 0);
    put('MAPValue', 34);
    put('sparkDwell', 3.1);
    return RealtimeDecoder(channels).decode(block);
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(1400, 1000),
    String? open,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final snapshot = idle();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(() => _Connected(connection())),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
          tuneProvider.overrideWith(() => _FakeTuneController(tune)),
          realtimeMonitorProvider.overrideWithValue(null),
          realtimeProvider.overrideWith(
            (ref) => Stream<RealtimeSnapshot>.value(snapshot),
          ),
          if (open != null)
            selectedSettingProvider.overrideWithBuild((ref, _) => open),
        ],
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  group('the dashboard', () {
    testWidgets('starts from rusEFI\'s own front page', (tester) async {
      await pump(tester, DashboardScreen(connection: connection()));
      expect(tester.takeException(), isNull);

      final dials = tester
          .widgetList<MeterGauge>(find.byType(MeterGauge))
          .map((m) => m.spec.channel)
          .toSet();
      for (final name in doc.frontPage.gauges) {
        expect(dials, contains(doc.gaugeNamed(name)!.channel), reason: name);
      }
      final rpm = tester
          .widgetList<MeterGauge>(find.byType(MeterGauge))
          .firstWhere((m) => m.spec.channel == 'RPMValue');
      expect(rpm.value, 850);
      // A float channel on the dial, not rounded.
      final dwell = tester
          .widgetList<MeterGauge>(find.byType(MeterGauge))
          .firstWhere((m) => m.spec.channel == 'sparkDwell');
      expect(dwell.value, closeTo(3.1, 1e-5));
    });

    testWidgets('fits at phone width', (tester) async {
      await pump(
        tester,
        DashboardScreen(connection: connection()),
        size: const Size(400, 850),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(MeterGauge), findsWidgets);
    });
  });

  group('every screen the menus offer', () {
    Set<String> targets() => {
      for (final menu in doc.menus)
        for (final item in menu.leaves)
          if (!item.isBuiltIn) item.target,
    };

    for (final (name, size) in [
      ('desktop', const Size(1400, 2400)),
      ('phone', const Size(400, 2400)),
    ]) {
      testWidgets('renders without a fault at $name width', (tester) async {
        final all = targets();
        expect(all.length, greaterThan(100));
        // A target the definition does not describe shows a message rather
        // than failing, so it has to be ruled out here.
        for (final target in all) {
          expect(
            doc.targetKind(target),
            isNot(anyOf(IniTargetKind.unknown, IniTargetKind.builtIn)),
            reason: target,
          );
        }

        final broken = <String>[];
        for (final target in all) {
          await pump(
            tester,
            SettingsScreen(connection: connection()),
            size: size,
            open: target,
          );
          final failure = tester.takeException();
          if (failure != null) broken.add('$target: $failure');
        }
        expect(broken, isEmpty, reason: broken.join('\n'));
      });
    }
  });

  testWidgets('every table opens as an editable grid', (tester) async {
    // The settings list only offers to open a table; the grid is where the
    // floats, the scaling and the axes actually meet the screen.
    final broken = <String>[];
    for (final table in doc.tables) {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => _Connected(connection())),
            tuneProvider.overrideWith(() => _FakeTuneController(tune)),
            realtimeMonitorProvider.overrideWithValue(null),
            realtimeProvider.overrideWith(
              (ref) => const Stream<RealtimeSnapshot>.empty(),
            ),
            selectedTableProvider.overrideWithBuild((ref, _) => table.id),
          ],
          child: MaterialApp(
            home: Scaffold(body: TableEditorScreen(connection: connection())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final failure = tester.takeException();
      if (failure != null) {
        broken.add('${table.id}: $failure');
      } else if (find.byType(TableGrid).evaluate().isEmpty) {
        broken.add('${table.id}: no grid');
      }
    }
    await tester.binding.setSurfaceSize(null);
    expect(broken, isEmpty, reason: broken.join('\n'));
  });
}
