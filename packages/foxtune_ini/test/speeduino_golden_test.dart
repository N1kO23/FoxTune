@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

/// Golden tests against the real `speeduino.ini` shipped by the firmware.
///
/// The point of these is that the parser must survive the actual file, not a
/// simplified stand-in. Every assertion here is a property a tuning session
/// depends on being right.
void main() {
  late String source;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    source = fixture.readAsStringSync();
  });

  IniDocument parse({Set<String> defined = const {}}) =>
      IniParser(defined: defined).parse(source);

  group('speeduino.ini', () {
    test('parses without error under every documented build config', () {
      for (final config in const <Set<String>>[
        {},
        {'CELSIUS'},
        {'LAMBDA'},
        {'pressure_bar'},
        {'mcu_teensy'},
        {'mcu_stm32'},
        {'COMMS_COMPAT'},
        {'MSDROID_COMPAT'},
        {'resetcontrol_adv'},
        {'enablehardware_test'},
        {'CELSIUS', 'mcu_stm32', 'COMMS_COMPAT', 'LAMBDA'},
      ]) {
        expect(() => parse(defined: config), returnsNormally,
            reason: 'config: $config');
      }
    });

    test('reports the firmware signature', () {
      final doc = parse();
      expect(doc.identity.signature, startsWith('speeduino '));
      expect(doc.identity.queryCommand, 'Q');
      expect(doc.identity.versionInfo, 'S');
    });

    test('declares the expected 15 pages and their sizes', () {
      // From `pageSize` in the shipped reference file. A change here means the
      // firmware layout moved and the rest of FoxTune needs revisiting.
      const expected = <int>[
        128,
        288,
        288,
        128,
        288,
        128,
        240,
        384,
        192,
        192,
        288,
        192,
        128,
        288,
        256,
      ];
      final constants = parse().constants;
      expect(constants.pageSizes, expected);
      expect(constants.pageCount, 15);
      expect(constants.endianness, 'little');
    });

    test('parses one field block per declared page, numbered 1..15', () {
      final pages = parse().constants.pages;
      expect(pages, hasLength(15));
      expect(
          [for (final p in pages) p.number], List.generate(15, (i) => i + 1));
      for (final page in pages) {
        expect(page.fields, isNotEmpty, reason: 'page ${page.number} is empty');
      }
    });

    test('every field fits inside its declared page', () {
      // The strongest structural check available: if offsets, widths or array
      // shapes were misparsed, some field would spill past its page boundary.
      final constants = parse().constants;
      for (final page in constants.pages) {
        final declared = constants.pageSizes[page.number - 1];
        for (final field in page.fields) {
          final offset = field.offset;
          if (offset == null) continue;
          expect(offset + field.sizeInBytes, lessThanOrEqualTo(declared),
              reason: 'page ${page.number}: ${field.name} '
                  '(offset $offset, ${field.sizeInBytes} bytes) '
                  'overruns declared size $declared');
        }
      }
    });

    test('selects blockingFactor per build config, last write winning', () {
      expect(parse().constants.blockingFactor, 251);
      expect(parse(defined: {'mcu_stm32'}).constants.blockingFactor, 121);
      // COMMS_COMPAT reassigns after the mcu branch has already run.
      expect(parse(defined: {'COMMS_COMPAT'}).constants.blockingFactor, 121);
      expect(
          parse(defined: {'mcu_stm32', 'COMMS_COMPAT'})
              .constants
              .blockingFactor,
          121);
    });

    test('selects the burn command variant per build config', () {
      expect(parse().constants.burnCommands.first, 'b%2i');
      expect(parse(defined: {'COMMS_COMPAT'}).constants.burnCommands.first,
          'B%2i');
    });

    test('supplies one command template per page', () {
      final constants = parse().constants;
      for (final list in [
        constants.pageReadCommands,
        constants.pageWriteCommands,
        constants.burnCommands,
        constants.pageIdentifiers,
      ]) {
        expect(list, hasLength(constants.pageCount));
      }
      expect(constants.pageReadCommands.first, 'p%2i%2o%2c');
      expect(constants.pageWriteCommands.first, 'M%2i%2o%2c%v');
    });

    test('parses the realtime data block layout', () {
      final och = parse().outputChannels;
      expect(och.blockSize, 139);
      expect(och.getCommand, contains('%2o%2c'));
      expect(och.channels, isNotEmpty);

      // Spot-check channels a dashboard depends on.
      final rpm = och.channelNamed('rpm');
      expect(rpm, isA<IniScalarField>());
      expect((rpm! as IniScalarField).type, IniDataType.u16);

      final map = och.channelNamed('map')! as IniScalarField;
      expect(map.offset, 4);
      expect(map.type, IniDataType.u16);
      expect(map.units.toLowerCase(), 'kpa');
    });

    test('keeps every realtime channel inside the declared block size', () {
      final och = parse().outputChannels;
      for (final channel in och.channels) {
        final offset = channel.offset;
        if (offset == null) continue;
        expect(offset + channel.sizeInBytes, lessThanOrEqualTo(och.blockSize!),
            reason: '${channel.name} overruns ochBlockSize');
      }
    });

    test('parses the tuning tables with resolvable axes', () {
      final doc = parse();
      expect(doc.tables, isNotEmpty);

      final ve = doc.tableNamed('veTable1Tbl');
      expect(ve, isNotNull, reason: 'the primary VE table must be present');
      expect(ve!.zBins, 'veTable');
      expect(ve.xBins.constant, isNotEmpty);
      expect(ve.yBins.constant, isNotEmpty);

      // Every table's z constant must actually exist in the page definitions,
      // or the editor would have nothing to write to.
      for (final table in doc.tables) {
        expect(doc.constants.findField(table.zBins), isNotNull,
            reason: 'table ${table.id} references unknown zBins '
                '"${table.zBins}"');
      }
    });

    test('the VE table array matches its axis lengths', () {
      final doc = parse();
      final ve = doc.tableNamed('veTable1Tbl')!;
      final z = doc.constants.findField(ve.zBins)!.field as IniArrayField;
      final x =
          doc.constants.findField(ve.xBins.constant)!.field as IniArrayField;
      final y =
          doc.constants.findField(ve.yBins.constant)!.field as IniArrayField;

      expect(z.shape, [16, 16]);
      expect(x.length, 16);
      expect(y.length, 16);
      expect(z.length, x.length * y.length);
    });

    test('parses curves with resolvable bins', () {
      final doc = parse();
      expect(doc.curves, isNotEmpty);
      for (final curve in doc.curves) {
        // Bins resolve against page constants or PC variables - warmup AFR
        // uses the latter - so the document-wide lookup is the right one.
        expect(doc.findField(curve.yBins.constant), isNotNull,
            reason: 'curve ${curve.id} references unknown yBins '
                '"${curve.yBins.constant}"');
        expect(doc.findField(curve.xBins.constant), isNotNull,
            reason: 'curve ${curve.id} references unknown xBins '
                '"${curve.xBins.constant}"');
      }
    });

    test('parses the datalog column definitions', () {
      final datalog = parse().datalog;
      expect(datalog.length, greaterThan(100));

      // Order matters: the file says entries are written in the order listed.
      expect(datalog.first.channel, 'time');
      expect(datalog.first.label, 'Time');
      expect(datalog.first.type, IniDatalogType.float);
      expect(datalog.first.decimals, 3);

      final rpm = datalog.firstWhere((e) => e.channel == 'rpm');
      expect(rpm.label, 'RPM');
      expect(rpm.type, IniDatalogType.integer);
      expect(rpm.decimals, 0);
    });

    test('falls back to the channel name for an expression label', () {
      // Aliased auxiliary inputs name their column with stringValue(), which
      // cannot be resolved here.
      final datalog = parse().datalog;
      final aliased = datalog.where((e) => e.labelExpression != null).toList();
      expect(aliased, isNotEmpty);
      for (final entry in aliased) {
        expect(entry.label, entry.channel);
        expect(entry.labelExpression, contains('stringValue'));
      }
    });

    test('retains the condition that gates optional columns', () {
      final gated = parse().datalog.where((e) => e.condition != null).toList();
      expect(gated, isNotEmpty);
      expect(gated.first.condition, isNotEmpty);
    });

    test('every logged channel exists in the definition', () {
      final doc = parse();
      final names = doc.outputChannels.allNames;
      final missing = [
        for (final entry in doc.datalog)
          if (!names.contains(entry.channel)) entry.channel,
      ];
      expect(missing, isEmpty, reason: 'unknown log channels: $missing');
    });

    test('collects the build-configuration groups', () {
      final groups = parse().settingGroups;
      expect(groups, isNotEmpty);
      final mcu = groups.firstWhere((g) => g.name == 'mcu');
      expect(mcu.selectableSymbols, containsAll(['mcu_teensy', 'mcu_stm32']));
    });

    test('retains the UI sections verbatim instead of dropping them', () {
      final raw = parse().rawSections;
      expect(raw.keys, containsAll(['Menu', 'UserDefined', 'FrontPage']));
      expect(raw['Menu']!.lines, isNotEmpty);
    });

    test('CELSIUS changes units without moving offsets', () {
      // Unit selection must never shift the byte layout; only labels and
      // scaling change. If offsets moved, a tune written under one unit
      // setting would corrupt an ECU configured with the other.
      final metric = parse(defined: {'CELSIUS'}).constants;
      final imperial = parse().constants;

      for (var i = 0; i < metric.pages.length; i++) {
        final a = metric.pages[i];
        final b = imperial.pages[i];
        expect(a.fields.length, b.fields.length,
            reason: 'page ${a.number} field count differs');
        for (var f = 0; f < a.fields.length; f++) {
          expect(a.fields[f].name, b.fields[f].name);
          expect(a.fields[f].offset, b.fields[f].offset,
              reason: 'offset of ${a.fields[f].name} moved with CELSIUS');
        }
      }
    });
  });
}
