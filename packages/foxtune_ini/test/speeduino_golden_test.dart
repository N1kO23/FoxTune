@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_ini/src/gauge_sections.dart';
import 'package:test/test.dart';

/// Golden tests against the real `speeduino.ini` shipped by the firmware.
///
/// The point of these is that the parser must survive the actual file, not a
/// simplified stand-in. Every assertion here is a property a tuning session
/// depends on being right.
void main() {
  late String source;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    source = fixture.readAsStringSync();
  });

  IniDocument parse({Set<String> defined = const {}}) =>
      IniParser(defined: defined).parse(source);

  group('speeduino.ini', () {
    test('parses without error under every documented build config', () {
      for (final config in const <Set<String>>[
        {},
        {'CELSIUS'},
        {'LAMBDA'},
        {'pressure_bar'},
        {'mcu_teensy'},
        {'mcu_stm32'},
        {'COMMS_COMPAT'},
        {'MSDROID_COMPAT'},
        {'resetcontrol_adv'},
        {'enablehardware_test'},
        {'CELSIUS', 'mcu_stm32', 'COMMS_COMPAT', 'LAMBDA'},
      ]) {
        expect(() => parse(defined: config), returnsNormally,
            reason: 'config: $config');
      }
    });

    test('reports the firmware signature', () {
      final doc = parse();
      expect(doc.identity.signature, startsWith('speeduino '));
      expect(doc.identity.queryCommand, 'Q');
      expect(doc.identity.versionInfo, 'S');
    });

    test('declares the expected 15 pages and their sizes', () {
      // From `pageSize` in the shipped reference file. A change here means the
      // firmware layout moved and the rest of FoxTune needs revisiting.
      const expected = <int>[
        128,
        288,
        288,
        128,
        288,
        128,
        240,
        384,
        192,
        192,
        288,
        192,
        128,
        288,
        256,
      ];
      final constants = parse().constants;
      expect(constants.pageSizes, expected);
      expect(constants.pageCount, 15);
      expect(constants.endianness, 'little');
    });

    test('parses one field block per declared page, numbered 1..15', () {
      final pages = parse().constants.pages;
      expect(pages, hasLength(15));
      expect(
          [for (final p in pages) p.number], List.generate(15, (i) => i + 1));
      for (final page in pages) {
        expect(page.fields, isNotEmpty, reason: 'page ${page.number} is empty');
      }
    });

    test('every field fits inside its declared page', () {
      // The strongest structural check available: if offsets, widths or array
      // shapes were misparsed, some field would spill past its page boundary.
      final constants = parse().constants;
      for (final page in constants.pages) {
        final declared = constants.pageSizes[page.number - 1];
        for (final field in page.fields) {
          final offset = field.offset;
          if (offset == null) continue;
          expect(offset + field.sizeInBytes, lessThanOrEqualTo(declared),
              reason: 'page ${page.number}: ${field.name} '
                  '(offset $offset, ${field.sizeInBytes} bytes) '
                  'overruns declared size $declared');
        }
      }
    });

    test('selects blockingFactor per build config, last write winning', () {
      expect(parse().constants.blockingFactor, 251);
      expect(parse(defined: {'mcu_stm32'}).constants.blockingFactor, 121);
      // COMMS_COMPAT reassigns after the mcu branch has already run.
      expect(parse(defined: {'COMMS_COMPAT'}).constants.blockingFactor, 121);
      expect(
          parse(defined: {'mcu_stm32', 'COMMS_COMPAT'})
              .constants
              .blockingFactor,
          121);
    });

    test('selects the burn command variant per build config', () {
      expect(parse().constants.burnCommands.first, 'b%2i');
      expect(parse(defined: {'COMMS_COMPAT'}).constants.burnCommands.first,
          'B%2i');
    });

    test('supplies one command template per page', () {
      final constants = parse().constants;
      for (final list in [
        constants.pageReadCommands,
        constants.pageWriteCommands,
        constants.burnCommands,
        constants.pageIdentifiers,
      ]) {
        expect(list, hasLength(constants.pageCount));
      }
      expect(constants.pageReadCommands.first, 'p%2i%2o%2c');
      expect(constants.pageWriteCommands.first, 'M%2i%2o%2c%v');
    });

    test('parses the realtime data block layout', () {
      final och = parse().outputChannels;
      expect(och.blockSize, 139);
      expect(och.getCommand, contains('%2o%2c'));
      expect(och.channels, isNotEmpty);

      // Spot-check channels a dashboard depends on.
      final rpm = och.channelNamed('rpm');
      expect(rpm, isA<IniScalarField>());
      expect((rpm! as IniScalarField).type, IniDataType.u16);

      final map = och.channelNamed('map')! as IniScalarField;
      expect(map.offset, 4);
      expect(map.type, IniDataType.u16);
      expect(map.units.toLowerCase(), 'kpa');
    });

    test('keeps every realtime channel inside the declared block size', () {
      final och = parse().outputChannels;
      for (final channel in och.channels) {
        final offset = channel.offset;
        if (offset == null) continue;
        expect(offset + channel.sizeInBytes, lessThanOrEqualTo(och.blockSize!),
            reason: '${channel.name} overruns ochBlockSize');
      }
    });

    test('parses the tuning tables with resolvable axes', () {
      final doc = parse();
      expect(doc.tables, isNotEmpty);

      final ve = doc.tableNamed('veTable1Tbl');
      expect(ve, isNotNull, reason: 'the primary VE table must be present');
      expect(ve!.zBins, 'veTable');
      expect(ve.xBins.constant, isNotEmpty);
      expect(ve.yBins.constant, isNotEmpty);

      // Every table's z constant must actually exist in the page definitions,
      // or the editor would have nothing to write to.
      for (final table in doc.tables) {
        expect(doc.constants.findField(table.zBins), isNotNull,
            reason: 'table ${table.id} references unknown zBins '
                '"${table.zBins}"');
      }
    });

    test('the VE table array matches its axis lengths', () {
      final doc = parse();
      final ve = doc.tableNamed('veTable1Tbl')!;
      final z = doc.constants.findField(ve.zBins)!.field as IniArrayField;
      final x =
          doc.constants.findField(ve.xBins.constant)!.field as IniArrayField;
      final y =
          doc.constants.findField(ve.yBins.constant)!.field as IniArrayField;

      expect(z.shape, [16, 16]);
      expect(x.length, 16);
      expect(y.length, 16);
      expect(z.length, x.length * y.length);
    });

    test('parses curves with resolvable bins', () {
      final doc = parse();
      expect(doc.curves, isNotEmpty);
      for (final curve in doc.curves) {
        // Bins resolve against page constants or PC variables - warmup AFR
        // uses the latter - so the document-wide lookup is the right one.
        expect(doc.findField(curve.yBins.constant), isNotNull,
            reason: 'curve ${curve.id} references unknown yBins '
                '"${curve.yBins.constant}"');
        expect(doc.findField(curve.xBins.constant), isNotNull,
            reason: 'curve ${curve.id} references unknown xBins '
                '"${curve.xBins.constant}"');
      }
    });

    test('parses the datalog column definitions', () {
      final datalog = parse().datalog;
      expect(datalog.length, greaterThan(100));

      // Order matters: the file says entries are written in the order listed.
      expect(datalog.first.channel, 'time');
      expect(datalog.first.label, 'Time');
      expect(datalog.first.type, IniDatalogType.float);
      expect(datalog.first.decimals, 3);

      final rpm = datalog.firstWhere((e) => e.channel == 'rpm');
      expect(rpm.label, 'RPM');
      expect(rpm.type, IniDatalogType.integer);
      expect(rpm.decimals, 0);
    });

    test('falls back to the channel name for an expression label', () {
      // Aliased auxiliary inputs name their column with stringValue(), which
      // cannot be resolved here.
      final datalog = parse().datalog;
      final aliased = datalog.where((e) => e.labelExpression != null).toList();
      expect(aliased, isNotEmpty);
      for (final entry in aliased) {
        expect(entry.label, entry.channel);
        expect(entry.labelExpression, contains('stringValue'));
      }
    });

    test('retains the condition that gates optional columns', () {
      final gated = parse().datalog.where((e) => e.condition != null).toList();
      expect(gated, isNotEmpty);
      expect(gated.first.condition, isNotEmpty);
    });

    test('every logged channel exists in the definition', () {
      final doc = parse();
      final names = doc.outputChannels.allNames;
      final missing = [
        for (final entry in doc.datalog)
          if (!names.contains(entry.channel)) entry.channel,
      ];
      expect(missing, isEmpty, reason: 'unknown log channels: $missing');
    });

    test('collects the build-configuration groups', () {
      final groups = parse().settingGroups;
      expect(groups, isNotEmpty);
      final mcu = groups.firstWhere((g) => g.name == 'mcu');
      expect(mcu.selectableSymbols, containsAll(['mcu_teensy', 'mcu_stm32']));
    });

    test('retains unmodelled sections verbatim instead of dropping them', () {
      final raw = parse().rawSections;
      expect(raw.keys, containsAll(['LoggerDefinition', 'Tools']));
      expect(raw['LoggerDefinition']!.lines, isNotEmpty);
    });

    test('builds the whole menu tree', () {
      final doc = parse(defined: {'CELSIUS'});
      expect(doc.menus.map((m) => m.displayLabel),
          containsAll(['Settings', 'Tuning', 'Spark', 'Startup/Idle']));

      // The accelerator marker must not reach a label a user reads.
      for (final menu in doc.menus) {
        expect(menu.displayLabel, isNot(contains('&')));
      }

      final startup =
          doc.menus.firstWhere((m) => m.displayLabel == 'Startup/Idle');
      expect(
          startup.items.map((i) => i.target), containsAll(['warmup', 'ASE']));
    });

    test('nests grouped menu entries under their group', () {
      final tuning =
          parse().menus.firstWhere((m) => m.displayLabel == 'Tuning');
      final group = tuning.items.firstWhere((i) => i.isGroup);
      expect(group.label, 'Engine Protection');
      expect(group.children.map((c) => c.target),
          containsAll(['engineProtection', 'revLimiterDialog', 'boostCut']));
      // A grouped entry must not also appear at the top level.
      expect(tuning.items.map((i) => i.target), isNot(contains('boostCut')));
    });

    test('every menu entry leads somewhere', () {
      // A `subMenu` target may name a dialog, a table, a table's 3D map, a
      // curve or one of TunerStudio's own editors. Anything else is a menu
      // entry that would dead-end when tapped.
      final doc = parse(defined: {'CELSIUS'});
      final dangling = <String>[];
      for (final menu in doc.menus) {
        for (final item in menu.leaves) {
          if (doc.targetKind(item.target) == IniTargetKind.unknown) {
            dangling.add('${menu.displayLabel} > ${item.target}');
          }
        }
      }
      expect(dangling, isEmpty);
    });

    test('every embedded panel resolves to something renderable', () {
      final doc = parse(defined: {'CELSIUS'});
      final dangling = <String>[];
      for (final dialog in doc.dialogs) {
        for (final item in dialog.items) {
          if (item is! IniDialogPanel) continue;
          if (doc.targetKind(item.target) == IniTargetKind.unknown) {
            dangling.add('${dialog.id} > ${item.target}');
          }
        }
      }
      expect(dangling, isEmpty);
    });

    test('builds the settings dialogs', () {
      final doc = parse(defined: {'CELSIUS'});
      expect(doc.dialogs.length, greaterThan(200));

      final trigger = doc.dialogNamed('triggerSettings');
      expect(trigger, isNotNull);
      expect(trigger!.title, 'Trigger Settings');
      expect(trigger.columns, 4);

      final pattern = trigger.items
          .whereType<IniDialogField>()
          .firstWhere((f) => f.constant == 'TrigPattern');
      expect(pattern.label, 'Trigger Pattern');
      expect(pattern.enableCondition, isNull);

      // A missing comma between the constant and its condition is in the
      // shipped file and must not swallow one into the other.
      final edge = trigger.items
          .whereType<IniDialogField>()
          .firstWhere((f) => f.label == 'Trigger edge');
      expect(edge.constant, 'TrigEdge');
      expect(edge.enableCondition, contains('TrigPattern != 4'));
    });

    test('reads warmup and afterstart enrichment as curve-bearing dialogs', () {
      final doc = parse(defined: {'CELSIUS'});

      final warmup = doc.dialogNamed('warmup');
      expect(warmup, isNotNull);
      final warmupCurve = warmup!.items.whereType<IniDialogPanel>().single;
      expect(doc.targetKind(warmupCurve.target), IniTargetKind.curve);

      // ASE nests one level further: its panels are dialogs, each of which
      // holds the curve. Rendering it means recursing rather than stopping at
      // the first panel.
      final ase = doc.dialogNamed('ASE');
      expect(ase, isNotNull);
      final asePanels = ase!.items.whereType<IniDialogPanel>().toList();
      expect(asePanels.map((p) => p.target), ['ASE_amount', 'ASE_time']);
      for (final panel in asePanels) {
        expect(doc.targetKind(panel.target), IniTargetKind.dialog);
        final inner = doc.dialogNamed(panel.target)!;
        expect(
          inner.items
              .whereType<IniDialogPanel>()
              .any((p) => doc.targetKind(p.target) == IniTargetKind.curve),
          isTrue,
          reason: '${panel.target} holds no curve',
        );
      }
    });

    test('keeps the warning marker off the label and out of the constant', () {
      // `displayOnlyField = !"No PWM Fan available on MCU", blankfield, ...`
      // writes the marker outside the quotes. Read naively the marker becomes
      // an argument of its own, which shunts the label into the constant slot
      // and binds the field to a constant that does not exist.
      final doc = parse(defined: {'CELSIUS'});
      final warnings = [
        for (final dialog in doc.dialogs)
          for (final item in dialog.items)
            if (item is IniDialogField &&
                item.emphasis == IniFieldEmphasis.warning)
              item,
      ];
      expect(warnings, isNotEmpty);
      for (final field in warnings) {
        expect(field.label, isNot(startsWith('!')));
        expect(field.constant, isNot(contains(' ')));
      }
    });

    test('every dialog condition compiles', () {
      // These decide which fields a tuner is shown. One that will not compile
      // is a field that either never appears or never hides.
      final doc = parse(defined: {'CELSIUS'});
      final broken = <String>[];
      var checked = 0;

      void check(String? source) {
        if (source == null) return;
        checked++;
        if (CompiledExpression.tryCompile(source) == null) broken.add(source);
      }

      for (final dialog in doc.dialogs) {
        for (final item in dialog.items) {
          check(item.enableCondition);
          check(item.visibleCondition);
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

      expect(checked, greaterThan(800));
      expect(broken, isEmpty);
    });

    test('binds dialog fields to constants that exist', () {
      // The only exceptions are the `string` PC variables - aux channel
      // aliases - which the field model does not cover. Anything else
      // unbound would be a setting shown with nothing behind it.
      final doc = parse(defined: {'CELSIUS'});
      final unbound = <String>{};
      for (final dialog in doc.dialogs) {
        for (final item in dialog.items) {
          final name = switch (item) {
            IniDialogField(:final constant) => constant,
            IniDialogSlider(:final constant) => constant,
            _ => null,
          };
          if (name == null) continue;
          if (doc.findField(name) == null) unbound.add(name);
        }
      }
      expect(unbound.every((n) => n.endsWith('Alias')), isTrue,
          reason: 'unbound: $unbound');
    });

    test('describes VE autotuning, per build configuration', () {
      // The definition declares one `veAnalyzeMap` per `#if LAMBDA` branch.
      // Reading the wrong one would tune the VE table against a target
      // fourteen times off, because AFR and lambda differ by `stoich`.
      final afrBuild = parse(defined: {'CELSIUS'}).veAnalyze!;
      expect(afrBuild.table, 'veTable1Tbl');
      expect(afrBuild.targetTable, 'afrTable1Tbl');
      expect(afrBuild.measuredChannel, 'afr');
      expect(afrBuild.measuresLambda, isFalse);
      expect(afrBuild.egoCorrectionChannel, 'egoCorrection');

      final lambdaBuild = parse(defined: {'CELSIUS', 'LAMBDA'}).veAnalyze!;
      expect(lambdaBuild.targetTable, 'lambdaTable1Tbl');
      expect(lambdaBuild.measuredChannel, 'lambda');
      expect(lambdaBuild.measuresLambda, isTrue);
    });

    test('reads the autotune filters, thresholds and all', () {
      final metric = parse(defined: {'CELSIUS'}).veAnalyze!;

      expect(metric.standardFilters.map((f) => f.id), [
        'std_xAxisMin',
        'std_xAxisMax',
        'std_yAxisMin',
        'std_yAxisMax',
        'std_DeadLambda',
        'std_Custom',
      ]);

      final clt = metric.filters.firstWhere((f) => f.id == 'minCltFilter');
      expect(clt.label, 'Minimum CLT');
      expect(clt.channel, 'coolant');
      expect(clt.operator, IniFilterOperator.lessThan);
      expect(clt.value, 71);

      // The same filter carries the Fahrenheit threshold in an imperial build,
      // which is the whole reason it is read from the file.
      final imperial = parse().veAnalyze!;
      expect(
        imperial.filters.firstWhere((f) => f.id == 'minCltFilter').value,
        160,
      );

      // A status-flag filter is a bitmask test, not a comparison.
      final accel = metric.filters.firstWhere((f) => f.id == 'accelFilter');
      expect(accel.operator, IniFilterOperator.bitmask);
      expect(accel.value, 16);
      // The trailing boolean is recorded but never acted on.
      expect(accel.flag, isFalse);
      expect(clt.flag, isTrue);
    });

    test('every autotune filter names a channel that exists', () {
      // A filter over a channel the ECU does not report can never fire, which
      // would silently remove a guard on what reaches the fuel table.
      for (final config in const <Set<String>>[
        {'CELSIUS'},
        {'CELSIUS', 'LAMBDA'},
        {},
      ]) {
        final doc = parse(defined: config);
        final channels = doc.outputChannels.allNames;
        for (final filter in doc.veAnalyze!.channelFilters) {
          expect(channels, contains(filter.channel),
              reason: '${filter.id} in $config');
        }
        expect(channels, contains(doc.veAnalyze!.measuredChannel));
        expect(channels, contains(doc.veAnalyze!.egoCorrectionChannel));
      }
    });

    test('reads the gauges, grouped by category', () {
      final doc = parse(defined: {'CELSIUS'});

      expect(doc.gauges.length, greaterThan(90));
      expect(
        doc.gauges.map((g) => g.category).toSet(),
        containsAll([
          'Main',
          'Sensor inputs',
          'Auxiliary Input Channels',
          'System Data',
        ]),
      );
    });

    test('keeps the tachometer tied to the Gauge Limits settings', () {
      // Range and thresholds are the Gauge Limits PC variables. Reading them
      // as literals - or at all before they are shown - would freeze the
      // gauge at whatever they were when the file was parsed.
      final tach = parse().gaugeNamed('tachometer')!;

      expect(tach.channel, 'rpm');
      expect(tach.title, 'Engine Speed');
      expect(tach.lo, const IniLiteral(0));
      expect(tach.hi, const IniExpression('rpmhigh'));
      expect(tach.hiWarning, const IniExpression('rpmwarn'));
      expect(tach.hiDanger, const IniExpression('rpmdang'));
      expect(tach.loDanger, const IniLiteral(300));
    });

    test('reads the gauges the file writes loosely', () {
      final doc = parse(defined: {'CELSIUS'});

      // No commas between channel, title and units.
      final system = doc.gaugeNamed('systemTempGauge')!;
      expect(system.channel, 'systemTemp');
      expect(system.title, 'System Temp');
      expect(system.units, 'C');

      // Units computed from another setting.
      final idle = doc.gaugeNamed('idleLoadGauge')!;
      expect(idle.hi, isA<IniExpression>());
      expect(idle.unitsExpression, contains('bitStringValue'));

      // A title computed from a user-set alias.
      final aux = doc.gaugeNamed('AuxInGauge0')!;
      expect(aux.title, isEmpty);
      expect(aux.titleExpression, contains('AUXin00Alias'));
      expect(aux.displayTitle, 'AuxInGauge0');
    });

    test('keeps a gauge whose line stops before its bands', () {
      final gauge = GaugeCollector.parseGauge(
        'short',
        'rpm, "Short", "RPM", 0, 8000, 300',
      )!;
      expect(gauge.loDanger, const IniLiteral(300));
      expect(gauge.loWarning, isNull);
      expect(gauge.hiDanger, isNull);
      expect(gauge.valueDigits, 0);
    });

    test('picks the temperature gauges for the build', () {
      expect(parse(defined: {'CELSIUS'}).gaugeNamed('cltGauge')!.units, 'C');
      expect(parse().gaugeNamed('cltGauge')!.units, 'F');
    });

    test('every gauge shows a channel the ECU reports', () {
      for (final config in const <Set<String>>[
        {},
        {'CELSIUS'},
        {'LAMBDA'}
      ]) {
        final doc = parse(defined: config);
        final channels = doc.outputChannels.allNames;
        final missing = [
          for (final gauge in doc.gauges)
            if (!channels.contains(gauge.channel)) gauge.name,
        ];
        expect(missing, isEmpty, reason: 'config $config');
      }
    });

    test('reads the default front page', () {
      final doc = parse(defined: {'CELSIUS'});
      final page = doc.frontPage;

      expect(page.gauges, [
        'tachometer',
        'throttleGauge',
        'pulseWidthGauge',
        'dutyCycleGauge',
        'mapGauge',
        'iatGauge',
        'cltGauge',
        'gammaEnrichGauge',
      ]);
      for (final name in page.gauges) {
        expect(doc.gaugeNamed(name), isNotNull, reason: name);
      }

      expect(page.indicators.length, greaterThan(40));
      final running = page.indicators.first;
      expect(running.expression, 'running');
      expect(running.onLabel, 'Running');
      expect(running.onBackground, 'green');
    });

    test('every front-page indicator compiles, bitwise ones included', () {
      // Four SD-card lamps test a flag bit with a single `&`.
      final doc = parse(defined: {'CELSIUS'});
      final broken = [
        for (final indicator in doc.frontPage.indicators)
          if (CompiledExpression.tryCompile(indicator.expression) == null)
            indicator.expression,
      ];
      expect(broken, isEmpty);
      expect(
        doc.frontPage.indicators.where((i) => i.expression.contains('& ')),
        isNotEmpty,
      );
    });

    test('reads per-constant help text', () {
      final help = parse().settingHelp;
      expect(help.length, greaterThan(300));
      expect(help['nCylinders'], 'Cylinder count');
    });

    test('reads factory values and power-cycle flags', () {
      final doc = parse();
      expect(doc.defaultValues['injAngRPM'], [500, 2000, 4500, 6500]);
      expect(doc.defaultValues['boardHasRTC'], hasLength(128));
      expect(doc.requiresPowerCycle, contains('pinLayout'));
    });

    test('CELSIUS changes units without moving offsets', () {
      // Unit selection must never shift the byte layout; only labels and
      // scaling change. If offsets moved, a tune written under one unit
      // setting would corrupt an ECU configured with the other.
      final metric = parse(defined: {'CELSIUS'}).constants;
      final imperial = parse().constants;

      for (var i = 0; i < metric.pages.length; i++) {
        final a = metric.pages[i];
        final b = imperial.pages[i];
        expect(a.fields.length, b.fields.length,
            reason: 'page ${a.number} field count differs');
        for (var f = 0; f < a.fields.length; f++) {
          expect(a.fields[f].name, b.fields[f].name);
          expect(a.fields[f].offset, b.fields[f].offset,
              reason: 'offset of ${a.fields[f].name} moved with CELSIUS');
        }
      }
    });
  });
}
