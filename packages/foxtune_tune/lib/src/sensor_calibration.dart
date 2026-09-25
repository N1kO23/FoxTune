import 'dart:math' as math;
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show crc32;

/// A thermistor's resistance against its temperature, fitted through three
/// measured points with the Steinhart-Hart equation, as TunerStudio's
/// three-point generator does.
class ThermistorCurve {
  const ThermistorCurve._(this.a, this.b, this.c);

  /// Fits the curve through [points]: three temperatures in degrees Celsius,
  /// each with the sensor's resistance at it in ohms.
  ///
  /// Throws [ArgumentError] for points no thermistor could have: other than
  /// three of them, two at one temperature, or a resistance that does not
  /// fall as the temperature rises.
  factory ThermistorCurve.fit(List<({double celsius, double ohms})> points) {
    if (points.length != 3) {
      throw ArgumentError('A thermistor is fitted through exactly three '
          'points, not ${points.length}.');
    }
    final sorted = [...points]..sort((a, b) => a.celsius.compareTo(b.celsius));
    for (var i = 0; i < sorted.length; i++) {
      final point = sorted[i];
      if (!point.celsius.isFinite || !(point.ohms > 0)) {
        throw ArgumentError('Each point needs a temperature and a resistance '
            'above zero.');
      }
      if (i == 0) continue;
      if (!(point.celsius > sorted[i - 1].celsius)) {
        throw ArgumentError('Two points are at the same temperature.');
      }
      if (!(point.ohms < sorted[i - 1].ohms)) {
        throw ArgumentError('The resistance has to fall as the temperature '
            'rises, as a thermistor\'s does.');
      }
    }

    final l = [for (final p in sorted) math.log(p.ohms)];
    final y = [for (final p in sorted) 1 / (p.celsius + 273.15)];
    final g2 = (y[1] - y[0]) / (l[1] - l[0]);
    final g3 = (y[2] - y[0]) / (l[2] - l[0]);
    final c = (g3 - g2) / (l[2] - l[1]) / (l[0] + l[1] + l[2]);
    final b = g2 - c * (l[0] * l[0] + l[0] * l[1] + l[1] * l[1]);
    final a = y[0] - (b + l[0] * l[0] * c) * l[0];
    if (!a.isFinite || !b.isFinite || !c.isFinite) {
      throw ArgumentError('No thermistor curve passes through these points.');
    }
    return ThermistorCurve._(a, b, c);
  }

  /// The Steinhart-Hart coefficients: 1/T = a + b ln R + c (ln R)^3, with T
  /// in kelvin.
  final double a;
  final double b;
  final double c;

  /// The temperature at [ohms], in degrees Celsius.
  ///
  /// Not finite, or far below absolute zero, where the curve has no answer:
  /// at no resistance at all, or an open circuit.
  double celsiusAt(double ohms) {
    final l = math.log(ohms);
    return 1 / (a + b * l + c * l * l * l) - 273.15;
  }
}

/// A sensor calibration, made for one of the definition's
/// `[ReferenceTables]`: a value for each step of the sensor's ADC reading, as
/// the ECU looks them up.
///
/// The values are in the units the table is sent in - degrees Fahrenheit for
/// a temperature table, which is how TunerStudio makes them and what the
/// definition's limits are in; the firmware converts. Where a value falls
/// outside the table's limits, or cannot be worked out at all, the limits'
/// fallback stands in: an open or shorted sensor then reads as something an
/// engine can run on, rather than as -270 degrees.
class SensorCalibration {
  SensorCalibration._(this.reference, this.target, this.values, this.fallbacks);

  /// For a thermistor read through a [biasOhms] pull-up resistor, as an
  /// ECU's coolant and air temperature inputs are.
  factory SensorCalibration.thermistor(
    IniReferenceTable reference, {
    required int target,
    required double biasOhms,
    required ThermistorCurve curve,
  }) =>
      SensorCalibration._fill(reference, target, (adc) {
        // The sensor is the lower leg of a divider, under the bias resistor.
        final ohms = biasOhms * adc / (1023 - adc);
        return curve.celsiusAt(ohms) * 1.8 + 32;
      });

