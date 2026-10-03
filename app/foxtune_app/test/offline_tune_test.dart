import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/autotune/autotune_screen.dart';
import 'package:foxtune_app/src/autotune/log_replay_screen.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_app/src/logging/log_files.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/host_values.dart';
import 'package:foxtune_app/src/tune/offline_tune.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

const _port = EcuPort(address: '/dev/ttyACM0', vendorId: 0x2341);

/// A connection the test switches on and off.
class _Connection extends ConnectionController {
  _Connection(this._initial);

  final EcuConnectionState _initial;

  @override
  EcuConnectionState build() => _initial;

  void set(EcuConnectionState next) => state = next;
}

class _NoWake implements ScreenWake {
  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}
}

/// Keeps what is saved, and hands out [next] when asked for a file.
class _Files extends FileSaving {
  _Files() : super(mobile: false);

  String? saved;
  PickedFile? next;

  @override
  Future<String?> saveBytes({
    required String fileName,
    required String extension,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    saved = utf8.decode(bytes);
    return '/home/tuner/$fileName';
  }

  @override
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async => next;
}

/// Editing a `.msq` with no ECU: opened from the port list, edited with the
/// same screens as an ECU's tune, and saved back out - never burned.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;
  late _Files files;

  /// Where Gauge Limits and the rest of this computer's settings are kept.
  late Directory storage;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  setUp(() {
    storage = Directory.systemTemp.createTempSync('foxtune_offline');
    addTearDown(() => storage.deleteSync(recursive: true));
    files = _Files();
    tune = TuneState.empty(doc);
    final ego = tune.locate('egoType')!;
    tune.writeBits(ego.page, ego.field as IniBitsField, 2);
    SettingView.of(tune, 'stoich')!.setValue(14.7);
    final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    for (var i = 0; i < 16; i++) {
      ve.setXAt(i, 500 + i * 500);
      ve.setYAt(i, 20 + i * 10);
    }
    for (var r = 0; r < 16; r++) {
      for (var c = 0; c < 16; c++) {
        ve.setValueAt(r, c, 50);
      }
    }
    ve.setValueAt(4, 3, 61);
  });

  PickedFile msq(TuneState state, {String name = 'base.msq'}) =>
      PickedFile(name: name, bytes: utf8.encode(MsqCodec.encode(state)));

  EcuConnected connected() => EcuConnected(
    port: _port,
    identification: EcuIdentification(
      signature: doc.identity.signature!,
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.matched,
    expectedSignature: doc.identity.signature,
    definition: doc,
  );

  List<Override> overrides(_Connection connection) => [
    connectionProvider.overrideWith(() => connection),
    appStorageDirectoryProvider.overrideWith((ref) async => storage),
    portsProvider.overrideWith((ref) async => const [_port]),
    screenWakeProvider.overrideWithValue(_NoWake()),
    fileSavingProvider.overrideWithValue(files),
    recentLogsProvider.overrideWith((ref) async => const []),
    definitionLibraryProvider.overrideWithValue(
      DefinitionLibrary(
        bundled: () async => doc,
        storage: () async => null,
        fetch: (_) async => null,
        symbols: {'CELSIUS'},
      ),
    ),
  ];

  double? veAt(TuneState state, int row, int column) =>
      TableView.of(state, doc.tableNamed('veTable1Tbl')!)!.valueAt(row, column);

  group('the tune', () {
    test('is the open file\'s while no ECU is connected', () async {
      final connection = _Connection(const EcuDisconnected());
      final container = ProviderContainer(overrides: overrides(connection));
      addTearDown(container.dispose);

      expect(await container.read(tuneProvider.future), isNull);

      container.read(offlineTuneProvider.notifier).open(tune, 'base.msq');
      expect(
        identical(await container.read(tuneProvider.future), tune),
        isTrue,
      );
      expect(container.read(editingOfflineProvider), isTrue);
      // A file may be edited; nothing may be written to an ECU from it.
      expect(container.read(editPermissionProvider).allowed, isTrue);
      expect(container.read(writePermissionProvider).allowed, isFalse);
    });

    test(
      'changes are shown against the file as opened, then as saved',
      () async {
        final connection = _Connection(const EcuDisconnected());
        final container = ProviderContainer(overrides: overrides(connection));
        addTearDown(container.dispose);
        container.read(offlineTuneProvider.notifier).open(tune, 'base.msq');
        await container.read(tuneProvider.future);

        TableView.of(
          tune,
          doc.tableNamed('veTable1Tbl')!,
        )!.setValueAt(4, 3, 70);
        container.read(tuneProvider.notifier).notifyEdited();
        expect(container.read(offlineTuneProvider)!.unsaved, isTrue);
        expect(veAt(container.read(tuneBaselineProvider)!, 4, 3), 61);

        container.read(offlineTuneProvider.notifier).markSaved();
        container.read(tuneProvider.notifier).notifyEdited();
        expect(container.read(offlineTuneProvider)!.unsaved, isFalse);
        expect(veAt(container.read(tuneBaselineProvider)!, 4, 3), 70);
      },
    );

    test(
      'a Gauge Limit set offline is kept, as one set connected is',
      () async {
        // They are this computer's, kept per ECU family - a .msq carries none -
        // so a file has nowhere else to keep them.
        final connection = _Connection(const EcuDisconnected());
        final container = ProviderContainer(overrides: overrides(connection));
        addTearDown(container.dispose);
        container.read(offlineTuneProvider.notifier).open(tune, 'base.msq');
        await container.read(tuneProvider.future);

        SettingView.of(tune, 'rpmwarn')!.setValue(5500);
        container.read(tuneProvider.notifier).notifyEdited();

        final kept = TuneState.empty(doc);
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await HostValues(container.read(jsonStoreProvider)).restoreInto(kept);
          if (SettingView.of(kept, 'rpmwarn')!.value == 5500) break;
        }
        expect(SettingView.of(kept, 'rpmwarn')!.value, 5500);
        expect(tune.isDirty, isFalse, reason: 'not part of the file');
      },
    );

    test('a connection takes over, and the file comes back after it', () async {
      final connection = _Connection(const EcuDisconnected());
      final container = ProviderContainer(overrides: overrides(connection));
      addTearDown(container.dispose);
      container.read(offlineTuneProvider.notifier).open(tune, 'base.msq');
      final listener = container.listen(tuneProvider, (_, _) {});
      addTearDown(listener.close);

      connection.set(connected());
      await container.pump();
      expect(container.read(editingOfflineProvider), isFalse);
      expect(
        identical(container.read(tuneProvider).value, tune),
        isFalse,
        reason: 'the ECU\'s tune, not the file\'s',
      );

      connection.set(const EcuDisconnected());
      expect(
        identical(await container.read(tuneProvider.future), tune),
        isTrue,
      );
    });
  });

