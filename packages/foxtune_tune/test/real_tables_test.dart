@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Table handling against the real shipped definition.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  test('every declared table resolves to a usable view', () {
    final tune = TuneState.empty(doc);
    final unresolved = <String>[];
    for (final table in doc.tables) {
      if (TableView.of(tune, table) == null) unresolved.add(table.id);
    }
    expect(unresolved, isEmpty, reason: 'unresolved: $unresolved');
  });

  test('the VE table is 16x16 on page 2 with the expected axes', () {
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

    expect(view.page, 2);
    expect(view.rows, 16);
    expect(view.columns, 16);
    expect(view.zUnits, '%');
    expect(view.xUnits, 'RPM');
    expect(view.low, 0);
    expect(view.high, 255);
  });

  test('VE cells round-trip through the page bytes', () {
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

    view.setValueAt(0, 0, 45);
    view.setValueAt(15, 15, 120);

    expect(view.valueAt(0, 0), 45);
    expect(view.valueAt(15, 15), 120);
    expect(tune.dirtyPages, {2});

    // The VE table occupies the first 256 bytes of page 2.
    final page = tune.page(2);
    expect(page.sublist(0, 256).where((b) => b != 0).length, 2);
  });

  test('the spark table stores negative advance via its translate', () {
    // advTable1 declares translate -40, so raw 0 reads as -40 degrees.
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('sparkTbl')!)!;

    expect(view.valueAt(0, 0), -40);
    view.setValueAt(0, 0, 22);
    expect(view.valueAt(0, 0), 22);
    expect(view.low, -40);
    expect(view.high, 70);
  });

  test('spark values clamp to the definition bounds', () {
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('sparkTbl')!)!;

    // 90 degrees of advance would be catastrophic; it must be pinned at 70.
    view.setValueAt(5, 5, 90);
    expect(view.valueAt(5, 5), 70);

    view.setValueAt(5, 5, -100);
    expect(view.valueAt(5, 5), -40);
  });

  test('table axes fit inside their declared page', () {
    final tune = TuneState.empty(doc);
    for (final table in doc.tables) {
      final view = TableView.of(tune, table);
      if (view == null) continue;
      final size = doc.constants.pageSizes[view.page - 1];
      for (final field in [view.zField, view.xField, view.yField]) {
        expect(field.offset! + field.sizeInBytes, lessThanOrEqualTo(size),
            reason: '${table.id}: ${field.name} overruns page ${view.page}');
      }
    }
  });

  test('resolves a load axis units expression to a real label', () {
    // fuelLoadBins declares { bitStringValue(algorithmUnits, algorithm) }, so
    // the label depends on the configured load source. algorithm 0 is MAP.
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;

    expect(view.yUnits, 'kPa');
    expect(view.yUnits, isNot(contains('bitStringValue')),
        reason: 'the expression source must never reach the UI');
  });

  test('follows the configured load source', () {
    final tune = TuneState.empty(doc);
    final algorithm = tune.locate('algorithm')!;
    // Select TPS as the load source; the axis label must follow.
    final current = tune.readRaw(algorithm.page, algorithm.field)!;
    final field = algorithm.field as IniBitsField;
    final mask =
        ((1 << (field.highBit - field.lowBit + 1)) - 1) << field.lowBit;
    tune.writeRaw(
        algorithm.page, field, (current & ~mask) | (1 << field.lowBit));

    final view = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    expect(view.yUnits, '% TPS');
  });

  test('an unresolvable units expression renders as nothing, not source', () {
    final broken = IniParser().parse('''
[Constants]
nPages   = 1
pageSize = 32
page = 1
  z = array, U08, 0, [2x2], { bitStringValue(missing, alsoMissing) }, 1.0, 0.0, 0.0, 255.0, 0
  x = array, U08, 4, [2], "RPM", 1.0, 0.0, 0.0, 255.0, 0
  y = array, U08, 6, [2], "kPa", 1.0, 0.0, 0.0, 255.0, 0
[TableEditor]
  table = t, tMap, "T", 1
    xBins = x, rpm
    yBins = y, map
    zBins = z
''');
    final tune = TuneState.empty(broken);
    final view = TableView.of(tune, broken.tables.single)!;
    expect(view.zUnits, isEmpty);
  });

  test('a fresh tune reports no live cursor cell as an error', () {
    // With all-zero axes the nearest-cell search must still return something
    // rather than throwing while the tune is still being read.
    final tune = TuneState.empty(doc);
    final view = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    expect(() => view.cellFor(3000, 50), returnsNormally);
  });
}
