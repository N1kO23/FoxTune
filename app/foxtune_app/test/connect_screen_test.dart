import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_app/src/tune/recovered_edits.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

const _port = EcuPort(address: '/dev/bus/usb/001/004', vendorId: 0x2341);

/// A connection held in whatever state the test asks for.
class _FixedConnection extends ConnectionController {
  _FixedConnection(this._initial);

  final EcuConnectionState _initial;
  int disconnects = 0;
  int reconnects = 0;

  @override
  EcuConnectionState build() => _initial;

  @override
  Future<void> disconnect() async {
    disconnects++;
    state = const EcuDisconnected();
  }

  @override
  Future<void> reconnect() async => reconnects++;
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

class _SavingPicker extends FilePicker {
  Uint8List? saved;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    saved = bytes;
    return '/storage/emulated/0/Download/$fileName';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  TuneState dirtyTune() {
    final tune = TuneState.empty(doc)..markClean();
    SettingView.of(tune, 'reqFuel')!.setValue(9.5);
    return tune;
  }

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

  group('disconnecting', () {
    Future<_FixedConnection> pumpHarness(
      WidgetTester tester, {
      required TuneState tune,
    }) async {
      final connection = _FixedConnection(connected());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => connection),
            tuneProvider.overrideWith(() => _FixedTune(tune)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  // Load the tune, as the tabs would have.
                  ref.watch(tuneProvider);
                  return TextButton(
                    onPressed: () => confirmDisconnect(context, ref),
                    child: const Text('Disconnect'),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return connection;
    }

    testWidgets('asks first when there are unburned changes', (tester) async {
      final connection = await pumpHarness(tester, tune: dirtyTune());

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('Disconnect with unburned changes?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(connection.disconnects, 0);

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(connection.disconnects, 1);
    });

    testWidgets('does not ask when nothing has changed', (tester) async {
      final clean = TuneState.empty(doc)..markClean();
      final connection = await pumpHarness(tester, tune: clean);

      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(connection.disconnects, 1);
    });
  });

  group('connect screen', () {
    Future<_FixedConnection> pumpScreen(
      WidgetTester tester, {
      required EcuConnectionState state,
      RecoveredEdits? recovered,
    }) async {
      final connection = _FixedConnection(state);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            connectionProvider.overrideWith(() => connection),
            tuneProvider.overrideWith(() => _FixedTune(null)),
            portsProvider.overrideWith((ref) async => const [_port]),
            screenWakeProvider.overrideWithValue(_NoWake()),
            fileSavingProvider.overrideWithValue(
              const FileSaving(mobile: true),
            ),
            if (recovered != null)
              recoveredEditsProvider.overrideWith((ref) => recovered),
          ],
          child: const MaterialApp(home: ConnectScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return connection;
    }

    testWidgets('a lost connection says why and offers to reconnect', (
      tester,
    ) async {
      final connection = await pumpScreen(
        tester,
        state: const EcuConnectionLost('The ECU was unplugged.', port: _port),
      );

      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.textContaining('unplugged'), findsOneWidget);

      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(connection.reconnects, 1);
    });

    testWidgets('rescued edits are offered for saving until dealt with', (
      tester,
    ) async {
      final picker = _SavingPicker();
      FilePicker.platform = picker;
      final tune = dirtyTune();

      await pumpScreen(
        tester,
        state: const EcuDisconnected(),
        recovered: RecoveredEdits(
          tune: tune.copy(),
          pages: tune.dirtyPages,
          at: DateTime(2026, 9, 21),
        ),
      );

      expect(
        find.textContaining('were kept when the connection ended'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save as .msq'));
      await tester.pumpAndSettle();

      // What was saved is a tune carrying the edit.
      final reloaded = TuneState.empty(doc);
      MsqCodec.decode(String.fromCharCodes(picker.saved!), reloaded);
      expect(SettingView.of(reloaded, 'reqFuel')!.value, closeTo(9.5, 0.05));

      // And once safely saved, the banner goes.
      expect(
        find.textContaining('were kept when the connection ended'),
        findsNothing,
      );
    });
  });
}
