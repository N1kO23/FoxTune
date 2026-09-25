@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show crc32;
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Sensor calibrations made from the shipped Speeduino definition's own
/// thermistors, formulas and generators.
void main() {
  late IniReferenceTable thermistors;
  late IniReferenceTable afr;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    final doc =
        IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
    thermistors = doc.referenceTables!.tableNamed('std_ms2gentherm')!;
    afr = doc.referenceTables!.tableNamed('std_ms2geno2')!;
  });

  IniThermistor named(String name) =>
      thermistors.thermistors.firstWhere((t) => t.name == name);

  group('a thermistor curve', () {
    test('passes through the three points it is fitted to', () {
      final curve = ThermistorCurve.fit(named('GM').points);
      expect(curve.celsiusAt(100700), closeTo(-40, 1e-6));
      expect(curve.celsiusAt(2238), closeTo(30, 1e-6));
      expect(curve.celsiusAt(177), closeTo(99, 1e-6));
    });

    test('fits every thermistor the definition offers', () {
      for (final thermistor in thermistors.thermistors) {
        expect(
          () => ThermistorCurve.fit(thermistor.points),
          returnsNormally,
          reason: thermistor.name,
        );
      }
    });

    test('refuses points no thermistor could have', () {
      expect(
        () => ThermistorCurve.fit([
          (celsius: -40, ohms: 1000),
          (celsius: 30, ohms: 2000),
          (celsius: 99, ohms: 3000),
        ]),
        throwsArgumentError,
        reason: 'resistance rising with temperature',
      );
      expect(
        () => ThermistorCurve.fit([
          (celsius: 30, ohms: 2000),
          (celsius: 30, ohms: 1000),
          (celsius: 99, ohms: 100),
        ]),
        throwsArgumentError,
      );
      expect(
        () => ThermistorCurve.fit([(celsius: 30, ohms: 2000)]),
        throwsArgumentError,
      );
    });
  });

  group('a temperature table', () {
    late SensorCalibration gm;

    setUp(() {
      gm = SensorCalibration.thermistor(
        thermistors,
        target: 0,
        biasOhms: named('GM').biasOhms,
        curve: ThermistorCurve.fit(named('GM').points),
      );
    });

    test('has a value every 33 ADC steps, in degrees Fahrenheit', () {
      expect(gm.values, hasLength(32));
      expect(SensorCalibration.adcAt(thermistors, 31), 1023);
      expect(SensorCalibration.adcAt(thermistors, 16), 528);
      // 2490 ohms over 2656: 26.1 degrees Celsius.
      expect(gm.values[16], closeTo(79.064, 0.001));
      expect(gm.values[1], closeTo(257.5, 0.001));
    });

    test(
        "puts the coolant fallback where the sensor reads as open or "
        'shorted', () {
      expect(gm.fallbacks, {0, 31});
      expect(gm.values.first, 180);
      expect(gm.values.last, 180);

      final air = SensorCalibration.thermistor(
        thermistors,
        target: 1,
        biasOhms: named('GM').biasOhms,
        curve: ThermistorCurve.fit(named('GM').points),
      );
      expect(air.values.last, 70, reason: "the air sensor's own fallback");
    });

    test('is sent as tenths of a degree, two bytes each, low byte first', () {
      final bytes = gm.encode();
      expect(bytes, hasLength(64));
      expect(bytes.sublist(0, 2), [1800 & 0xFF, 1800 >> 8]);
      expect(bytes.sublist(32, 34), [791 & 0xFF, 791 >> 8]);
      expect(gm.crc, crc32(bytes));
    });

    test('keeps a sub-zero value signed', () {
      // Index 30 is -31.9 degrees Fahrenheit.
      final bytes = gm.encode();
      final raw = bytes[60] | (bytes[61] << 8);
      expect(raw.toSigned(16), -319);
    });
  });

  group('the AFR table', () {
    IniCalibrationSolution solution(String label) =>
        afr.solutions.firstWhere((s) => s.label == label);

    test("from a sensor's formula: a byte of AFR x 10 per ADC step", () {
      final table = SensorCalibration.formula(
        afr,
        target: 2,
        expression: solution('14Point7').expression!,
      );
      final bytes = table.encode();
      expect(bytes, hasLength(1024));
      expect(bytes.first, 100);
      expect(bytes[512], 150);
      expect(bytes.last, 200);
      expect(table.fallbacks, isEmpty);
    });

    test('from two points of a linear wideband, carried on beyond them', () {
      final line = afr.generatorOf('linearGenerator')!;
      final table = SensorCalibration.linear(
        afr,
        target: 2,
        voltsLow: line.xLow!,
        valueLow: line.yLow!,
        voltsHigh: line.xHigh!,
        valueHigh: line.yHigh!,
      );
      expect(table.values.first, closeTo(6.7, 1e-9));
      expect(table.values.last, closeTo(21.7, 1e-9));
      expect(table.encode().first, 67);
    });

    test('offers only the formulas it can work out', () {
      final usable = {
        for (final s in afr.solutions)
          if (s.expression != null && SensorCalibration.canUse(s.expression!))
            s.label,
      };
      expect(usable, contains('14Point7'));
      expect(usable, contains('Innovate LC-1 / LC-2 Default'));
      expect(usable, isNot(contains(' ')), reason: 'the blank first row');
      expect(usable, isNot(contains('Narrowband')), reason: 'needs nb.inc');
    });
  });
}
