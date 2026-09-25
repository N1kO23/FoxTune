import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_catalog.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';

void main() {
  _temperatureUnitTests();
  group('GaugeSpec thresholds', () {
    const rpm = GaugeSpec(
      channel: 'rpm',
      label: 'RPM',
      units: 'rpm',
      min: 0,
      max: 8000,
      warnAbove: 6000,
      dangerAbove: 7000,
    );

    test('classifies an upper-bounded value', () {
      expect(rpm.statusFor(3000), GaugeStatus.normal);
      // On a limit is not past it.
      expect(rpm.statusFor(6000), GaugeStatus.normal);
      expect(rpm.statusFor(6001), GaugeStatus.warning);
      expect(rpm.statusFor(7000), GaugeStatus.warning);
      expect(rpm.statusFor(7001), GaugeStatus.danger);
      expect(rpm.statusFor(9000), GaugeStatus.danger);
    });

    test('treats an unavailable value as normal, not as an alarm', () {
      // A missing reading must not light up a false redline.
      expect(rpm.statusFor(null), GaugeStatus.normal);
    });

    const battery = GaugeSpec(
      channel: 'batteryVoltage',
      label: 'Battery',
      units: 'V',
      min: 8,
      max: 16,
      decimals: 1,
      warnBelow: 12.0,
      dangerBelow: 11.0,
      warnAbove: 15.0,
    );

    test('classifies a value whose failure mode is low', () {
      expect(battery.statusFor(13.8), GaugeStatus.normal);
      expect(battery.statusFor(12.0), GaugeStatus.normal);
      expect(battery.statusFor(11.9), GaugeStatus.warning);
      expect(battery.statusFor(11.0), GaugeStatus.warning);
      expect(battery.statusFor(10.9), GaugeStatus.danger);
    });

    test('handles limits at both ends', () {
      expect(battery.statusFor(15.2), GaugeStatus.warning);
    });

    test('danger wins over warning when both apply', () {
      expect(rpm.statusFor(7500), GaugeStatus.danger);
    });

    test('zero on a scale from zero is at rest, not too low', () {
      const pulse = GaugeSpec(
        channel: 'pulseWidth',
        label: 'PW',
        units: 'ms',
        min: 0,
        max: 35,
        dangerBelow: 1.0,
        warnBelow: 1.2,
        warnAbove: 20,
      );
      expect(pulse.statusFor(0), GaugeStatus.normal);
      expect(pulse.statusFor(0.5), GaugeStatus.danger);
      expect(pulse.statusFor(1.1), GaugeStatus.warning);
      // The same zero, on a scale that runs below it, is just a low reading.
      const offset = GaugeSpec(
        channel: 'x',
        label: 'X',
        units: '',
        min: -10,
        max: 10,
        dangerBelow: 1,
      );
      expect(offset.statusFor(0), GaugeStatus.danger);
    });
  });

  group('GaugeSpec presentation', () {
    const spec = GaugeSpec(
      channel: 'x',
      label: 'X',
      units: 'u',
      min: 0,
      max: 100,
      decimals: 1,
    );

    test('maps a value to a clamped fraction', () {
      expect(spec.fractionFor(0), 0);
      expect(spec.fractionFor(50), 0.5);
      expect(spec.fractionFor(100), 1);
      expect(spec.fractionFor(-20), 0, reason: 'must clamp, not go negative');
      expect(spec.fractionFor(500), 1, reason: 'must clamp at full scale');
      expect(spec.fractionFor(null), 0);
    });

    test('handles a negative minimum', () {
      const temp = GaugeSpec(
        channel: 't',
        label: 'T',
        units: 'C',
        min: -40,
        max: 140,
      );
      expect(temp.fractionFor(-40), 0);
      expect(temp.fractionFor(50), closeTo(0.5, 1e-9));
    });

    test('formats to the configured precision', () {
      expect(spec.format(12.345), '12.3');
      expect(
        spec.format(null),
        '--',
        reason: 'an unavailable reading must be visibly absent, not zero',
      );
    });
  });

  group('StatusPalette', () {
    test('pairs every alarm with an icon and a label', () {
      // Colour alone must never carry the meaning: warning is deliberately
      // below 3:1 contrast on a light surface, so the icon and text are the
      // mitigation, not decoration.
      for (final status in [GaugeStatus.warning, GaugeStatus.danger]) {
        expect(StatusPalette.iconFor(status), isNotNull, reason: status.name);
        expect(StatusPalette.labelFor(status), isNotNull, reason: status.name);
        expect(status.isAlarm, isTrue);
      }
    });

    test('normal carries no badge', () {
      expect(StatusPalette.iconFor(GaugeStatus.normal), isNull);
      expect(StatusPalette.labelFor(GaugeStatus.normal), isNull);
      expect(GaugeStatus.normal.isAlarm, isFalse);
    });

    test('normal is neutral, not the accent', () {
      // The brand accent is a red-leaning pink: normal dials in it would
      // compete with the critical colour for attention.
      for (final brightness in Brightness.values) {
        final scheme = ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF2E6E),
          brightness: brightness,
        );
        expect(
          StatusPalette.forStatus(GaugeStatus.normal, scheme),
          scheme.onSurface,
        );
      }
    });
  });
}

