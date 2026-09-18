import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';

void main() {
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
      expect(rpm.statusFor(6000), GaugeStatus.warning);
      expect(rpm.statusFor(6500), GaugeStatus.warning);
      expect(rpm.statusFor(7000), GaugeStatus.danger);
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
      expect(battery.statusFor(12.0), GaugeStatus.warning);
      expect(battery.statusFor(11.0), GaugeStatus.danger);
      expect(battery.statusFor(10.2), GaugeStatus.danger);
    });

    test('handles limits at both ends', () {
      expect(battery.statusFor(15.2), GaugeStatus.warning);
    });

    test('danger wins over warning when both apply', () {
      expect(rpm.statusFor(7500), GaugeStatus.danger);
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
  });

  group('default gauge set', () {
    test('every spec has a sane span', () {
      for (final spec in [
        ...DefaultGauges.primary,
        ...DefaultGauges.secondary,
      ]) {
        expect(spec.max, greaterThan(spec.min), reason: spec.channel);
        expect(spec.channel, isNotEmpty);
        expect(spec.label, isNotEmpty);
      }
    });

    test('thresholds fall inside the displayed range', () {
      // A limit outside the span could never be drawn on the track.
      for (final spec in [
        ...DefaultGauges.primary,
        ...DefaultGauges.secondary,
      ]) {
        for (final limit in [
          spec.warnAbove,
          spec.dangerAbove,
          spec.warnBelow,
          spec.dangerBelow,
        ]) {
          if (limit == null) continue;
          expect(
            limit,
            inInclusiveRange(spec.min, spec.max),
            reason:
                '${spec.channel} limit $limit outside '
                '${spec.min}..${spec.max}',
          );
        }
      }
    });

    test('danger is beyond warning wherever both are set', () {
      for (final spec in [
        ...DefaultGauges.primary,
        ...DefaultGauges.secondary,
      ]) {
        if (spec.warnAbove != null && spec.dangerAbove != null) {
          expect(
            spec.dangerAbove,
            greaterThan(spec.warnAbove!),
            reason: spec.channel,
          );
        }
        if (spec.warnBelow != null && spec.dangerBelow != null) {
          expect(
            spec.dangerBelow,
            lessThan(spec.warnBelow!),
            reason: spec.channel,
          );
        }
      }
    });
  });
}
