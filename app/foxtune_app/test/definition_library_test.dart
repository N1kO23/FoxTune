import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

/// The collection of definitions: what is kept, how it is listed, and what
/// may be added.
void main() {
  late String speeduinoSource;
  late IniDocument speeduino;

  setUpAll(() {
    speeduinoSource = File('assets/speeduino.ini').readAsStringSync();
    speeduino = IniParser(defined: {'CELSIUS'}).parse(speeduinoSource);
  });

  late Directory storage;
  late DefinitionLibrary library;

  setUp(() {
    storage = Directory.systemTemp.createTempSync('foxtune_definitions');
    library = DefinitionLibrary(
      bundled: () async => speeduino,
      bundledSource: () async => speeduinoSource,
      storage: () async => storage,
      fetch: (url) async => null,
      symbols: {'CELSIUS'},
    );
  });

  tearDown(() => storage.deleteSync(recursive: true));

  Directory folder() => Directory('${storage.path}/definitions');

  /// A definition that reads, declaring [signature].
  String definitionFor(String signature) =>
      speeduinoSource.replaceFirst('"speeduino 202504-dev"', '"$signature"');

  Future<List<DefinitionEntry>> kept() async =>
      (await library.list()).where((entry) => !entry.isBuiltIn).toList();

  group('speeduinoRelease', () {
    const versions = ['202501.7', '202402.2', '202310', '201902b', 'master'];

    test('a release is the newest point release of its month', () {
      expect(speeduinoRelease('speeduino 202501', versions), '202501.7');
      expect(speeduinoRelease('speeduino 202310', versions), '202310');
      expect(
        speeduinoRelease('speeduino 202501', ['202501.2', '202501.10']),
        '202501.10',
      );
    });

    test('a development build, or a release not listed, is none', () {
      expect(speeduinoRelease('speeduino 202504-dev', versions), isNull);
      expect(speeduinoRelease('speeduino 202207', versions), isNull);
      expect(
        speeduinoRelease('rusEFI master.2026.09.21.x.1', versions),
        isNull,
      );
    });
  });

  test('the built-in definition is listed first, alone at first', () async {
    final entries = await library.list();
    expect(entries, hasLength(1));
    expect(entries.single.isBuiltIn, isTrue);
    expect(entries.single.source, DefinitionSource.bundled);
    expect(entries.single.signature, 'speeduino 202504-dev');
    expect(utf8.decode(await library.bytesOf(entries.single)), speeduinoSource);
  });

  test('an added definition is kept with a note of where it came from, and '
      'a connection finds it', () async {
    final source = definitionFor('speeduino 202501');
    final added = await library.add(source, fileName: 'speeduino.ini');

    expect(added.signature, 'speeduino 202501');
    expect(added.source, DefinitionSource.picked);
    expect(added.fileName, 'speeduino.ini');
    expect(added.added, isNotNull);
    expect(File('${folder().path}/speeduino_202501.json').existsSync(), isTrue);

    final listed = await kept();
    expect(listed.single.signature, 'speeduino 202501');
    expect(listed.single.fileName, 'speeduino.ini');
    expect(utf8.decode(await library.bytesOf(listed.single)), source);

    final lookup = await library.find(
      const EcuIdentification(signature: 'speeduino 202501', version: ''),
      download: false,
    );
    expect(lookup, isA<DefinitionFound>());
    expect((lookup as DefinitionFound).source, DefinitionSource.cached);
  });

  test('refuses what could never be matched, or is built in', () async {
    await expectLater(
      library.add('[MegaTune]\n   MTversion = 2.25\n', fileName: 'a.ini'),
      throwsA(isA<DefinitionRefusedException>()),
    );
    await expectLater(
      library.add(speeduinoSource, fileName: 'speeduino.ini'),
      throwsA(isA<DefinitionRefusedException>()),
    );
    expect(await kept(), isEmpty);
  });

  test('replaces a kept definition only when told to', () async {
    await library.add(definitionFor('speeduino 202501'), fileName: 'old.ini');
    await expectLater(
      library.add(definitionFor('speeduino 202501'), fileName: 'new.ini'),
      throwsA(isA<DefinitionExistsException>()),
    );
    expect((await kept()).single.fileName, 'old.ini');

    await library.add(
      definitionFor('speeduino 202501'),
      fileName: 'new.ini',
      replace: true,
    );
    expect((await kept()).single.fileName, 'new.ini');
  });

  test('lists the most recently kept first', () async {
    await library.add(definitionFor('speeduino 202402'), fileName: 'a.ini');
    await library.add(definitionFor('speeduino 202501'), fileName: 'b.ini');
    // Written a moment apart, but the order has to hold regardless.
    final older = File('${folder().path}/speeduino_202402.json');
    final note = jsonDecode(older.readAsStringSync()) as Map<String, Object?>;
    older.writeAsStringSync(
      jsonEncode({...note, 'added': '2020-01-01T00:00:00.000'}),
    );

    expect((await kept()).map((entry) => entry.signature), [
      'speeduino 202501',
      'speeduino 202402',
    ]);
  });

  test('removing deletes the definition and its note', () async {
    await library.add(definitionFor('speeduino 202501'), fileName: 'a.ini');
    await library.remove((await kept()).single);
    expect(await kept(), isEmpty);
    expect(folder().listSync(), isEmpty);
    await expectLater(
      library.remove((await library.list()).first),
      throwsArgumentError,
    );
  });

  group('a definition kept before notes were written', () {
    test('is read for its signature once, and noted', () async {
      folder().createSync(recursive: true);
      File('${folder().path}/speeduino_202501.ini')
          .writeAsStringSync(definitionFor('speeduino 202501'));

      final entry = (await kept()).single;
      expect(entry.signature, 'speeduino 202501');
      expect(entry.source, DefinitionSource.cached);
      expect(entry.problem, isNull);
      expect(
        File('${folder().path}/speeduino_202501.json').existsSync(),
        isTrue,
      );
    });

    test('under a name no connection would look for, is moved to it', () async {
      folder().createSync(recursive: true);
      File('${folder().path}/downloaded copy.ini')
          .writeAsStringSync(definitionFor('speeduino 202501'));

      final entry = (await kept()).single;
      expect(entry.file!.path, '${folder().path}/speeduino_202501.ini');
      expect(entry.problem, isNull);
    });

    test('that cannot be read is listed, to be removed', () async {
      folder().createSync(recursive: true);
      File('${folder().path}/junk.ini').writeAsStringSync('not a definition');

      final entry = (await kept()).single;
      expect(entry.signature, isNull);
      expect(entry.name, 'junk.ini');
      expect(entry.problem, isNotNull);

      await library.remove(entry);
      expect(await kept(), isEmpty);
    });
  });
}
