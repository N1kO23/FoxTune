import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/definitions/definitions_screen.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// Hands out [next] when asked for a file, and keeps what is saved.
class _Files extends FileSaving {
  _Files() : super(mobile: false);

  PickedFile? next;
  final saved = <String, List<int>>{};

  @override
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async => next;

  @override
  Future<String?> saveBytes({
    required String fileName,
    required String extension,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    saved[fileName] = bytes;
    return fileName;
  }
}

/// A connection held as the test says, which records a request to look for
/// its definition again and answers it with [afterRetry].
class _FixedConnection extends ConnectionController {
  _FixedConnection(this._initial);

  final EcuConnectionState _initial;
  EcuConnectionState? afterRetry;
  int retries = 0;

  @override
  EcuConnectionState build() => _initial;

  @override
  Future<void> retryDefinition() async {
    retries++;
    if (afterRetry case final next?) state = next;
  }
}

void main() {
  late String speeduinoSource;
  late IniDocument speeduino;

  setUpAll(() {
    speeduinoSource = File('assets/speeduino.ini').readAsStringSync();
    speeduino = IniParser(defined: {'CELSIUS'}).parse(speeduinoSource);
  });

  late Directory storage;
  late _Files files;
  late _FixedConnection connection;

  /// What the stubbed websites serve, by address.
  late Map<Uri, String> served;

  setUp(() {
    storage = Directory.systemTemp.createTempSync('foxtune_definitions_ui');
    files = _Files();
    served = {};
  });

  tearDown(() => storage.deleteSync(recursive: true));

  String definitionFor(String signature) =>
      speeduinoSource.replaceFirst('"speeduino 202504-dev"', '"$signature"');

  PickedFile fileFor(String signature, {String name = 'speeduino.ini'}) =>
      PickedFile(
        name: name,
        bytes: Uint8List.fromList(utf8.encode(definitionFor(signature))),
      );

  EcuConnected connectedTo(
    String signature, {
    required SignatureStatus status,
    IniDocument? definition,
  }) => EcuConnected(
    port: const EcuPort(address: '/dev/ttyACM0'),
    identification: EcuIdentification(signature: signature, version: 'test'),
    signatureStatus: status,
    expectedSignature: definition?.identity.signature,
    definition: definition,
  );

  Future<void> pumpScreen(
    WidgetTester tester, {
    EcuConnectionState state = const EcuDisconnected(),
  }) async {
    connection = _FixedConnection(state);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bundledDefinitionProvider.overrideWith((ref) async => speeduino),
          bundledDefinitionSourceProvider.overrideWith(
            (ref) async => speeduinoSource,
          ),
          appStorageDirectoryProvider.overrideWith((ref) async => storage),
          fileSavingProvider.overrideWithValue(files),
          definitionFetcherProvider.overrideWithValue(
            (url) async => served[url],
          ),
          connectionProvider.overrideWith(() => connection),
        ],
        child: const MaterialApp(home: DefinitionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Adds a file through the screen's own button.
  Future<void> add(WidgetTester tester, PickedFile file) async {
    files.next = file;
    await tester.tap(find.text('Add from file'));
    await tester.pumpAndSettle();
  }

  Finder tileOf(String name) => find.widgetWithText(ListTile, name);

  Future<void> openMenuOf(WidgetTester tester, String name) async {
    final menu = find.descendant(
      of: tileOf(name),
      matching: find.byTooltip('Definition'),
    );
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
  }

  testWidgets('lists the built-in definition, and says when none are kept', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(tileOf('speeduino 202504-dev'), findsOneWidget);
    expect(find.text('Ships with FoxTune'), findsOneWidget);
    expect(find.textContaining('None yet.'), findsOneWidget);
    expect(find.text('In use'), findsNothing);
  });

  testWidgets('adds a definition from a file, and lists where it came from', (
    tester,
  ) async {
    await pumpScreen(tester);
    await add(tester, fileFor('speeduino 202501', name: 'release.ini'));

    expect(tileOf('speeduino 202501'), findsOneWidget);
    expect(find.textContaining('Added from release.ini'), findsOneWidget);
    expect(find.text('Added speeduino 202501.'), findsOneWidget);
    expect(find.textContaining('None yet.'), findsNothing);
  });

  testWidgets('asks before replacing a kept definition', (tester) async {
    await pumpScreen(tester);
    await add(tester, fileFor('speeduino 202501', name: 'old.ini'));
    await add(tester, fileFor('speeduino 202501', name: 'new.ini'));

    expect(find.text('Replace the kept definition?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Replace'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Added from new.ini'), findsOneWidget);
    expect(find.textContaining('Added from old.ini'), findsNothing);
  });

  testWidgets('says why a file is refused', (tester) async {
    await pumpScreen(tester);
    await add(
      tester,
      PickedFile(
        name: 'notes.ini',
        bytes: Uint8List.fromList(utf8.encode('[MegaTune]\n')),
      ),
    );

    expect(find.textContaining('declares no signature'), findsOneWidget);
    expect(find.textContaining('None yet.'), findsOneWidget);
  });

  testWidgets('removes a kept definition once confirmed, and never the '
      'built-in one', (tester) async {
    await pumpScreen(tester);
    await add(tester, fileFor('speeduino 202501'));

    await openMenuOf(tester, 'speeduino 202504-dev');
    expect(find.text('Save a copy'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await openMenuOf(tester, 'speeduino 202501');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tileOf('speeduino 202501'), findsOneWidget);

    await openMenuOf(tester, 'speeduino 202501');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(tileOf('speeduino 202501'), findsNothing);
    expect(Directory('${storage.path}/definitions').listSync(), isEmpty);
  });

  testWidgets('saves a copy of a definition', (tester) async {
    await pumpScreen(tester);
    await openMenuOf(tester, 'speeduino 202504-dev');
    await tester.tap(find.text('Save a copy'));
    await tester.pumpAndSettle();

    expect(
      utf8.decode(files.saved['speeduino_202504-dev.ini']!),
      speeduinoSource,
    );
  });

  testWidgets('marks the definition the connected ECU is read through', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      state: connectedTo(
        'speeduino 202504-dev',
        status: SignatureStatus.matched,
        definition: speeduino,
      ),
    );

    expect(
      find.descendant(
        of: tileOf('speeduino 202504-dev'),
        matching: find.text('In use'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a definition added for the ECU waiting on it is put to use', (
    tester,
  ) async {
    // A Speeduino on a release FoxTune does not ship, read through the
    // built-in definition until its own turns up.
    await pumpScreen(
      tester,
      state: connectedTo(
        'speeduino 202501',
        status: SignatureStatus.mismatched,
        definition: speeduino,
      ),
    );
    connection.afterRetry = connectedTo(
      'speeduino 202501',
      status: SignatureStatus.matched,
      definition: IniParser(defined: {'CELSIUS'})
          .parse(definitionFor('speeduino 202501')),
    );

    await add(tester, fileFor('speeduino 202501'));

    expect(connection.retries, 1);
    expect(
      find.text('Added speeduino 202501, and it is now in use.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tileOf('speeduino 202501'),
        matching: find.text('In use'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a definition for some other ECU is only kept', (tester) async {
    await pumpScreen(
      tester,
      state: connectedTo(
        'speeduino 202501',
        status: SignatureStatus.mismatched,
        definition: speeduino,
      ),
    );
    await add(tester, fileFor('speeduino 202402'));

    expect(connection.retries, 0);
    expect(find.text('Added speeduino 202402.'), findsOneWidget);
  });

  testWidgets('turns automatic downloads on and off for each firmware', (
    tester,
  ) async {
    await pumpScreen(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(DefinitionsScreen)),
    );

    await tester.tap(find.widgetWithText(SwitchListTile, 'rusEFI'));
    await tester.pumpAndSettle();
    expect(container.read(appSettingsProvider).downloadDefinitionsFor, {
      EcuFamily.speeduino,
    });
  });

  group('downloading', () {
    Finder inDialog(Finder finder) =>
        find.descendant(of: find.byType(AlertDialog), matching: finder);

    testWidgets('a Speeduino release is chosen from speeduino.com\'s list', (
      tester,
    ) async {
      served[speeduinoVersionsUrl] =
          '202501.7\n202402.2\nmaster\nEEPROM_clear\n';
      served[speeduinoDefinitionUrl('202501.7')] = definitionFor(
        'speeduino 202501',
      );
      await pumpScreen(tester);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('202402.2')), findsOneWidget);
      expect(inDialog(find.text('master')), findsOneWidget);
      // A firmware that wipes the settings, not a definition.
      expect(inDialog(find.text('EEPROM_clear')), findsNothing);

      await tester.tap(inDialog(find.text('202501.7')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tileOf('speeduino 202501'), findsOneWidget);
      expect(
        find.textContaining('Downloaded from speeduino.com'),
        findsOneWidget,
      );
      expect(find.text('Downloaded speeduino 202501.'), findsOneWidget);
    });

    testWidgets('a rusEFI build is downloaded by its signature', (
      tester,
    ) async {
      const signature = 'rusEFI master.2026.09.21.uaefi.419928595';
      served[rusEfiDefinitionUrl(signature)!] = File(
        '../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini',
      ).readAsStringSync();
      await pumpScreen(tester);

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.text('rusEFI')));
      await tester.pumpAndSettle();

      await tester.enterText(inDialog(find.byType(TextField)), 'rusEFI 1.0');
      await tester.pump();
      expect(
        inDialog(find.textContaining('Not a signature rusEFI publishes')),
        findsOneWidget,
      );

      await tester.enterText(inDialog(find.byType(TextField)), signature);
      await tester.pump();
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Download')));
      await tester.pumpAndSettle();

      expect(tileOf(signature), findsOneWidget);
      expect(find.textContaining('Downloaded from rusefi.com'), findsOneWidget);
    });
  });
}