  /// From [expression], over `adcValue` from 0 to 1023: one of the
  /// definition's `solution` lines.
  ///
  /// Throws [ArgumentError] where the expression cannot be worked out - one
  /// that reads an `.inc` file, say. [canUse] says so beforehand.
  factory SensorCalibration.formula(
    IniReferenceTable reference, {
    required int target,
    required String expression,
  }) {
    final compiled = CompiledExpression.tryCompile(expression);
    if (compiled == null || !canUse(expression)) {
      throw ArgumentError('"$expression" cannot be worked out here.');
    }
    return SensorCalibration._fill(
      reference,
      target,
      (adc) =>
          compiled.evaluate(
            (name) => name == 'adcValue' ? adc.toDouble() : null,
          ) ??
          double.nan,
    );
  }

  /// A straight line through two points of sensor voltage against value,
  /// carried on across the whole range: a linear wideband controller's
  /// output.
  factory SensorCalibration.linear(
    IniReferenceTable reference, {
    required int target,
    required double voltsLow,
    required double valueLow,
    required double voltsHigh,
    required double valueHigh,
    double referenceVolts = 5,
  }) {
    if (voltsHigh == voltsLow) {
      throw ArgumentError('The two points need different voltages.');
    }
    final slope = (valueHigh - valueLow) / (voltsHigh - voltsLow);
    return SensorCalibration._fill(reference, target, (adc) {
      final volts = adc * referenceVolts / 1023;
      return valueLow + (volts - voltsLow) * slope;
    });
  }

  static SensorCalibration _fill(
    IniReferenceTable reference,
    int target,
    double Function(int adc) valueAt,
  ) {
    final limits = reference.limits[target];
    final values = <double>[];
    final fallbacks = <int>{};
    for (var i = 0; i < reference.adcCount; i++) {
      var value = valueAt(adcAt(reference, i));
      if (limits != null) {
        // Written so that a value that is not a number fails it too.
        if (!(value >= limits.min && value <= limits.max)) {
          value = limits.fallback;
          fallbacks.add(i);
        }
      } else if (!value.isFinite) {
        value = 0;
        fallbacks.add(i);
      }
      values.add(value);
    }
    return SensorCalibration._(
      reference,
      target,
      List.unmodifiable(values),
      Set.unmodifiable(fallbacks),
    );
  }

  /// Whether [expression] can be worked out over `adcValue` - not one that
  /// needs an `.inc` file, as several of Speeduino's O2 sensors' do.
  static bool canUse(String expression) {
    if (expression.trim().isEmpty) return false;
    final compiled = CompiledExpression.tryCompile(expression);
    if (compiled == null) return false;
    return compiled.evaluate(
          (name) => name == 'adcValue' ? 512 : null,
        ) !=
        null;
  }

  /// The ADC reading, from 0 to 1023, that value [index] of [reference] is
  /// for.
  ///
  /// Spread evenly across the range: every 33rd for Speeduino's 32-value
  /// temperature tables, where its firmware puts them.
  static int adcAt(IniReferenceTable reference, int index) =>
      reference.adcCount <= 1
          ? 0
          : (index * 1023 / (reference.adcCount - 1)).round();

  /// The table this is for.
  final IniReferenceTable reference;

  /// Which of the table's identifiers it is written as - the coolant or the
  /// air temperature sensor, say.
  final int target;

  /// One value per ADC step, in the units the table is sent in.
  final List<double> values;

  /// Steps whose value fell outside the limits, or could not be worked out,
  /// and hold the fallback instead.
  final Set<int> fallbacks;

  /// The bytes sent: each value times the table's scale, rounded, in
  /// [IniReferenceTable.bytesPerAdc] bytes low byte first.
  Uint8List encode() {
    final size = reference.bytesPerAdc;
    final out = ByteData(values.length * size);
    for (var i = 0; i < values.length; i++) {
      final raw = (values[i] * reference.scale).round();
      switch (size) {
        case 1:
          out.setUint8(i, raw.clamp(0, 255));
        case 2:
          out.setInt16(i * 2, raw.clamp(-32768, 32767), Endian.little);
        default:
          throw UnsupportedError('$size-byte calibration values');
      }
    }
    return out.buffer.asUint8List();
  }

  /// The CRC-32 of [encode], which the ECU keeps of what it saved - so a
  /// calibration can be checked, or recognised, without reading it back.
  int get crc => crc32(encode());
}
