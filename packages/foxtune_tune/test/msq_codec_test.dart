@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

const _source = '''
[MegaTune]
signature = "speeduino 202504-dev"
[Constants]
endianness = little
nPages     = 1
pageSize   = 64
page = 1
  aScalar = scalar, U08, 0,  "S",  0.1, 0.0, 0.0, 25.5, 1
  aSigned = scalar, S08, 1,  "deg", 1.0, -40.0, -40.0, 70.0, 0
  mode    = bits,   U08, 2, [0:1], "TPS", "MAP", "IMAP", "OTHER"
  flag    = bits,   U08, 2, [2:2], "Off", "On"
  aList   = array,  U08, 3, [4],   "%", 1.0, 0.0, 0.0, 255.0, 0
  aTable  = array,  U08, 8, [3x3], "%", 1.0, 0.0, 0.0, 255.0, 0
''';

IniDocument get definition => IniParser().parse(_source);

TuneState populated() {
  final tune = TuneState.empty(definition);
  void write(String name, int value, [int index = 0]) {
    final f = tune.locate(name)!;
    tune.writeRaw(f.page, f.field, value, index);
  }

  write('aScalar', 123); // 12.3 s
  write('aSigned', 62); // 22 deg after translate -40
  // mode = MAP (1), flag = On (1) -> byte 2 = 0b101 = 5
  write('mode', 5);
  for (var i = 0; i < 4; i++) {
    write('aList', 10 * (i + 1), i);
  }
  for (var i = 0; i < 9; i++) {
    write('aTable', i + 1, i);
  }
  tune.markClean();
  return tune;
}

