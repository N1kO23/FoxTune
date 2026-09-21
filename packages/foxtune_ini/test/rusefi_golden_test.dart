@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

/// Golden tests against a real rusEFI definition: the one generated for the
/// uaEFI board by rusEFI's own build, vendored unchanged.
///
/// rusEFI's definitions are generated per board and per build, much larger
/// than Speeduino's and written by a different generator, so they exercise
/// corners of the format Speeduino's never reaches. Everything here is
/// something connecting to, reading or editing a rusEFI depends on.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini'),
      File('test/fixtures/rusefi_uaefi.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser().parse(fixture.readAsStringSync());
  });

  group('rusefi_uaefi.ini', () {
    test('reports its identity from [TunerStudio]', () {
      // rusEFI puts these where the format also allows them, rather than in
      // [MegaTune] as Speeduino does.
      expect(
          doc.identity.signature, 'rusEFI master.2026.09.21.uaefi.419928595');
      expect(doc.identity.queryCommand, 'S');
      expect(doc.identity.versionInfo, 'V');
    });

    test('declares its pages and how to address them', () {
      final constants = doc.constants;
      expect(constants.pageSizes, [16816, 256, 2048, 1268, 8000]);
      expect(constants.pageIdentifiers, [
        r'\x00\x00',
        r'\x00\x01',
        r'\x00\x02',
        r'\x00\x03',
        r'\x00\x04',
      ]);
      expect(constants.pageReadCommands, everyElement('R%2i%2o%2c'));
      expect(constants.pageWriteCommands, everyElement('C%2i%2o%2c%v'));
      expect(constants.crcCheckCommands, everyElement('k%2i%2o%2c'));
      // Two pages are never burned: they are working memory, not settings.
      expect(constants.burnCommands, ['B%2i', '', '', 'B%2i', 'B%2i']);
      expect(constants.blockingFactor, 1024);
      expect(constants.blockReadTimeoutMs, 3000);
    });

    test('streams more realtime data than one transfer carries', () {
      final channels = doc.outputChannels;
      expect(channels.getCommand, 'O%2o%2c');
      expect(channels.blockSize, greaterThan(doc.constants.blockingFactor!));
    });

    test('keeps floats as floats', () {
      // rusEFI stores a large share of its settings and channels as 32-bit
      // floats, which Speeduino never does.
      final floatSettings = [
        for (final page in doc.constants.pages)
          for (final field in page.fields)
            if (field.type == IniDataType.f32) field,
      ];
      expect(floatSettings.length, greaterThan(300));
      expect(
        doc.outputChannels.channels.where((c) => c.type == IniDataType.f32),
        hasLength(greaterThan(200)),
      );
    });

    test('reads a field written with an empty argument', () {
      // `i2c1_speed = bits, U08, , 4216, [0:2], ...` - rusEFI's generator
      // leaves a gap before the offset.
      final field = doc.findField('i2c1_speed');
      expect(field, isA<IniBitsField>());
      expect(field!.offset, 4216);
      expect(
          (field as IniBitsField).options.first, startsWith('Standart mode'));
    });

    test('models the screens, tables and dashboard', () {
      expect(doc.tables.length, greaterThan(100));
      expect(doc.curves.length, greaterThan(60));
      expect(doc.dialogs.length, greaterThan(600));
      expect(doc.menus, isNotEmpty);
      expect(doc.gauges.length, greaterThan(300));
      expect(doc.frontPage.gauges, contains('RPMGauge'));
      for (final name in doc.frontPage.gauges) {
        expect(doc.gaugeNamed(name), isNotNull, reason: name);
      }
      expect(doc.tableNamed('veTableTbl'), isNotNull);
    });

    test('every menu entry leads somewhere', () {
      // Including through groups, which in rusEFI's menus hold separators.
      for (final menu in doc.menus) {
        for (final leaf in menu.leaves) {
          expect(leaf.isSeparator, isFalse, reason: menu.label);
          expect(
            doc.targetKind(leaf.target),
            isNot(IniTargetKind.unknown),
            reason: leaf.target,
          );
        }
      }
    });

    test('every expression compiles', () {
      final failures = <String>[];
      void check(String? source) {
        if (source == null || source.trim().isEmpty) return;
        if (CompiledExpression.tryCompile(source) == null) failures.add(source);
      }

      for (final channel in doc.outputChannels.computed) {
        check(channel.expression);
      }
      for (final indicator in doc.frontPage.indicators) {
        check(indicator.expression);
      }
      for (final dialog in doc.dialogs) {
        for (final item in dialog.items) {
          check(item.enableCondition);
          check(item.visibleCondition);
          if (item is IniDialogIndicator) check(item.expression);
        }
      }
      for (final menu in doc.menus) {
        for (final item in menu.items) {
          check(item.condition);
          for (final child in item.children) {
            check(child.condition);
          }
        }
      }
      for (final gauge in doc.gauges) {
        for (final limit in [
          gauge.lo,
          gauge.hi,
          gauge.loDanger,
          gauge.loWarning,
          gauge.hiWarning,
          gauge.hiDanger,
        ]) {
          if (limit is IniExpression) check(limit.source);
        }
      }
      expect(failures, isEmpty);
    });

    test('reads braced indicator labels as templates, not conditions', () {
      final lamps = [
        for (final dialog in doc.dialogs)
          for (final item in dialog.items)
            if (item is IniDialogIndicator && item.onLabelIsTemplate) item,
      ];
      expect(lamps, isNotEmpty);
      final ignition = lamps.firstWhere(
        (i) => i.onLabel.startsWith('Ignition out 1'),
      );
      expect(ignition.onLabel, contains('bitStringValue(outputDiagErrorList'));
      // The label is not mistaken for a condition.
      expect(ignition.enableCondition, isNull);
      expect(ignition.onBackground, 'red');
    });
  });
}
