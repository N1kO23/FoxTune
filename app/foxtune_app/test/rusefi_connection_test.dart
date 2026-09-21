import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_state.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/testing.dart';

/// Connecting to a rusEFI: finding its definition, and reading its tune
/// through the commands that definition declares.
///
/// Runs the real connection controller over a real socket to a simulated
/// rusEFI. Only the download is stubbed, to stay off the network.
void main() {
  late String rusEfiSource;
  late IniDocument rusEfi;
  late String speeduinoSource;
  late IniDocument speeduino;

  setUpAll(() {
    rusEfiSource = File(
      '../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini',
    ).readAsStringSync();
    rusEfi = IniParser().parse(rusEfiSource);
    speeduinoSource = File('assets/speeduino.ini').readAsStringSync();
    speeduino = IniParser(defined: {'CELSIUS'}).parse(speeduinoSource);
  });

  late Directory storage;
  late FakeTsEcu ecu;
  late ProviderContainer container;
  var started = false;
  late List<Uri> fetched;

  /// What the stubbed rusefi.com serves, by URL.
  late Map<Uri, String> published;
  var offline = false;

  setUp(() {
    storage = Directory.systemTemp.createTempSync('foxtune_rusefi');
    fetched = [];
    published = {};
    offline = false;
  });

  tearDown(() async {
    if (started) {
      container.dispose();
      await ecu.stop();
      started = false;
    }
    storage.deleteSync(recursive: true);
  });

  Future<void> start(FakeTsEcu fake) async {
    ecu = fake;
    started = true;
    final port = await ecu.start();
    container = ProviderContainer(
      overrides: [
        definitionProvider.overrideWith((ref) async => speeduino),
        appStorageDirectoryProvider.overrideWith((ref) async => storage),
        definitionFetcherProvider.overrideWithValue((url) async {
          fetched.add(url);
          if (offline) throw const SocketException('offline');
          return published[url];
        }),
      ],
    );
    await container
        .read(connectionProvider.notifier)
        .connectToNetwork('127.0.0.1:$port');
  }

  EcuConnected connected() =>
      container.read(connectionProvider) as EcuConnected;

  final url = Uri.parse(
    'https://rusefi.com/online/ini/rusefi/master/2026/09/21/uaefi/419928595.ini',
  );

  test('works out where rusEFI publishes a definition', () {
    expect(rusEfiDefinitionUrl(rusEfi.identity.signature!), url);
    expect(rusEfiDefinitionUrl('speeduino 202504-dev'), isNull);
  });

  test('downloads the published definition, and keeps it', () async {
    published[url] = rusEfiSource;
    await start(FakeRusEfi.fromDefinition(rusEfi));

    final state = connected();
    expect(state.identification.family, EcuFamily.rusefi);
    expect(state.signatureStatus, SignatureStatus.matched);
    expect(state.definitionSource, DefinitionSource.downloaded);
    expect(state.definition!.identity.signature, rusEfi.identity.signature);
    expect(fetched, [url]);

    // Next time, offline, it comes from this device.
    offline = true;
    await container.read(connectionProvider.notifier).reconnect();
    expect(connected().definitionSource, DefinitionSource.cached);
  });

  test('reads the tune through rusEFI commands', () async {
    published[url] = rusEfiSource;
    await start(FakeRusEfi.fromDefinition(rusEfi));

    final tune = await container.read(tuneProvider.future);
    expect(tune, isNotNull);
    for (var page = 1; page <= ecu.pages.length; page++) {
      expect(tune!.page(page), ecu.pages[page - 1], reason: 'page $page');
    }
  });

  test('asks for the file when none is published, and checks it', () async {
    await start(FakeRusEfi.fromDefinition(rusEfi));

    final waiting = connected();
    expect(waiting.definition, isNull);
    expect(waiting.signatureStatus, SignatureStatus.unknown);
    expect(waiting.definitionProblem, contains('no definition for this build'));

    final controller = container.read(connectionProvider.notifier);
    // The wrong firmware's file is refused, and nothing changes.
    await expectLater(
      controller.adoptDefinition(speeduinoSource),
      throwsA(isA<DefinitionMismatchException>()),
    );
    expect(connected().definition, isNull);

    await controller.adoptDefinition(rusEfiSource);
    final ready = connected();
    expect(ready.definitionSource, DefinitionSource.picked);
    expect(ready.signatureStatus, SignatureStatus.matched);
    // And it is kept, so the next connection does not ask.
    expect(Directory('${storage.path}/definitions').listSync(), hasLength(1));
  });

  test('says so when rusefi.com cannot be reached', () async {
    offline = true;
    await start(FakeRusEfi.fromDefinition(rusEfi));
    expect(connected().definitionProblem, contains('Could not reach'));
  });

  test('a Speeduino is matched against the definition FoxTune ships', () async {
    await start(
      FakeSpeeduino(
        signature: speeduino.identity.signature!,
        pageSizes: speeduino.constants.pageSizes,
      ),
    );
    final state = connected();
    expect(state.signatureStatus, SignatureStatus.matched);
    expect(state.definitionSource, DefinitionSource.bundled);
    // Speeduino signatures are not downloaded.
    expect(fetched, isEmpty);
  });

  test('a Speeduino on another release reads through the shipped definition, '
      'read-only', () async {
    await start(
      FakeSpeeduino(
        signature: 'speeduino 202501',
        pageSizes: speeduino.constants.pageSizes,
      ),
    );
    final state = connected();
    expect(state.signatureStatus, SignatureStatus.mismatched);
    expect(state.definition, same(speeduino));
    expect(state.definitionProblem, isNotNull);
  });
}