void _temperatureUnitTests() {
  group('temperature units', () {
    test('symbols and ini flags match the scale', () {
      expect(TemperatureUnit.celsius.symbol, '\u00B0C');
      expect(TemperatureUnit.fahrenheit.symbol, '\u00B0F');
      // The definition gates Celsius behind this symbol and falls through to
      // Fahrenheit without it.
      expect(TemperatureUnit.celsius.iniSymbols, contains('CELSIUS'));
      expect(TemperatureUnit.fahrenheit.iniSymbols, isEmpty);
    });

    test('converts thresholds between scales', () {
      expect(TemperatureUnit.celsius.fromCelsius(100), 100);
      expect(TemperatureUnit.fahrenheit.fromCelsius(100), 212);
      expect(TemperatureUnit.fahrenheit.fromCelsius(-40), -40);
    });

    test('converts a temperature either way', () {
      const c = TemperatureUnit.celsius;
      const f = TemperatureUnit.fahrenheit;
      expect(c.convert(100, to: f), 212);
      expect(f.convert(212, to: c), closeTo(100, 1e-9));
      expect(f.convert(-40, to: c), closeTo(-40, 1e-9));
      expect(c.convert(20, to: c), 20);
    });

    test('knows a scale however a definition spells it', () {
      for (final units in ['C', '\u00B0C', 'deg C', 'degC', ' c ']) {
        expect(
          TemperatureUnit.ofUnits(units),
          TemperatureUnit.celsius,
          reason: units,
        );
      }
      for (final units in ['F', '\u00B0F', 'deg F']) {
        expect(
          TemperatureUnit.ofUnits(units),
          TemperatureUnit.fahrenheit,
          reason: units,
        );
      }
      // Ignition timing is in degrees too, and is no temperature.
      for (final units in ['deg', '%', 'kPa', 'ms', '']) {
        expect(TemperatureUnit.ofUnits(units), isNull, reason: units);
      }
    });

    GaugeSpec gaugeFor(TemperatureUnit unit, String name) {
      // The definition picks its temperature gauges by the same symbols the
      // decoder is parsed with, so gauge and reading cannot disagree on scale.
      final doc = IniParser(defined: unit.iniSymbols)
          .parse(File('assets/speeduino.ini').readAsStringSync());
      return GaugeCatalog(definition: doc).specFor(doc.gaugeNamed(name)!);
    }

    test('a healthy engine is normal in both scales', () {
      // The bug this guards: the app parsed the definition as Fahrenheit
      // while the gauge kept Celsius limits, so a healthy 108 degree engine
      // decoded as 226 and pegged the gauge at DANGER.
      const healthyCelsius = 90.0;
      for (final unit in TemperatureUnit.values) {
        final gauge = gaugeFor(unit, 'cltGauge');
        final reading = unit.fromCelsius(healthyCelsius);

        expect(
          gauge.statusFor(reading),
          GaugeStatus.normal,
          reason: '$healthyCelsius C in ${unit.name}',
        );
        expect(
          gauge.fractionFor(reading),
          lessThan(1.0),
          reason: 'must not peg the gauge in ${unit.name}',
        );
      }
    });

    test('an overheating engine alarms in both scales', () {
      for (final unit in TemperatureUnit.values) {
        final gauge = gaugeFor(unit, 'cltGauge');
        expect(gauge.statusFor(unit.fromCelsius(100)), GaugeStatus.warning);
        expect(gauge.statusFor(unit.fromCelsius(115)), GaugeStatus.danger);
      }
    });

    test('the same physical temperature reads the same status', () {
      // Checked away from the band edges: the definition's two branches are
      // written separately and do not line up to the degree - its Fahrenheit
      // danger point, 220, is 104.4 C where the Celsius one is 105.
      for (final celsius in const [-20.0, 20.0, 90.0, 100.0, 120.0]) {
        final metric = gaugeFor(
          TemperatureUnit.celsius,
          'cltGauge',
        ).statusFor(celsius);
        final imperial = gaugeFor(
          TemperatureUnit.fahrenheit,
          'cltGauge',
        ).statusFor(TemperatureUnit.fahrenheit.fromCelsius(celsius));
        expect(imperial, metric, reason: '$celsius C');
      }
    });

    test('intake air follows the same rule', () {
      for (final unit in TemperatureUnit.values) {
        final gauge = gaugeFor(unit, 'iatGauge');
        expect(gauge.statusFor(unit.fromCelsius(25)), GaugeStatus.normal);
        expect(gauge.statusFor(unit.fromCelsius(115)), GaugeStatus.danger);
      }
    });
  });
}