  group('from the port list', () {
    Future<ProviderContainer> pumpScreen(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer(
        overrides: overrides(_Connection(const EcuDisconnected())),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    Future<void> openFile(WidgetTester tester) async {
      files.next = msq(tune);
      await tester.tap(find.text('Open a tune file'));
      await tester.pumpAndSettle();
      // Past the report of what loaded, which sits over the tabs.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    testWidgets('opens a .msq, with its own definition, to edit', (
      tester,
    ) async {
      final container = await pumpScreen(tester);
      await openFile(tester);

      final open = container.read(offlineTuneProvider)!;
      expect(open.fileName, 'base.msq');
      expect(open.unsaved, isFalse);
      expect(veAt(open.tune, 4, 3), 61);

      expect(find.textContaining('base.msq'), findsWidgets);
      expect(find.text('Tables'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Dashboard'), findsNothing);
      // Editable, and with nothing to burn to.
      expect(tester.widget<TableGrid>(find.byType(TableGrid)).editable, isTrue);
      expect(find.text('Write mode'), findsNothing);
      expect(find.text('Burn to ECU'), findsNothing);
      expect(find.text('Save .msq'), findsWidgets);
    });

    testWidgets('saves under the name it was opened with', (tester) async {
      final container = await pumpScreen(tester);
      await openFile(tester);
      final open = container.read(offlineTuneProvider)!;
      TableView.of(
        open.tune,
        doc.tableNamed('veTable1Tbl')!,
      )!.setValueAt(4, 3, 70);
      container.read(tuneProvider.notifier).notifyEdited();
      await tester.pumpAndSettle();
      expect(find.textContaining('unsaved changes'), findsOneWidget);

      await tester.tap(find.byTooltip('Save as .msq'));
      await tester.pumpAndSettle();

      final saved = TuneState.empty(doc);
      MsqCodec.decode(files.saved!, saved);
      expect(veAt(saved, 4, 3), 70);
      expect(container.read(offlineTuneProvider)!.unsaved, isFalse);
      expect(find.textContaining('unsaved changes'), findsNothing);
    });

    testWidgets('asks before closing over unsaved changes', (tester) async {
      final container = await pumpScreen(tester);
      await openFile(tester);
      TableView.of(
        container.read(offlineTuneProvider)!.tune,
        doc.tableNamed('veTable1Tbl')!,
      )!.setValueAt(4, 3, 70);
      container.read(tuneProvider.notifier).notifyEdited();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close base.msq'));
      await tester.pumpAndSettle();
      expect(find.text('Close without saving?'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(container.read(offlineTuneProvider), isNotNull);

      await tester.tap(find.byTooltip('Close base.msq'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(container.read(offlineTuneProvider), isNull);
      expect(find.text('Open a tune file'), findsOneWidget);
    });

    testWidgets('closes at once when nothing has changed', (tester) async {
      final container = await pumpScreen(tester);
      await openFile(tester);

      await tester.tap(find.byTooltip('Close base.msq'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(container.read(offlineTuneProvider), isNull);
    });

    testWidgets('autotuning offers a log replay into the file', (tester) async {
      await pumpScreen(tester);
      await openFile(tester);

      await tester.tap(find.text('Autotune'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Replay a log'));
      await tester.pumpAndSettle();

      expect(find.byType(LogReplayScreen), findsOneWidget);
      expect(find.text('Tune: base.msq'), findsOneWidget);
    });
  });

  testWidgets('autotuning is not offered for a firmware it does not know', (
    tester,
  ) async {
    final other = IniParser(defined: {'CELSIUS'}).parse(
      File('assets/speeduino.ini')
          .readAsStringSync()
          .replaceFirst('"${doc.identity.signature}"', '"MS3 Format 0566.05"'),
    );
    final container = ProviderContainer(
      overrides: overrides(_Connection(const EcuDisconnected())),
    );
    addTearDown(container.dispose);
    container
        .read(offlineTuneProvider.notifier)
        .open(TuneState.empty(other), 'other.msq');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: OfflineAutotunePane())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('not yet available'), findsOneWidget);
    expect(find.text('Replay a log'), findsNothing);
  });
}
