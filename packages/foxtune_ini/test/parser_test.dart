import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

IniDocument parse(String source, {Set<String> defined = const {}}) =>
    IniParser(defined: defined).parse(source);

void main() {
  group('identity', () {
    test('reads signature and commands from [MegaTune]', () {
      final doc = parse('''
[MegaTune]
   MTversion      = 2.25
   queryCommand   = "Q"
   signature      = "speeduino 202504-dev"
   versionInfo    = "S" ;shown to the user

[TunerStudio]
   iniSpecVersion = 3.64
''');
      expect(doc.identity.signature, 'speeduino 202504-dev');
      expect(doc.identity.queryCommand, 'Q');
      expect(doc.identity.versionInfo, 'S');
      expect(doc.identity.mtVersion, '2.25');
      expect(doc.identity.iniSpecVersion, '3.64');
    });

    test('matches a reported signature exactly, and rejects a mismatch', () {
      final doc = parse('[MegaTune]\nsignature = "speeduino 202504-dev"');
      expect(doc.matchesSignature('speeduino 202504-dev'), isTrue);
      expect(doc.matchesSignature('  speeduino 202504-dev  '), isTrue);
      expect(doc.matchesSignature('speeduino 202207'), isFalse);
      expect(doc.matchesSignature(''), isFalse);
    });

    test('treats an absent signature as no match, never a wildcard', () {
      // Writing to an ECU we cannot identify must never be allowed.
      final doc = parse('[MegaTune]\nqueryCommand = "Q"');
      expect(doc.matchesSignature('anything'), isFalse);
    });
  });

  group('constants header', () {
    test('applies last-write-wins across preprocessor branches', () {
      const source = '''
[Constants]
#if mcu_stm32
blockingFactor = 121
#else
blockingFactor = 251
#endif
#if COMMS_COMPAT
blockingFactor = 121
#endif
''';
      expect(parse(source).constants.blockingFactor, 251);
      expect(
          parse(source, defined: {'mcu_stm32'}).constants.blockingFactor, 121);
      // Both assignments survive; the later one must win.
      expect(parse(source, defined: {'COMMS_COMPAT'}).constants.blockingFactor,
          121);
    });

    test('parses page sizes and command templates as lists', () {
      final doc = parse('''
[Constants]
endianness      = little
nPages          = 3
pageSize        = 128, 288, 256
pageReadCommand = "p%2i%2o%2c", "p%2i%2o%2c", "p%2i%2o%2c"
burnCommand     = "b%2i", "b%2i", "b%2i"
''');
      expect(doc.constants.pageSizes, [128, 288, 256]);
      expect(doc.constants.pageCount, 3);
      expect(doc.constants.endianness, 'little');
      expect(doc.constants.pageReadCommands, everyElement('p%2i%2o%2c'));
      expect(doc.constants.burnCommands.first, 'b%2i');
    });
  });

  group('field declarations', () {
    test('parses a scalar with an offset and bounds', () {
      final doc = parse('''
[Constants]
page = 1
  aseTaperTime = scalar, U08, 0, "S", 0.1, 0.0, 0.0, 25.5, 1
''');
      final field = doc.constants.pages.single.fieldNamed('aseTaperTime');
      expect(field, isA<IniScalarField>());
      final scalar = field! as IniScalarField;
      expect(scalar.offset, 0);
      expect(scalar.type, IniDataType.u08);
      expect(scalar.units, 'S');
      expect(scalar.scale, const IniLiteral(0.1));
      expect(scalar.high, const IniLiteral(25.5));
      expect(scalar.digits, 1);
      expect(scalar.sizeInBytes, 1);
    });

    test('converts raw values to display units', () {
      final doc = parse('''
[Constants]
page = 1
  clt = scalar, U08, 0, "C", 1.0, -40.0, -40, 215, 0
''');
      final clt =
          doc.constants.pages.single.fieldNamed('clt')! as IniScalarField;
      expect(clt.toDisplay(60), -40 + 60);
      expect(clt.toDisplay(0), -40);
    });

    test('preserves an unevaluated expression instead of guessing', () {
      final doc = parse('''
[PcVariables]
  wueAFR = array, S16, [10], "Lambda", { 0.1 / stoich }, 0.000, -0.300, 0.300, 3
''');
      final field = doc.pcVariables.single as IniArrayField;
      expect(field.scale, isA<IniExpression>());
      expect((field.scale as IniExpression).source, '0.1 / stoich');
      // A field whose scale cannot be resolved must not fabricate a reading.
      expect(field.offset, isNull);
    });

    test('omits the offset for [PcVariables], which have none', () {
      final doc = parse('''
[PcVariables]
  rpmhigh = scalar, U16, "rpm", 1, 0, 0, 30000, 0
''');
      final field = doc.pcVariables.single as IniScalarField;
      expect(field.offset, isNull);
      expect(field.units, 'rpm');
      expect(field.type, IniDataType.u16);
      expect(field.high, const IniLiteral(30000));
    });

    test('parses bits with a range and labels', () {
      final doc = parse('''
[Constants]
page = 1
  aeMode = bits, U08, 3, [0:1], "TPS", "MAP", "INVALID", "INVALID"
''');
      final bits =
          doc.constants.pages.single.fieldNamed('aeMode')! as IniBitsField;
      expect(bits.offset, 3);
      expect(bits.lowBit, 0);
      expect(bits.highBit, 1);
      expect(bits.bitCount, 2);
      expect(bits.valueCount, 4);
      expect(bits.options, ['TPS', 'MAP', 'INVALID', 'INVALID']);
      expect(bits.hasCompleteOptions, isTrue);
      expect(bits.labelFor(1), 'MAP');
      expect(bits.labelFor(9), isNull);
    });

    test('parses an [OutputChannels] flag that declares no labels', () {
      final doc = parse('''
[OutputChannels]
  ochGetCommand = "r\\\$tsCanId\\x30%2o%2c"
  ochBlockSize  = 139
  inj1Status    = bits, U08, 1, [0:0]
''');
      final bits = doc.outputChannels.channels.single as IniBitsField;
      expect(bits.offset, 1);
      expect(bits.lowBit, 0);
      expect(bits.options, isEmpty);
      expect(doc.outputChannels.blockSize, 139);
    });

    test('expands a \$define reference in a bits option list', () {
      final doc = parse('''
#define loadSourceNames = "MAP", "TPS", "IMAP/EMAP"
[Constants]
page = 1
  algorithm = bits, U08, 0, [0:2], \$loadSourceNames
''');
      final bits =
          doc.constants.pages.single.fieldNamed('algorithm')! as IniBitsField;
      expect(bits.options, ['MAP', 'TPS', 'IMAP/EMAP']);
      // Three labels for a 3-bit field is short of the 8 possible values.
      expect(bits.hasCompleteOptions, isFalse);
    });

    test('parses 1D and 2D arrays and computes their size', () {
      final doc = parse('''
[Constants]
page = 1
  wueRates = array, U08, 4, [10], "%", 1.0, 0.0, 0.0, 255, 0
  veTable  = array, U08, 20, [16x16], "%", 1.0, 0.0, 0.0, 255, 0
  bigBins  = array, S16, 300, [8], "deg", 0.1, 0.0, 0.0, 100, 1
''');
      final page = doc.constants.pages.single;
      final wue = page.fieldNamed('wueRates')! as IniArrayField;
      expect(wue.shape, [10]);
      expect(wue.length, 10);
      expect(wue.isTable, isFalse);
      expect(wue.sizeInBytes, 10);

      final ve = page.fieldNamed('veTable')! as IniArrayField;
      expect(ve.shape, [16, 16]);
      expect(ve.length, 256);
      expect(ve.isTable, isTrue);
      expect(ve.sizeInBytes, 256);

      // S16 is two bytes wide, so size is element count times width.
      expect((page.fieldNamed('bigBins')! as IniArrayField).sizeInBytes, 16);
    });

    test('lastOffset aliases the previous field rather than appending', () {
      // Both representations describe the SAME byte: the file offers a value
      // as AFR or as Lambda depending on the user's units. Appending instead
      // would place ego_min_lambda on top of ego_max_afr.
      final doc = parse('''
[Constants]
page = 1
  ego_min_afr    = scalar, U08,          8, "AFR",    0.1, 0, 7, 25, 1
  ego_min_lambda = scalar, U08, lastOffset, "Lambda", 0.1, 0, 7, 25, 3
  ego_max_afr    = scalar, U08,          9, "AFR",    0.1, 0, 7, 25, 1
''');
      final page = doc.constants.pages.single;
      expect(page.fieldNamed('ego_min_afr')!.offset, 8);
      expect(page.fieldNamed('ego_min_lambda')!.offset, 8);
      expect(page.fieldNamed('ego_max_afr')!.offset, 9);
    });

    test('lastOffset works for arrays, keeping the alias at the same base', () {
      final doc = parse('''
[Constants]
page = 5
  lambdaTable = array, U08,          0, [16x16], "Lambda", 0.1, 0, 0, 2, 3
  afrTable    = array, U08, lastOffset, [16x16], "AFR",    0.1, 0, 7, 25.5, 1
  rpmBinsAFR  = array, U08,        256, [16],    "RPM",    100, 0, 100, 25500, 0
''');
      final page = doc.constants.pages.single;
      expect(page.fieldNamed('lambdaTable')!.offset, 0);
      expect(page.fieldNamed('afrTable')!.offset, 0);
      expect(page.fieldNamed('rpmBinsAFR')!.offset, 256);
      // The alias must not consume its own 256 bytes on top of the original.
      expect(page.extent, 272);
    });

    test('rejects lastOffset with no preceding field', () {
      expect(
        () => parse('''
[Constants]
page = 1
  orphan = scalar, U08, lastOffset, "", 1, 0
'''),
        throwsA(isA<IniParseException>()),
      );
    });

    test('rejects an unknown data type rather than shifting every offset', () {
      expect(
        () => parse('[Constants]\npage = 1\n  x = scalar, U99, 0, "", 1, 0'),
        throwsA(isA<IniParseException>()),
      );
    });
  });

  group('pages', () {
    test('groups fields under their page and computes extent', () {
      final doc = parse('''
[Constants]
page = 1
  a = scalar, U08, 0, "", 1, 0
  b = scalar, U16, 1, "", 1, 0
page = 2
  c = scalar, U08, 0, "", 1, 0
''');
      expect(doc.constants.pages, hasLength(2));
      expect(doc.constants.pages[0].number, 1);
      expect(doc.constants.pages[0].fields, hasLength(2));
      // b is U16 at offset 1, so the page reaches byte 3.
      expect(doc.constants.pages[0].extent, 3);
      expect(doc.constants.pages[1].number, 2);
    });

    test('finds a field across pages', () {
      final doc = parse('''
[Constants]
page = 1
  a = scalar, U08, 0, "", 1, 0
page = 2
  target = scalar, U08, 5, "", 1, 0
''');
      final hit = doc.constants.findField('target');
      expect(hit, isNotNull);
      expect(hit!.page.number, 2);
      expect(hit.field.offset, 5);
      expect(doc.constants.findField('nope'), isNull);
    });
  });

  group('tables and curves', () {
    test('parses a table block with its axes', () {
      final doc = parse('''
[TableEditor]
   table = veTable1Tbl, veTable1Map, "VE Table", 2
      topicHelp   = "http://wiki.speeduino.com/en/configuration/VE_table"
      xBins       = rpmBins, rpm
      yBins       = fuelLoadBins, fuelLoad
      xyLabels    = "RPM", "Fuel Load: "
      zBins       = veTable
      gridHeight  = 2.0
      gridOrient  = 250, 0, 340
      upDownLabel = "(RICHER)", "(LEANER)"
''');
      final table = doc.tableNamed('veTable1Tbl');
      expect(table, isNotNull);
      expect(table!.mapId, 'veTable1Map');
      expect(table.title, 'VE Table');
      expect(table.page, 2);
      expect(table.xBins.constant, 'rpmBins');
      expect(table.xBins.channel, 'rpm');
      expect(table.yBins.constant, 'fuelLoadBins');
      expect(table.zBins, 'veTable');
      expect(table.xyLabels, ['RPM', 'Fuel Load: ']);
      expect(table.gridHeight, 2.0);
      expect(table.gridOrient, [250.0, 0.0, 340.0]);
    });

    test('keeps consecutive table blocks separate', () {
      final doc = parse('''
[TableEditor]
   table = first, firstMap, "First", 2
      zBins = aTable
   table = second, secondMap, "Second", 11
      zBins = bTable
''');
      expect(doc.tables, hasLength(2));
      expect(doc.tableNamed('first')!.zBins, 'aTable');
      expect(doc.tableNamed('second')!.zBins, 'bTable');
      expect(doc.tableNamed('second')!.page, 11);
    });

    test('parses a curve block', () {
      final doc = parse('''
[CurveEditor]
   curve = dwell_correction_curve, "Dwell voltage correction"
       columnLabel = "Voltage", "Dwell"
       xAxis = 6, 22, 6
       yAxis = 0, 255, 6
       xBins = brvBins, batteryVoltage
       yBins = dwellRates
''');
      final curve = doc.curveNamed('dwell_correction_curve');
      expect(curve, isNotNull);
      expect(curve!.title, 'Dwell voltage correction');
      expect(curve.columnLabels, ['Voltage', 'Dwell']);
      expect(curve.xAxis, [6.0, 22.0, 6.0]);
      expect(curve.xBins.channel, 'batteryVoltage');
      expect(curve.yBins.constant, 'dwellRates');
      expect(curve.yBins.channel, isNull);
    });
  });

  group('setting groups', () {
    test('collects groups with their options', () {
      final doc = parse('''
[SettingGroups]
   settingGroup  = mcu, "Controller in use"
   settingOption = DEFAULT, "Arduino Mega 2560"
   settingOption = mcu_teensy, "Teensy"
   settingOption = mcu_stm32, "STM32"
''');
      final group = doc.settingGroups.single;
      expect(group.name, 'mcu');
      expect(group.label, 'Controller in use');
      expect(group.options, hasLength(3));
      // DEFAULT is a sentinel, not a symbol that gets defined.
      expect(group.selectableSymbols, ['mcu_teensy', 'mcu_stm32']);
    });
  });

  group('unmodelled sections', () {
    test('are retained verbatim rather than dropped', () {
      final doc = parse('''
[Tools]
   addTool = veTableGenerator, "VE Table Generator", veTable1Tbl
[Constants]
page = 1
  a = scalar, U08, 0, "", 1, 0
''');
      expect(doc.rawSections.containsKey('Tools'), isTrue);
      expect(doc.rawSections['Tools']!.lines, hasLength(1));
      expect(doc.rawSections.containsKey('Constants'), isFalse);
    });
  });
}