void main() {
  group('encode', () {
    late XmlDocument doc;

    setUpAll(() => doc = XmlDocument.parse(MsqCodec.encode(populated())));

    test('writes the expected document shape', () {
      expect(doc.rootElement.name.local, 'msq');
      expect(doc.rootElement.getAttribute('xmlns'), MsqCodec.namespace);
      expect(doc.findAllElements('bibliography'), hasLength(1));
      expect(doc.findAllElements('versionInfo'), hasLength(1));
    });

    test('records the signature so a mismatch can be caught on load', () {
      final version = doc.findAllElements('versionInfo').single;
      expect(version.getAttribute('signature'), 'speeduino 202504-dev');
      expect(version.getAttribute('nPages'), '1');
      expect(version.getAttribute('fileFormat'), MsqCodec.fileFormat);
    });

    test('writes the page with its number and size', () {
      final page = doc
          .findAllElements('page')
          .firstWhere((p) => p.getAttribute('number') != null);
      expect(page.getAttribute('number'), '1');
      expect(page.getAttribute('size'), '64');
    });

    XmlElement constant(String name) => doc
        .findAllElements('constant')
        .firstWhere((e) => e.getAttribute('name') == name);

    test('writes scalars in engineering units to the declared precision', () {
      expect(constant('aScalar').innerText.trim(), '12.3');
      expect(constant('aScalar').getAttribute('units'), 'S');
      expect(constant('aScalar').getAttribute('digits'), '1');
    });

    test('applies translate to signed values', () {
      expect(constant('aSigned').innerText.trim(), '22');
    });

    test('writes bits as their quoted option label', () {
      expect(constant('mode').innerText.trim(), '"MAP"');
      expect(constant('flag').innerText.trim(), '"On"');
    });

    test('writes a 1D array one value per row', () {
      final list = constant('aList');
      expect(list.getAttribute('cols'), '1');
      expect(list.getAttribute('rows'), '4');
      final values = list.innerText.trim().split(RegExp(r'\s+'));
      expect(values, hasLength(4));
    });

    test('writes a 2D table highest-Y row first, as TunerStudio displays it',
        () {
      final table = constant('aTable');
      expect(table.getAttribute('cols'), '3');
      expect(table.getAttribute('rows'), '3');

      final rows = table.innerText
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(rows, hasLength(3));
      // Stored row 2 is [7,8,9] and is the highest Y, so it comes first.
      expect(rows.first.split(RegExp(r'\s+')), ['7', '8', '9']);
      expect(rows.last.split(RegExp(r'\s+')), ['1', '2', '3']);
    });
  });

  group('round trip', () {
    test('restores every value exactly', () {
      final original = populated();
      final xml = MsqCodec.encode(original);

      final restored = TuneState.empty(definition);
      final result = MsqCodec.decode(xml, restored);

      expect(result.applied, greaterThan(0));
      expect(result.skipped, isEmpty);
      expect(result.unknown, isEmpty);
      expect(restored.page(1), original.page(1),
          reason: 'a round trip must be byte-identical');
    });

    test('survives a second round trip unchanged', () {
      final original = populated();
      final once = TuneState.empty(definition);
      MsqCodec.decode(MsqCodec.encode(original), once);
      final twice = TuneState.empty(definition);
      MsqCodec.decode(MsqCodec.encode(once), twice);

      expect(twice.page(1), once.page(1));
    });

    test('preserves neighbouring bits packed into the same byte', () {
      // mode and flag share byte 2; loading one must not clear the other.
      final original = populated();
      final restored = TuneState.empty(definition);
      MsqCodec.decode(MsqCodec.encode(original), restored);

      expect(restored.page(1)[2], original.page(1)[2]);
    });

    test('marks the tune dirty, since it now differs from the ECU', () {
      final restored = TuneState.empty(definition);
      MsqCodec.decode(MsqCodec.encode(populated()), restored);
      expect(restored.isDirty, isTrue);
    });
  });

  group('decode safety', () {
    test('refuses a tune for a different firmware', () {
      // Loading it would put values at the wrong offsets.
      final xml = MsqCodec.encode(populated())
          .replaceAll('speeduino 202504-dev', 'speeduino 202207');
      expect(() => MsqCodec.decode(xml, TuneState.empty(definition)),
          throwsA(isA<MsqException>()));
    });

    test('can be told to load a mismatched tune anyway', () {
      final xml = MsqCodec.encode(populated())
          .replaceAll('speeduino 202504-dev', 'speeduino 202207');
      final tune = TuneState.empty(definition);
      final result = MsqCodec.decode(xml, tune, requireSignatureMatch: false);
      expect(result.signature, 'speeduino 202207');
      expect(result.applied, greaterThan(0));
    });

    test('rejects a file with no signature when matching is required', () {
      final xml = MsqCodec.encode(populated())
          .replaceAll('signature="speeduino 202504-dev"', '');
      expect(() => MsqCodec.decode(xml, TuneState.empty(definition)),
          throwsA(isA<MsqException>()));
    });

    test('reports names the definition does not declare', () {
      final xml = MsqCodec.encode(populated()).replaceFirst(
          '<constant digits="1" name="aScalar"',
          '<constant digits="1" name="notAThing"');
      final result = MsqCodec.decode(xml, TuneState.empty(definition));
      expect(result.unknown, contains('notAThing'));
      expect(result.isClean, isFalse);
    });

    test('rejects a non-XML document', () {
      expect(() => MsqCodec.decode('not xml', TuneState.empty(definition)),
          throwsA(isA<MsqException>()));
    });

    test('rejects XML that is not an msq', () {
      expect(
        () => MsqCodec.decode('<other/>', TuneState.empty(definition)),
        throwsA(isA<MsqException>()),
      );
    });

    test('skips an array whose length does not match the definition', () {
      // A wrong-length table means the firmware layout differs; writing what
      // arrived would scatter values across the page.
      final xml = MsqCodec.encode(populated())
          .replaceFirst(RegExp(r'7 8 9\s*\n'), '7 8 9 10\n');
      final result = MsqCodec.decode(xml, TuneState.empty(definition));
      expect(result.skipped, contains('aTable'));
    });
  });

  group('against the real definition', () {
    late IniDocument real;

    setUpAll(() {
      final candidates = [
        File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
        File('../foxtune_ini/test/fixtures/speeduino.ini'),
      ];
      final fixture = candidates.firstWhere((f) => f.existsSync());
      real = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
    });

    test('round-trips a full 15-page Speeduino tune', () {
      final original = TuneState.empty(real);
      // Put recognisable data in the VE table and spark table.
      final ve = TableView.of(original, real.tableNamed('veTable1Tbl')!)!;
      final spark = TableView.of(original, real.tableNamed('sparkTbl')!)!;
      for (var r = 0; r < 16; r++) {
        for (var c = 0; c < 16; c++) {
          ve.setValueAt(r, c, (40 + r * 2 + c).toDouble());
          spark.setValueAt(r, c, (-10 + r + c).toDouble());
        }
      }

      final xml = MsqCodec.encode(original);
      final restored = TuneState.empty(real);
      final result = MsqCodec.decode(xml, restored);

      expect(result.unknown, isEmpty);
      final restoredVe =
          TableView.of(restored, real.tableNamed('veTable1Tbl')!)!;
      expect(restoredVe.valueAt(0, 0), ve.valueAt(0, 0));
      expect(restoredVe.valueAt(15, 15), ve.valueAt(15, 15));
      expect(restoredVe.toGrid(), ve.toGrid());

      final restoredSpark =
          TableView.of(restored, real.tableNamed('sparkTbl')!)!;
      expect(restoredSpark.toGrid(), spark.toGrid());
    });

    test('produces a document TunerStudio would recognise', () {
      final xml = MsqCodec.encode(TuneState.empty(real));
      final doc = XmlDocument.parse(xml);

      expect(doc.rootElement.name.local, 'msq');
      expect(doc.findAllElements('page').length, greaterThanOrEqualTo(15));
      expect(
          doc.findAllElements('versionInfo').single.getAttribute('signature'),
          startsWith('speeduino '));
    });
  });

  group('temperatures saved in the other scale', () {
    const source = '''
[MegaTune]
signature = "speeduino 202504-dev"
[Constants]
endianness = little
nPages     = 1
pageSize   = 16
page = 1
  minClt  = scalar, U08, 0,  "C",   1.0, -40.0, -40.0, 215.0, 0
  cltBins = array,  U08, 1, [4], "C", 1.0, -40.0, -40.0, 215.0, 0
  advance = scalar, U08, 5,  "deg", 1.0,   0.0,   0.0,  60.0, 0
''';
    final celsius = IniParser().parse(source);

    String msq(String constants) =>
        '''<?xml version="1.0" encoding="ISO-8859-1"?>
<msq xmlns="http://www.msefi.com/:msq">
<versionInfo fileFormat="5.0" signature="speeduino 202504-dev"/>
<page number="0">
$constants
</page>
</msq>''';

    /// [name]'s [count] values, lowest first. Each is a byte, offset by
    /// [translate] - every temperature here by 40, so it can go below zero.
    List<num> valuesOf(
      TuneState tune,
      String name,
      int count, {
      num translate = -40,
    }) {
      final located = tune.locate(name)!;
      return [
        for (var i = 0; i < count; i++)
          tune.readRaw(located.page, located.field, i)! + translate,
      ]..sort();
    }

    test('are converted on the way in, and said to be', () {
      final tune = TuneState.empty(celsius);
      final result = MsqCodec.decode(
        msq('''
<constant digits="0" name="minClt" units="F">140</constant>
<constant cols="1" digits="0" name="cltBins" rows="4" units="&#176;F">
  32 50 68 212
</constant>
<constant digits="0" name="advance" units="deg">20</constant>'''),
        tune,
      );

      expect(result.applied, 3);
      expect(result.converted, ['minClt', 'cltBins']);
      expect(result.isClean, isTrue);
      expect(valuesOf(tune, 'minClt', 1), [60]);
      expect(valuesOf(tune, 'cltBins', 4), [0, 10, 20, 100]);
      // Degrees of timing are no temperature.
      expect(valuesOf(tune, 'advance', 1, translate: 0), [20]);
    });

    test('in the same scale are left as they are', () {
      final tune = TuneState.empty(celsius);
      final result = MsqCodec.decode(
        msq('<constant digits="0" name="minClt" units="C">60</constant>'),
        tune,
      );
      expect(result.converted, isEmpty);
      expect(valuesOf(tune, 'minClt', 1), [60]);
    });

    test('with no units said are taken as they stand', () {
      final tune = TuneState.empty(celsius);
      final result = MsqCodec.decode(
        msq('<constant digits="0" name="minClt">60</constant>'),
        tune,
      );
      expect(result.converted, isEmpty);
      expect(valuesOf(tune, 'minClt', 1), [60]);
    });
  });
}
