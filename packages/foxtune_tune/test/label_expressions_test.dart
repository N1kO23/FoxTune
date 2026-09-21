@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Labels with live lookups in them, as rusEFI writes its lamps.
void main() {
  late IniDocument doc;
  late IniDialogIndicator fuelCut;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('../foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
    ];
    doc = IniParser().parse(
      candidates.firstWhere((f) => f.existsSync()).readAsStringSync(),
    );
    // `{ Fuel cut: bitStringValue(fuelIgnCutCodeList, fuelCutReason) }`
    fuelCut = doc.frontPage.indicators.firstWhere(
      (i) => i.expression.startsWith('fuelCutReasonBlinker'),
    );
  });

  test('a lamp says why, not just that', () {
    expect(fuelCut.onLabelIsTemplate, isTrue);
    final label = indicatorLabel(
      fuelCut,
      on: true,
      definition: doc,
      resolve: (name) => name == 'fuelCutReason' ? 3 : null,
    );
    expect(label, 'Fuel cut: RPM limit');
  });

  test('before the first sample, the lookup shows as an ellipsis', () {
    final label = indicatorLabel(
      fuelCut,
      on: true,
      definition: doc,
      resolve: (_) => null,
    );
    expect(label, 'Fuel cut: ...');
  });

  test('in a list, with nothing live, the lookup is left out', () {
    expect(indicatorLabelText(fuelCut, on: true), 'Fuel cut: ...');
    // A plain label is untouched.
    expect(indicatorLabelText(fuelCut, on: false), 'Injection OK');
  });
}
