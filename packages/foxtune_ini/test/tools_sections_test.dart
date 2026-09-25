@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

void main() {
  late IniDocument speeduino;
  late IniDocument rusEfi;

  String fixture(String name) => [
        File('packages/foxtune_ini/test/fixtures/$name'),
        File('test/fixtures/$name'),
      ].firstWhere((f) => f.existsSync()).readAsStringSync();

  setUpAll(() {
    speeduino = IniParser(
      defined: {'CELSIUS'},
    ).parse(fixture('speeduino.ini'));
    rusEfi = IniParser().parse(fixture('rusefi_uaefi.ini'));
  });

  group('Speeduino loggers', () {
    test('are the tooth logger and three composite ones', () {
      expect(speeduino.loggers.map((l) => l.id), [
        'tooth',
        'compositeLogger',
        'compositeLogger2',
        'compositeLogger3',
      ]);
      expect(speeduino.loggers.map((l) => l.kind), [
        IniLoggerKind.tooth,
        IniLoggerKind.composite,
        IniLoggerKind.composite,
        IniLoggerKind.composite,
      ]);
    });

    test('the tooth logger: its commands, and a 32-bit time a record', () {
      final tooth = speeduino.loggers.first;
      expect(tooth.label, 'Tooth Logger');
      expect(tooth.startCommand, 'H');
      expect(tooth.stopCommand, 'h');
      // The comment after the command is not part of it.
      expect(tooth.readCommand, r'T\$tsCanId\x01\xFC\x00\x01\xFC');
      expect(tooth.readyCondition, 'toothLog1Ready == 1');
      expect(tooth.readTimeout, const Duration(seconds: 5));
      expect(tooth.continuousRead, isTrue);
      expect(tooth.recordLength, 4);
      final time = tooth.fields.single;
      expect(
        (time.name, time.startBit, time.bitCount, time.units),
        ('toothTime', 0, 32, 'uS'),
      );
    });

    test('a composite record: flags in its last byte, the time before it', () {
      final composite = speeduino.loggers[1];
      expect((composite.startCommand, composite.stopCommand), ('J', 'j'));
      expect(composite.recordLength, 5);
      expect(
        [
          for (final f in composite.fields)
            if (f.isFlag) (f.name, f.startBit),
        ],
        [
          ('priLevel', 0),
          ('secLevel', 1),
          ('ThirdLevel', 2),
          ('trigger', 3),
          ('sync', 4),
          ('cycle', 5),
        ],
      );
      final time = composite.fieldNamed('refTime')!;
      expect((time.startBit, time.bitCount, time.scale), (8, 32, 0.001));
      final calcs = {for (final c in composite.calcs) c.name: c};
      expect(calcs['toothTime']!.expression, 'refTime - pastValue(refTime, 1)');
      expect(calcs['maxTime']!.hidden, isTrue);
      expect(calcs['time']!.hidden, isFalse);
    });

    test('are still kept raw as well', () {
      expect(speeduino.rawSections['LoggerDefinition']!.lines, isNotEmpty);
    });
  });

  group('Speeduino reference tables', () {
    test('are written with the t command, 256 bytes at a time', () {
      final tables = speeduino.referenceTables!;
      expect(tables.writeCommand, r't\$tsCanId%2i%2o%2c%v');
      expect(tables.blockingFactor, 256);
    });

    test('the thermistor tables: 32 shorts each, for two sensors', () {
      final therm = speeduino.referenceTables!.tableNamed('std_ms2gentherm')!;
      expect(therm.targets, [
        (id: 0, label: 'Coolant Temperature Sensor'),
        (id: 1, label: 'Air Temperature Sensor'),
      ]);
      expect(therm.limits[0], (min: -40.0, max: 350.0, fallback: 180.0));
      expect(therm.limits[1], (min: -40.0, max: 350.0, fallback: 70.0));
      expect(
        (therm.adcCount, therm.bytesPerAdc, therm.scale),
        (32, 2, 10.0),
      );
      final gm = therm.thermistors.firstWhere((t) => t.name == 'GM');
      expect(gm.biasOhms, 2490);
      expect(gm.points, [
        (celsius: -40.0, ohms: 100700.0),
        (celsius: 30.0, ohms: 2238.0),
        (celsius: 99.0, ohms: 177.0),
      ]);
      expect(therm.thermistors, hasLength(13));
      expect(therm.generatorOf('thermGenerator'), isNotNull);
    });

    test('the AFR table: 1024 bytes, from a formula or two points', () {
      final afr = speeduino.referenceTables!.tableNamed('std_ms2geno2')!;
      expect(afr.targets, [(id: 2, label: 'AFR Table')]);
      expect((afr.adcCount, afr.bytesPerAdc, afr.scale), (1024, 1, 10.0));
      expect(afr.solutionsLabel, 'EGO Sensor');
      final byName = {for (final s in afr.solutions) s.label: s};
      expect(
        byName['14Point7']!.expression,
        '10.0001 + ( adcValue * 0.0097752 )',
      );
      expect(byName['Custom Linear WB']!.generator, 'linearGenerator');
      expect(byName[' ']!.expression, isEmpty);
      final linear = afr.generatorOf('linearGenerator')!;
      expect(
        (linear.xUnits, linear.yUnits, linear.xLow, linear.xHigh),
        ('Volts', 'AFR', 1.0, 4.0),
      );
      expect((linear.yLow, linear.yHigh), (9.7, 18.7));
    });
  });

  group('rusEFI', () {
    test('has a composite logger of its own commands and 8-byte records', () {
      final composite = rusEfi.loggers.first;
      expect(composite.kind, IniLoggerKind.composite);
      expect(composite.startCommand, r'l\x01');
      expect(composite.readCommand, r'l\x03');
      expect(composite.readyCondition, 'toothLogReady');
      expect(composite.recordLength, 8);
      final time = composite.fieldNamed('refTime')!;
      expect((time.startBit, time.bitCount), (0, 32));
      expect(composite.fieldNamed('priLevel')!.startBit, 32);
    });

    test('calibrates its sensors through ordinary settings instead', () {
      expect(rusEfi.referenceTables, isNull);
    });
  });
}
