import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// One page carrying each shape a settings dialog binds to.
///
/// `injLayout` and `inj4CylPairing` deliberately share byte 3, because that
/// packing is what a bitfield write has to survive.
const _source = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 24
page = 1
  nCylinders      = scalar, U08, 0, "", 1.0, 0.0, 1.0, 8.0, 0
  stoich          = scalar, U08, 1, ":1", 0.1, 0.0, 8.0, 25.0, 1
  fuelLoadRes     = scalar, U08, 2, "", 1.0, 0.0, 1.0, 10.0, 0
  injLayout       = bits,   U08, 3, [0:1], "Paired", "Semi-Sequential", "Banked", "Sequential"
  inj4CylPairing  = bits,   U08, 3, [2:3], "1&2, 3&4", "1&3, 2&4", "INVALID", "INVALID"
  scaledByExpr    = scalar, U08, 4, "kPa", { fuelLoadRes }, 0.0, 0.0, 250.0, 0
  taeBins         = array,  U08, 8,  [4], "TPSdot", 10.0, 0.0, 0.0, 2550.0, 0
  taeRates        = array,  U08, 12, [4], "%",      1.0,  0.0, 0.0, 255.0,  0
[SettingContextHelp]
  nCylinders = "Cylinder count"
[ConstantsExtensions]
  requiresPowerCycle = injLayout
[CurveEditor]
  curve = tae, "TPS based AE"
    columnLabel = "TPSdot", "Added"
    xAxis = 0, 1200, 6
    yAxis = 0, 250, 4
    xBins = taeBins, TPSdot
    yBins = taeRates
''';

IniDocument get definition => IniParser().parse(_source);

void main() {
  late TuneState tune;

  setUp(() => tune = TuneState.empty(definition));

  SettingView view(String name, {int index = 0}) =>
      SettingView.of(tune, name, index: index)!;

  group('numeric settings', () {
    test('reads and writes through the declared scale', () {
      final stoich = view('stoich');
      stoich.setValue(14.7);

      expect(stoich.value, closeTo(14.7, 1e-9));
      expect(stoich.units, ':1');
      expect(stoich.decimals, 1);
      expect(stoich.step, closeTo(0.1, 1e-9));
      expect(stoich.displayText, '14.7');
      // The stored byte is the scaled value, which is what the ECU reads.
      expect(tune.readRaw(1, tune.locate('stoich')!.field), 147);
    });

    test('clamps to the declared bounds instead of writing them out', () {
      final cylinders = view('nCylinders');
      cylinders.setValue(99);
      expect(cylinders.value, 8);
      cylinders.setValue(-4);
      expect(cylinders.value, 1);
    });

    test('follows an expression scale rather than reporting nothing', () {
      // `scale = { fuelLoadRes }` resolves through another constant. Read as
      // a literal it comes back null, and the field shows nothing at all.
      view('fuelLoadRes').setValue(2);
      final scaled = SettingView.of(tune, 'scaledByExpr')!;
      expect(scaled.step, 2);

      scaled.setValue(50);
      expect(scaled.value, 50);
      expect(tune.readRaw(1, tune.locate('scaledByExpr')!.field), 25);
    });

    test('marks the page dirty so the change reaches a burn', () {
      expect(tune.isDirty, isFalse);
      view('nCylinders').setValue(6);
      expect(tune.dirtyPages, {1});
    });
  });

  group('enumerated settings', () {
    test('reads the option labels and the selection', () {
      final layout = view('injLayout');
      expect(layout.isEnumerated, isTrue);
      expect(layout.options,
          ['Paired', 'Semi-Sequential', 'Banked', 'Sequential']);

      layout.setOptionIndex(3);
      expect(layout.optionIndex, 3);
      expect(layout.optionLabel, 'Sequential');
      expect(layout.displayText, 'Sequential');
      // Conditions in the definition compare against the raw index.
      expect(layout.value, 3);
    });

    test('drops the INVALID padding from the offered options', () {
      // A two-bit field is padded out to four labels. Offering the padding
      // would let a tuner select a value the firmware rejects.
      final pairing = view('inj4CylPairing');
      expect(pairing.options, ['1&2, 3&4', '1&3, 2&4']);
      expect(() => pairing.setOptionIndex(2), throwsRangeError);
    });

    test('refuses a placeholder in the middle of the list', () {
      // `inj4CylPairing` pads its end; a real definition also pads the middle
      // - nCylinders lists INVALID for 0 and 7 - and neither is a value the
      // firmware understands.
      final tune = TuneState.empty(IniParser().parse('''
