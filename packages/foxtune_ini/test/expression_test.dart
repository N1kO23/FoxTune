import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

double? eval(String source, [Map<String, double> vars = const {}]) =>
    CompiledExpression.compile(source).evaluate((name) => vars[name]);

void main() {
  group('arithmetic', () {
    test('evaluates literals and the four operations', () {
      expect(eval('1 + 2'), 3);
      expect(eval('10 - 4'), 6);
      expect(eval('3 * 4'), 12);
      expect(eval('10 / 4'), 2.5);
      expect(eval('10 % 3'), 1);
      expect(eval('0.5 + .25'), 0.75);
    });

    test('respects precedence and parentheses', () {
      expect(eval('2 + 3 * 4'), 14);
      expect(eval('(2 + 3) * 4'), 20);
      expect(eval('100.0 * 2 / 4'), 50);
    });

    test('handles unary minus and not', () {
      expect(eval('-5'), -5);
      expect(eval('-(2 + 3)'), -5);
      expect(eval('!0'), 1);
      expect(eval('!5'), 0);
    });

    test('yields null on division by zero rather than infinity', () {
      // A gauge must read as unavailable, never as "Infinity".
      expect(eval('1 / 0'), isNull);
      expect(eval('1 % 0'), isNull);
    });
  });

  group('comparison and logic', () {
    test('returns 1 or 0 in C fashion', () {
      expect(eval('3 > 2'), 1);
      expect(eval('3 < 2'), 0);
      expect(eval('2 >= 2'), 1);
      expect(eval('2 == 2'), 1);
      expect(eval('2 != 2'), 0);
      expect(eval('1 && 1'), 1);
      expect(eval('1 && 0'), 0);
      expect(eval('0 || 3'), 1);
    });

    test('short-circuits, so the right side may be unavailable', () {
      // `a && b` with an unknown b must still resolve when a is false.
      expect(eval('0 && unknown'), 0);
      expect(eval('1 || unknown'), 1);
      expect(eval('1 && unknown'), isNull);
    });

    test('evaluates shifts', () {
      expect(eval('1 << 3'), 8);
      expect(eval('16 >> 2'), 4);
    });
  });

  group('ternary', () {
    test('selects a branch', () {
      expect(eval('1 ? 10 : 20'), 10);
      expect(eval('0 ? 10 : 20'), 20);
    });

    test('evaluates only the taken branch', () {
      // This is what makes the real `dutyCycle` guard against rpm == 0 work.
      expect(eval('rpm ? (100.0 * 5 / rpm) : 0', {'rpm': 0}), 0);
      expect(eval('rpm ? (100.0 * 5 / rpm) : 0', {'rpm': 10}), 50);
    });

    test('nests, as the chained load-source selectors do', () {
      const source = 'a == 0 ? map : a == 1 ? tps : a == 2 ? 0 : 99';
      expect(eval(source, {'a': 0, 'map': 50, 'tps': 12}), 50);
      expect(eval(source, {'a': 1, 'map': 50, 'tps': 12}), 12);
      expect(eval(source, {'a': 2, 'map': 50, 'tps': 12}), 0);
      expect(eval(source, {'a': 7, 'map': 50, 'tps': 12}), 99);
    });
  });

  group('identifiers', () {
    test('resolves channel values', () {
      expect(eval('coolantRaw - 40', {'coolantRaw': 100}), 60);
      expect(eval('afr / stoich', {'afr': 14.7, 'stoich': 14.7}), 1);
    });

    test('propagates null for an unknown identifier', () {
      expect(eval('coolantRaw - 40'), isNull);
      expect(eval('a + b', {'a': 1}), isNull);
    });

    test('reports which identifiers it reads', () {
      final expr =
          CompiledExpression.compile('rpm ? loopsPerSecond / (rpm / 60) : 0');
      expect(expr.references, {'rpm', 'loopsPerSecond'});
    });

    test('accepts dotted names', () {
      final expr = CompiledExpression.compile(
          'arrayValue(array.boardFuelOutputs, pinLayout)');
      expect(expr.references, contains('array.boardFuelOutputs'));
    });
  });

  group('function calls', () {
    test('parse but evaluate to null rather than guessing', () {
      // Better an unavailable gauge than a fabricated reading.
      expect(eval('smoothBasic(loopsPerSecond, 75)', {'loopsPerSecond': 100}),
          isNull);
      expect(eval('bitStringValue(algorithmUnits, algorithm)'), isNull);
    });

    test('null from a call propagates through arithmetic', () {
      expect(eval('smoothBasic(x, 1) * 2', {'x': 5}), isNull);
    });
  });

  group('real definitions from speeduino.ini', () {
    test('coolant, celsius and fahrenheit forms', () {
      expect(eval('coolantRaw - 40', {'coolantRaw': 120}), 80);
      expect(eval('(coolantRaw - 40) * 1.8 + 32', {'coolantRaw': 120}), 176);
    });

    test('revolutionTime guards against a stopped engine', () {
      expect(eval('rpm ? ( 60000.0 / rpm) : 0', {'rpm': 0}), 0);
      expect(eval('rpm ? ( 60000.0 / rpm) : 0', {'rpm': 6000}), 10);
    });

    test('map_vacboost picks vacuum or boost', () {
      final vars = {
        'map': 40.0,
        'baro': 101.0,
        'map_inhg': 18.0,
        'map_psi': -8.8
      };
      expect(eval('map < baro ? -map_inhg : map_psi', vars), -18);
    });

    test('syncStatus combines two flags with a shift', () {
      expect(eval('halfSync + (sync << 1)', {'halfSync': 1, 'sync': 1}), 3);
    });
  });

  group('element access', () {
    // Dialog conditions in a real definition test pin assignments this way -
    // `{ outputPin[0] != 0 }` - and there are around a hundred of them. An
    // expression that will not compile is a field that never appears.
    test('resolves an indexed name through the resolver', () {
      expect(eval('outputPin[0]', {'outputPin[0]': 7}), 7);
      expect(eval('outputPin[2] != 0', {'outputPin[2]': 0}), 0);
    });

    test('evaluates the index as an expression', () {
      expect(
        eval('outputPin[nCylinders - 1]', {'nCylinders': 4, 'outputPin[3]': 9}),
        9,
      );
    });

    test('reports an unavailable element as unavailable', () {
      expect(eval('outputPin[1]'), isNull);
    });

    test('collects the base name as a reference', () {
      expect(CompiledExpression.compile('outputPin[idx] > 0').references,
          containsAll(['outputPin', 'idx']));
    });

    test('arrayValue is the same lookup spelled as a call', () {
      // `arrayValue(array.boardHasRTC, pinLayout)` gates Speeduino's whole
      // Data Logging menu.
      expect(
        eval('arrayValue( array.boardHasRTC, pinLayout ) > 0',
            {'pinLayout': 3, 'boardHasRTC[3]': 1}),
        1,
      );
      expect(
        eval('arrayValue( array.boardHasRTC, pinLayout ) > 0',
            {'pinLayout': 2, 'boardHasRTC[2]': 0}),
        0,
      );
    });

    test('other function calls still evaluate to null', () {
      expect(eval('bitStringValue(algorithmUnits, algorithm)'), isNull);
    });

    test('rejects a malformed index', () {
      expect(CompiledExpression.tryCompile('outputPin[0'), isNull);
      expect(CompiledExpression.tryCompile('outputPin[]'), isNull);
    });
  });

  group('malformed input', () {
    test('tryCompile returns null instead of throwing', () {
      expect(CompiledExpression.tryCompile('1 +'), isNull);
      expect(CompiledExpression.tryCompile('(1 + 2'), isNull);
      expect(CompiledExpression.tryCompile('1 ? 2'), isNull);
      expect(CompiledExpression.tryCompile('@@@'), isNull);
    });

    test('compile throws with position information', () {
      expect(() => CompiledExpression.compile('1 + + )'),
          throwsA(isA<FormatException>()));
    });
  });
}
