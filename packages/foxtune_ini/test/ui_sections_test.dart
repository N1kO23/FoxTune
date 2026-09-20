import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:test/test.dart';

/// Parsing of the sections that describe screens: `[Menu]`, `[UserDefined]`,
/// `[SettingContextHelp]` and `[ConstantsExtensions]`.
///
/// These drive every settings screen FoxTune shows, so a misread argument is
/// not a cosmetic problem - it is a field bound to the wrong constant, or one
/// that never appears.
void main() {
  IniDocument parse(String body) => IniParser().parse(body);

  group('[Menu]', () {
    test('reads a target, label, page and condition', () {
      final doc = parse('''
[Menu]
   menu = "&Tuning"
      subMenu = egoControl, "AFR/O2", 3, { egoType > 0 }
''');
      final menu = doc.menus.single;
      expect(menu.label, '&Tuning');
      expect(menu.displayLabel, 'Tuning');

      final item = menu.items.single;
      expect(item.target, 'egoControl');
      expect(item.label, 'AFR/O2');
      expect(item.page, 3);
      expect(item.condition, 'egoType > 0');
    });

    test('recovers a label written without its comma', () {
      // The shipped definition contains
      // `subMenu = dwell_tblMap    "Dwell Map", { useDwellMap }`.
      final item = parse('''
[Menu]
   menu = "Maps"
      subMenu = dwell_tblMap    "Dwell Map", { useDwellMap }
''').menus.single.items.single;

      expect(item.target, 'dwell_tblMap');
      expect(item.label, 'Dwell Map');
      expect(item.condition, 'useDwellMap');
    });

    test('keeps separators so the grouping survives', () {
      final items = parse('''
[Menu]
   menu = "Settings"
      subMenu = a, "A"
      subMenu = std_separator
      subMenu = b, "B"
''').menus.single.items;

      expect(items.map((i) => i.isSeparator), [false, true, false]);
      expect(items[1].isBuiltIn, isFalse);
    });

    test('nests group children and closes the group at the next entry', () {
      final items = parse('''
[Menu]
   menu = "Tuning"
      groupMenu = "Engine Protection"
        groupChildMenu = engineProtection, "Common"
        groupChildMenu = boostCut, "Boost Cut", { engineProtectType }
      subMenu = flexFuel, "Flex Fuel", 2
''').menus.single.items;

      expect(items, hasLength(2));
      expect(items[0].isGroup, isTrue);
      expect(items[0].label, 'Engine Protection');
      expect(items[0].children.map((c) => c.target),
          ['engineProtection', 'boostCut']);
      expect(items[1].target, 'flexFuel');
    });

    test('appends to a menu declared twice rather than shadowing it', () {
      // The format reserves "File", "Tools" and "Help" for appending to, and
      // Speeduino splits its own menus across several `menuDialog` blocks.
      final doc = parse('''
[Menu]
   menuDialog = main
   menu = "Tools"
      subMenu = mapCal, "Calibrate MAP"
   menuDialog = main
   menu = "Tools"
      subMenu = batCal, "Calibrate Voltage"
''');
      expect(doc.menus, hasLength(1));
      expect(doc.menus.single.items.map((i) => i.target), ['mapCal', 'batCal']);
    });

    test('marks TunerStudio built-ins as such', () {
      final item = parse('''
[Menu]
   menu = "Tools"
      subMenu = std_ms2gentherm, "Calibrate Temperature Sensors", 0
''').menus.single.items.single;

      expect(item.isBuiltIn, isTrue);
      expect(item.page, 0);
    });

    test('unescapes a doubled ampersand instead of eating it', () {
      final menu = parse('[Menu]\n   menu = "Fuel && Spark"\n').menus.single;
      expect(menu.displayLabel, 'Fuel & Spark');
    });
  });

  group('[UserDefined]', () {
    test('reads a dialog title and column count', () {
      final dialog = parse('''
[UserDefined]
    dialog = triggerSettings,"Trigger Settings",4
        topicHelp = "http://wiki.speeduino.com/en/decoders"
        field = "Trigger Pattern", TrigPattern
''').dialogs.single;

      expect(dialog.id, 'triggerSettings');
      expect(dialog.title, 'Trigger Settings');
      expect(dialog.columns, 4);
      expect(dialog.layout, isNull);
      expect(dialog.topicHelp, contains('decoders'));
    });

    test('reads a named layout in place of a column count', () {
      final dialog = parse('''
[UserDefined]
    dialog = engine_constants, "", border
        panel = engine_constants_west, West
''').dialogs.single;

      expect(dialog.title, isEmpty);
      expect(dialog.layout, 'border');
      expect(dialog.isBorderLayout, isTrue);
      expect(dialog.columns, isNull);

      final panel = dialog.items.single as IniDialogPanel;
      expect(panel.target, 'engine_constants_west');
      expect(panel.position, 'West');
    });

    test('distinguishes the enable condition from the visibility one', () {
      // One group enables; two mean the first enables and the second hides.
      final items = parse('''
[UserDefined]
    dialog = d, "D"
        field = "Switch point", mapSwitchPoint, { mapSample >= 1 }
        field = "Pairing", inj4CylPairing, {}, { nCylinders == 4 }
        field = "Deviation", afrDev, { afrEnabled }, { afrEnabled == 2 }
''').dialogs.single.items.cast<IniDialogField>();

      expect(items[0].enableCondition, 'mapSample >= 1');
      expect(items[0].visibleCondition, isNull);

      expect(items[1].enableCondition, isNull);
      expect(items[1].visibleCondition, 'nCylinders == 4');

      expect(items[2].enableCondition, 'afrEnabled');
      expect(items[2].visibleCondition, 'afrEnabled == 2');
    });

    test('reads a condition written without its comma', () {
      final field = parse('''
[UserDefined]
    dialog = d, "D"
        field = "Trigger edge", TrigEdge  { TrigPattern != 4 }
''').dialogs.single.items.single as IniDialogField;

      expect(field.constant, 'TrigEdge');
      expect(field.enableCondition, 'TrigPattern != 4');
    });

    test('separates text, spacers and bound fields', () {
      final items = parse('''
[UserDefined]
    dialog = d, "D"
        field = "Skip Revolutions", SkipCycles
        field = "Note: revolutions skipped while cranking"
        field = ""
''').dialogs.single.items.cast<IniDialogField>();

      expect(items[0].constant, 'SkipCycles');
      expect(items[0].isText, isFalse);

      expect(items[1].isText, isTrue);
      expect(items[1].constant, isNull);

      expect(items[2].isSpacer, isTrue);
    });

    test('peels the warning marker off a label, inside or outside the quotes',
        () {
      final items = parse('''
[UserDefined]
    dialog = d, "D"
        field = "!This is a critical setting!"
        displayOnlyField = !"No PWM Fan available on MCU", blankfield, {a},{a}
        field = "#Time and duration curves share coolant values"
''').dialogs.single.items.cast<IniDialogField>();

      expect(items[0].emphasis, IniFieldEmphasis.warning);
      expect(items[0].label, 'This is a critical setting!');

      // The marker outside the quotes is the one that shunts the label into
      // the constant slot if it is read as an argument of its own.
      expect(items[1].emphasis, IniFieldEmphasis.warning);
      expect(items[1].label, 'No PWM Fan available on MCU');
      expect(items[1].constant, 'blankfield');
      expect(items[1].readOnly, isTrue);

      expect(items[2].emphasis, IniFieldEmphasis.note);
      expect(items[2].label, startsWith('Time and duration'));
    });

    test('reads sliders, command buttons and indicators', () {
      final items = parse('''
[UserDefined]
    dialog = d, "D"
        slider = "Flex sensor filter", FILTER_FLEX, horizontal, { flexEnabled }
        commandButton = "Set Gear 1", cmdVSSratio1, { vssMode > 0 }
        indicator = { engineProtectRPM }, "Rev Limiter Off", "Rev Limiter ON", green, black, red, black
''').dialogs.single.items;

      final slider = items[0] as IniDialogSlider;
      expect(slider.constant, 'FILTER_FLEX');
      expect(slider.orientation, 'horizontal');
      expect(slider.enableCondition, 'flexEnabled');

      final button = items[1] as IniDialogCommandButton;
      expect(button.label, 'Set Gear 1');
      expect(button.command, 'cmdVSSratio1');

      final lamp = items[2] as IniDialogIndicator;
      // The leading group is the lamp's own expression, not a condition on
      // whether the lamp is shown at all.
      expect(lamp.expression, 'engineProtectRPM');
      expect(lamp.enableCondition, isNull);
      expect(lamp.offLabel, 'Rev Limiter Off');
      expect(lamp.onLabel, 'Rev Limiter ON');
      expect(lamp.onBackground, 'red');
    });

    test('collects setting presets under their selector', () {
      final selector = parse('''
[UserDefined]
    dialog = d, "D"
        settingSelector = "Common Pressure Sensors"
            settingOption = "MPX4250A", mapMin=10, mapMax=260
            settingOption = "GM 1-BAR", mapMin=10, mapMax=105
''').dialogs.single.items.single as IniDialogSettingSelector;

      expect(selector.label, 'Common Pressure Sensors');
      expect(selector.options.map((o) => o.label), ['MPX4250A', 'GM 1-BAR']);
      expect(selector.options.first.assignments,
          {'mapMin': 10.0, 'mapMax': 260.0});
    });

    test('attaches graph lines to the graph above them', () {
      final graph = parse('''
[UserDefined]
    dialog = d, "D"
      liveGraph = pump_ae_Graph, "AE Graph"
            graphLine = TPSdot
            graphLine = MAPdot
''').dialogs.single.items.single as IniDialogLiveGraph;

      expect(graph.id, 'pump_ae_Graph');
      expect(graph.title, 'AE Graph');
      expect(graph.lines, ['TPSdot', 'MAPdot']);
    });

    test('treats an indicator panel as a dialog others can embed', () {
      // `indicatorPanel` opens a block of lamps and is pulled in elsewhere
      // with an ordinary `panel` line, so it has to resolve like a dialog.
      final doc = parse('''
[UserDefined]
    indicatorPanel = protectIndicatorPanel, 1, { 1 }
        indicator = { engineProtectRPM }, "Off", "ON", green, black, red, black
    dialog = engineProtectionWest, "Engine Protection"
        panel = protectIndicatorPanel, { engineProtectType }
''');

      final lamps = doc.dialogNamed('protectIndicatorPanel');
      expect(lamps, isNotNull);
      expect(lamps!.columns, 1);
      expect(lamps.items.single, isA<IniDialogIndicator>());
      expect(doc.targetKind('protectIndicatorPanel'), IniTargetKind.dialog);
    });

    test('treats a help block as a dialog a menu entry can open', () {
      final doc = parse('''
[UserDefined]
       help = helpGeneral, "Speeduino Online Manual"
        webHelp = "https://wiki.speeduino.com/"
        text = "For current WIKI documentation, click Web Help,"
''');

      final help = doc.dialogNamed('helpGeneral');
      expect(help, isNotNull);
      expect(help!.title, 'Speeduino Online Manual');
      expect(help.webHelp, 'https://wiki.speeduino.com/');
      expect((help.items.single as IniDialogText).text, startsWith('For '));
    });
  });

  group('[SettingContextHelp] and [ConstantsExtensions]', () {
    test('reads help text and factory values', () {
      final doc = parse('''
[SettingContextHelp]
  nCylinders = "Cylinder count"
[ConstantsExtensions]
    defaultValue = injAngRPM,   500 2000 4500 6500
    defaultValue = pinLayout,   1
    requiresPowerCycle = pinLayout
''');

      expect(doc.helpFor('nCylinders'), 'Cylinder count');
      expect(doc.helpFor('missing'), isNull);
      expect(doc.defaultValues['injAngRPM'], [500, 2000, 4500, 6500]);
      expect(doc.defaultValues['pinLayout'], [1]);
      expect(doc.requiresPowerCycle, {'pinLayout'});
    });
  });
}