[MegaTune]
signature = "t 1"
[Constants]
endianness = little
nPages = 1
pageSize = 4
page = 1
  nCylinders = bits, U08, 0, [0:3], "INVALID", "1", "2", "3", "4", "5", "6", "INVALID", "8"
'''));
      final cylinders = SettingView.of(tune, 'nCylinders')!;

      expect(cylinders.isSelectable(0), isFalse);
      expect(cylinders.isSelectable(7), isFalse);
      expect(cylinders.isSelectable(8), isTrue);
      expect(() => cylinders.setOptionIndex(7), throwsArgumentError);

      cylinders.setOptionIndex(4);
      expect(cylinders.optionLabel, '4');
    });

    test('leaves the neighbouring setting in the same byte alone', () {
      view('inj4CylPairing').setOptionIndex(1);
      view('injLayout').setOptionIndex(3);

      expect(view('inj4CylPairing').optionIndex, 1);
      expect(view('injLayout').optionIndex, 3);
    });
  });

  group('array elements', () {
    test('addresses one element at a time', () {
      view('taeBins', index: 2).setValue(300);
      expect(view('taeBins', index: 2).value, 300);
      expect(view('taeBins', index: 1).value, 0);
    });

    test('refuses an index past the end', () {
      expect(SettingView.of(tune, 'taeBins', index: 4), isNull);
    });
  });

  group('metadata', () {
    test('carries the definition help and power-cycle flag', () {
      expect(view('nCylinders').help, 'Cylinder count');
      expect(view('nCylinders').requiresPowerCycle, isFalse);
      expect(view('injLayout').requiresPowerCycle, isTrue);
    });

    test('is null for a constant the definition does not place on a page', () {
      expect(SettingView.of(tune, 'nothingLikeThis'), isNull);
    });
  });

  group('CurveView', () {
    CurveView curve() => CurveView.of(tune, definition.curveNamed('tae')!)!;

    test('reads and writes both axes through their scales', () {
      final view = curve();
      expect(view.length, 4);
      expect(view.xLabel, 'TPSdot');
      expect(view.yLabel, 'Added');
      expect(view.xStep, 10);

      view.setXAt(1, 250);
      view.setYAt(1, 40);
      expect(view.xAt(1), 250);
      expect(view.yAt(1), 40);
      expect(tune.readRaw(1, tune.locate('taeBins')!.field, 1), 25);
    });

    test('interpolates between bins and holds past the ends', () {
      final view = curve();
      for (var i = 0; i < 4; i++) {
        view.setXAt(i, i * 100);
        view.setYAt(i, i * 10);
      }

      expect(view.valueAt(150), closeTo(15, 1e-9));
      expect(view.valueAt(-50), 0);
      expect(view.valueAt(9999), 30);
      expect(view.fractionalIndexFor(150), closeTo(1.5, 1e-9));
    });

    test('presents a descending bin array ascending, and writes it back', () {
      // Nothing in the shipped definition stores a curve backwards, but the
      // table axes are stored that way and the same code has to be safe if a
      // curve ever is.
      final bins = tune.locate('taeBins')!;
      for (var i = 0; i < 4; i++) {
        tune.writeRaw(bins.page, bins.field, 30 - i * 10, i);
      }

      final view = curve();
      expect(view.reversed, isTrue);
      expect([for (var i = 0; i < 4; i++) view.xAt(i)], [0, 100, 200, 300]);

      view.setXAt(0, 50);
      expect(view.xAt(0), 50);
      expect(tune.readRaw(bins.page, bins.field, 3), 5);
    });

    test('reports an axis that has stopped ascending', () {
      final view = curve();
      for (var i = 0; i < 4; i++) {
        view.setXAt(i, i * 100);
      }
      expect(view.isAscending, isTrue);

      view.setXAt(2, 50);
      expect(view.isAscending, isFalse);
    });

    test('tracks which points moved and in which direction', () {
      final view = curve();
      for (var i = 0; i < 4; i++) {
        view.setXAt(i, i * 100);
        view.setYAt(i, 50);
      }
      final baseline =
          CurveView.of(tune.copy(), definition.curveNamed('tae')!)!;

      view.setYAt(1, 70);
      view.setYAt(3, 20);

      expect(view.changesAgainst(baseline),
          {1: CellChange.raised, 3: CellChange.lowered});
    });
  });
}
