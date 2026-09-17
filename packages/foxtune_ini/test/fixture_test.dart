@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Guards the bundled `speeduino.ini` fixture.
///
/// The parser's golden tests in M1 assert against this file, so these checks
/// exist to make a missing or truncated fixture fail loudly and early rather
/// than as a confusing parser error.
void main() {
  late File fixture;

  setUpAll(() {
    fixture = File('packages/foxtune_ini/test/fixtures/speeduino.ini');
    if (!fixture.existsSync()) {
      // Fall back to a path relative to the package, for IDE test runners.
      fixture = File('test/fixtures/speeduino.ini');
    }
  });

  group('speeduino.ini fixture', () {
    test('is present and substantial', () {
      expect(fixture.existsSync(), isTrue,
          reason: 'fixture missing at ${fixture.path}');
      expect(fixture.lengthSync(), greaterThan(100000));
    });

    test('declares the sections the parser must model', () {
      final text = fixture.readAsStringSync();
      for (final section in const [
        '[MegaTune]',
        '[TunerStudio]',
        '[SettingGroups]',
        '[Constants]',
        '[OutputChannels]',
        '[TableEditor]',
        '[CurveEditor]',
        '[PcVariables]',
      ]) {
        expect(text, contains(section), reason: 'missing $section');
      }
    });

    test('carries the protocol keys the transport layer depends on', () {
      final text = fixture.readAsStringSync();
      expect(text, contains('queryCommand'));
      expect(text, contains('signature'));
      expect(text, contains('blockingFactor'));
      expect(text, contains('pageReadCommand'));
      expect(text, contains('ochGetCommand'));
    });

    test('uses the preprocessor the parser has to implement', () {
      final lines = fixture.readAsLinesSync();
      final directives =
          lines.map((l) => l.trim()).where((l) => l.startsWith('#')).toList();

      // A parser that ignores these produces wrong page offsets, which is the
      // difference between a working tune and a damaged engine.
      expect(directives.where((d) => d.startsWith('#if')), isNotEmpty);
      expect(directives.where((d) => d.startsWith('#else')), isNotEmpty);
      expect(directives.where((d) => d.startsWith('#endif')), isNotEmpty);
      expect(directives.where((d) => d.startsWith('#define')), isNotEmpty);
    });
  });
}
