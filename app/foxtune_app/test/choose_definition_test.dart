import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/definitions/choose_definition.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// Connected to an ECU whose definition has not been found yet.
class _NeedsDefinition extends ConnectionController {
  @override
  EcuConnectionState build() => const EcuConnected(
    port: EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(
      signature: 'speeduino 202599',
      version: 'Speeduino test',
    ),
    signatureStatus: SignatureStatus.unknown,
    expectedSignature: null,
  );
}

/// Opening a file fails with [error].
class _FailingFiles extends FileSaving {
  const _FailingFiles(this.error) : super(mobile: false);

  final Object error;

  @override
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async => throw error;
}

void main() {
  Future<void> choose(WidgetTester tester, Object error) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionProvider.overrideWith(_NeedsDefinition.new),
          fileSavingProvider.overrideWithValue(_FailingFiles(error)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => chooseDefinition(context, ref),
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('says so when no file dialog can be shown', (tester) async {
    // On Linux the dialog comes from the desktop portal, and with none running
    // the picker fails over D-Bus instead of opening anything.
    await choose(
      tester,
      Exception(
        'The name org.freedesktop.portal.Desktop was not provided by any '
        '.service files',
      ),
    );

    expect(find.textContaining('Could not open a file'), findsOneWidget);
  });

  testWidgets('says why a picked file was refused', (tester) async {
    await choose(
      tester,
      const WrongFileTypeException('"notes.txt" is not a .ini file.'),
    );

    expect(find.text('"notes.txt" is not a .ini file.'), findsOneWidget);
  });
}
