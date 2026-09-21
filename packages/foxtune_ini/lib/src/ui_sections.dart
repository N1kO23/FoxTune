/// Parsers for the sections that describe screens rather than bytes.
///
/// `[Menu]` and `[UserDefined]` are what TunerStudio builds its settings
/// dialogs from, and they are the only description of trigger setup, engine
/// constants, warmup enrichment and the rest that exists. Generating those
/// screens from here is what keeps FoxTune tracking a firmware release instead
/// of needing 240 dialogs hand-written and hand-maintained.
///
/// These collectors are stateful because the sections are: a `dialog` line
/// opens a dialog and every line after it belongs to that dialog until the
/// next one.
library;

import 'model/dialogs.dart';
import 'model/menus.dart';
import 'tokenizer.dart';

/// The two `{ ... }` conditions an item may carry, plus its other arguments.
///
/// See [IniDialogItem] for what the two conditions mean. The rule for reading
/// them is positional but forgiving: the definition writes an empty `{}` to
/// skip a slot, and some lines skip the constant slot that way too, so the
/// *last* group is the visibility condition and the one before it enables.
/// A line with a single group has only an enable condition.
class _Arguments {
  _Arguments(this.values, this.enable, this.visible);

  factory _Arguments.of(Iterable<String> atoms) {
    final values = <String>[];
    final groups = <String>[];
    for (final atom in atoms) {
      if (isBraceGroup(atom)) {
        groups.add(braceContents(atom));
      } else {
        values.add(atom);
      }
    }

    String? at(int index) {
      if (index < 0 || index >= groups.length) return null;
      final source = groups[index];
      return source.isEmpty ? null : source;
    }

    final enable = groups.length == 1 ? at(0) : at(groups.length - 2);
    final visible = groups.length == 1 ? null : at(groups.length - 1);
    return _Arguments(values, enable, visible);
  }

  final List<String> values;
  final String? enable;
  final String? visible;

  /// The value at [index], unquoted, or `null` when the line is shorter.
  String? value(int index) =>
      index < values.length ? unquote(values[index]) : null;

  /// The value at [index] read as an integer, or `null`.
  int? integer(int index) =>
      index < values.length ? int.tryParse(values[index].trim()) : null;
}

/// Builds the menu tree from `[Menu]` lines.
class MenuCollector {
  final List<IniMenu> _menus = [];
  IniMenu? _current;
  IniMenuItem? _group;
  final List<IniMenuItem> _groupChildren = [];

  /// The menus collected so far, in declaration order.
  List<IniMenu> get menus {
    _closeGroup();
    return List.unmodifiable(_menus);
  }

  /// Feeds one `key = value` line.
  void add(String key, String value) {
    switch (key) {
      case 'menu':
        _closeGroup();
        final label = unquote(value);
        // A menu name may be declared more than once - the format says the
        // standard "File", "Tools" and "Help" menus are appended to rather
        // than replaced - so entries accumulate under one heading.
        var menu = _menus.where((m) => m.label == label).firstOrNull;
        if (menu == null) {
          menu = IniMenu(label: label);
          _menus.add(menu);
        }
        _current = menu;

      case 'subMenu':
        _closeGroup();
        final item = _menuItem(value);
        if (item != null) _currentMenu().items.add(item);

      case 'groupMenu':
        _closeGroup();
        _group = IniMenuItem(target: '', label: unquote(value));

      case 'groupChildMenu':
        final item = _menuItem(value);
        if (item == null) break;
        if (_group == null) {
          _currentMenu().items.add(item);
        } else {
          _groupChildren.add(item);
        }

      // `menuDialog` names the window a menu belongs to, which matters to
      // TunerStudio's menu bar and not to a navigation list.
      default:
        break;
    }
  }

  IniMenu _currentMenu() {
    final menu = _current;
    if (menu != null) return menu;
    // Entries before any `menu` line still belong somewhere.
    final fallback = IniMenu(label: '');
    _menus.add(fallback);
    return _current = fallback;
  }

  void _closeGroup() {
    final group = _group;
    if (group == null) return;
    _currentMenu().items.add(IniMenuItem(
          target: group.target,
          label: group.label,
          children: List.of(_groupChildren),
        ));
    _group = null;
    _groupChildren.clear();
  }

  /// Parses `target[, "Label"][, page][, { condition }]`.
  static IniMenuItem? _menuItem(String value) {
    final atoms = splitArguments(value);
    if (atoms.isEmpty) return null;

    final target = unquote(atoms.first);
    if (target.isEmpty) return null;

    String? label;
    int? page;
    String? condition;

    for (final atom in atoms.skip(1)) {
      if (isBraceGroup(atom)) {
        final source = braceContents(atom);
        if (source.isNotEmpty) condition = source;
      } else if (int.tryParse(atom.trim()) case final number?) {
        page = number;
      } else {
        label ??= unquote(atom);
      }
    }

    return IniMenuItem(
      target: target,
      label: label ?? '',
      page: page,
      condition: condition,
    );
  }
}

/// Builds dialogs from `[UserDefined]` lines.
class DialogCollector {
  final List<IniDialog> _dialogs = [];

  String? _id;
  String _title = '';
  String? _layout;
  int? _columns;
  String? _topicHelp;
  String? _webHelp;
  List<IniDialogItem> _items = [];

  /// The dialogs collected so far, in declaration order.
  List<IniDialog> get dialogs {
    _flush();
    return List.unmodifiable(_dialogs);
  }

  /// Feeds one `key = value` line.
  void add(String key, String value) {
    switch (key) {
      case 'dialog':
        _flush();
        _begin(value);

      // Both of these open a block of their own rather than appearing inside
      // one. `indicatorPanel = protectIndicatorPanel, 1, { 1 }` is followed by
      // the indicators it holds, and other dialogs pull it in with
      // `panel = protectIndicatorPanel`; `help = helpGeneral, "..."` is a
      // dialog of prose that a menu entry opens.
      case 'indicatorPanel':
        _flush();
        _begin(value, layout: 'indicatorPanel');

      case 'help':
        _flush();
        _begin(value, layout: 'help');

      case 'topicHelp':
        _topicHelp = unquote(value);

      case 'webHelp':
        _webHelp = unquote(value);

      case 'field':
        _addField(value, readOnly: false);

      case 'displayOnlyField':
        _addField(value, readOnly: true);

      case 'panel':
        _addPanel(value);

      case 'slider':
        _addSlider(value);

      case 'commandButton':
        _addCommandButton(value);

      case 'indicator':
        _addIndicator(value);

      case 'text':
        _add(IniDialogText(text: unquote(value)));

      case 'gauge':
        final args = _Arguments.of(splitArguments(value));
        final gauge = args.value(0);
        if (gauge != null && gauge.isNotEmpty) {
          _add(IniDialogGauge(
            gauge: gauge,
            enableCondition: args.enable,
            visibleCondition: args.visible,
          ));
        }

      case 'liveGraph':
        _addLiveGraph(value);

      case 'graphLine':
        _addGraphLine(value);

      case 'settingSelector':
        _addSettingSelector(value);

      case 'settingOption':
        _addSettingOption(value);

      default:
        break;
    }
  }

  void _begin(String value, {String? layout}) {
    final atoms = splitArguments(value);
    _id = atoms.isEmpty ? null : unquote(atoms.first);
    _layout = layout;
    _columns = null;
    _title = '';
    _topicHelp = null;
    _webHelp = null;
    _items = [];

    // A dialog names a title second and a layout third; an `indicatorPanel`
    // names a column count second. Reading by shape rather than by position
    // covers both without a separate parser for each.
    for (final atom in atoms.skip(1)) {
      if (isBraceGroup(atom)) continue;
      final text = unquote(atom);
      final columns = int.tryParse(text);
      if (columns != null) {
        _columns = columns;
      } else if (_title.isEmpty && _layout == layout && _looksLikeTitle(atom)) {
        _title = text;
      } else if (text.isNotEmpty) {
        _layout = text;
      }
    }
  }

  /// Whether an argument is a quoted title rather than a bare layout name.
  ///
  /// Titles are always quoted - including the empty `""` that dialogs meant
  /// only for embedding carry - so the quotes are what distinguishes
  /// `dialog = x, "", border` from a layout name.
  static bool _looksLikeTitle(String atom) => atom.trim().startsWith('"');

  void _flush() {
    final id = _id;
    if (id == null || id.isEmpty) return;
    _dialogs.add(IniDialog(
      id: id,
      title: _title,
      items: List.unmodifiable(_items),
      layout: _layout,
      columns: _columns,
      topicHelp: _topicHelp,
      webHelp: _webHelp,
    ));
    _id = null;
  }

  void _add(IniDialogItem item) {
    if (_id == null) return;
    _items.add(item);
  }

  void _addField(String value, {required bool readOnly}) {
    final args = _Arguments.of(splitArguments(value));
    if (args.values.isEmpty) {
      // `field = { cond }` with nothing else says nothing; skip it rather
      // than emitting a spacer that carries a condition.
      return;
    }

    final styled = _readLabel(args.values.first);
    final constant = args.value(1);

    _add(IniDialogField(
      label: styled.label,
      constant: constant == null || constant.isEmpty ? null : constant,
      readOnly: readOnly,
      emphasis: styled.emphasis,
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  /// Reads a label, peeling off the `!` warning or `#` note marker.
  ///
  /// The marker sits either outside the quotes (`!"No PWM fan"`) or inside
  /// them (`"!This is a critical setting!"`), and both spellings appear in the
  /// shipped definition.
  static ({String label, IniFieldEmphasis emphasis}) _readLabel(String token) {
    var text = token.trim();
    var emphasis = IniFieldEmphasis.none;

    if (text.startsWith('!')) {
      emphasis = IniFieldEmphasis.warning;
      text = text.substring(1);
    } else if (text.startsWith('#')) {
      emphasis = IniFieldEmphasis.note;
      text = text.substring(1);
    }

    text = unquote(text);

    if (emphasis == IniFieldEmphasis.none) {
      if (text.startsWith('!')) {
        emphasis = IniFieldEmphasis.warning;
        text = text.substring(1);
      } else if (text.startsWith('#')) {
        emphasis = IniFieldEmphasis.note;
        text = text.substring(1);
      }
    }

    return (label: text.trim(), emphasis: emphasis);
  }

  static const _positions = {'north', 'south', 'east', 'west', 'center'};

  void _addPanel(String value) {
    final args = _Arguments.of(splitArguments(value));
    final target = args.value(0);
    if (target == null || target.isEmpty) return;

    String? position;
    for (var i = 1; i < args.values.length; i++) {
      final candidate = unquote(args.values[i]);
      if (_positions.contains(candidate.toLowerCase())) {
        position = candidate;
        break;
      }
    }

    _add(IniDialogPanel(
      target: target,
      position: position,
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  void _addSlider(String value) {
    final args = _Arguments.of(splitArguments(value));
    final constant = args.value(1);
    if (constant == null || constant.isEmpty) return;
    _add(IniDialogSlider(
      label: _readLabel(args.values.first).label,
      constant: constant,
      orientation: args.value(2) ?? 'horizontal',
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  void _addCommandButton(String value) {
    final args = _Arguments.of(splitArguments(value));
    final command = args.value(1);
    if (command == null || command.isEmpty) return;
    _add(IniDialogCommandButton(
      label: _readLabel(args.values.first).label,
      command: command,
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  void _addIndicator(String value) {
    final indicator = parseIndicator(value);
    if (indicator != null) _add(indicator);
  }

  void _addLiveGraph(String value) {
    final args = _Arguments.of(splitArguments(value));
    final id = args.value(0);
    if (id == null || id.isEmpty) return;
    _add(IniDialogLiveGraph(
      id: id,
      title: args.value(1) ?? '',
      lines: [],
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  void _addGraphLine(String value) {
    final channel = _Arguments.of(splitArguments(value)).value(0);
    if (channel == null || channel.isEmpty) return;

    // A `graphLine` belongs to the graph declared above it.
    final graph = _items.lastOrNull;
    if (graph is! IniDialogLiveGraph) return;
    _items[_items.length - 1] = IniDialogLiveGraph(
      id: graph.id,
      title: graph.title,
      lines: [...graph.lines, channel],
      enableCondition: graph.enableCondition,
      visibleCondition: graph.visibleCondition,
    );
  }

  void _addSettingSelector(String value) {
    final args = _Arguments.of(splitArguments(value));
    _add(IniDialogSettingSelector(
      label: args.value(0) ?? '',
      options: <IniSettingPreset>[],
      enableCondition: args.enable,
      visibleCondition: args.visible,
    ));
  }

  void _addSettingOption(String value) {
    final selector = _items.lastOrNull;
    if (selector is! IniDialogSettingSelector) return;

    final atoms = splitArguments(value);
    if (atoms.isEmpty) return;

    final assignments = <String, double>{};
    for (final atom in atoms.skip(1)) {
      final split = atom.indexOf('=');
      if (split <= 0) continue;
      final name = atom.substring(0, split).trim();
      final parsed = double.tryParse(atom.substring(split + 1).trim());
      if (name.isEmpty || parsed == null) continue;
      assignments[name] = parsed;
    }

    selector.options.add(
      IniSettingPreset(label: unquote(atoms.first), assignments: assignments),
    );
  }
}

/// Parses `{ expression }, "off label", "on label", colours...`.
///
/// Shared by dialogs and `[FrontPage]`, which declare indicators identically.
/// The leading group is the lamp's own expression - not a condition on whether
/// the lamp is shown - so it is taken before the generic argument reading.
IniDialogIndicator? parseIndicator(String value) {
  final atoms = splitArguments(value);
  if (atoms.isEmpty || !isBraceGroup(atoms.first)) return null;

  final expression = braceContents(atoms.first);
  if (expression.isEmpty) return null;

  // The two labels come next, by position. Either may be written in braces -
  // a template with live lookups in it - so they are taken before the
  // arguments are sorted, or a braced label would be read as a condition.
  ({String text, bool template}) label(int index) {
    if (index >= atoms.length) return (text: '', template: false);
    final atom = atoms[index];
    return isBraceGroup(atom)
        ? (text: braceContents(atom), template: true)
        : (text: unquote(atom), template: false);
  }

  final off = label(1);
  final on = label(2);
  final args = _Arguments.of(atoms.skip(3));
  return IniDialogIndicator(
    expression: expression,
    offLabel: off.text,
    onLabel: on.text,
    offLabelIsTemplate: off.template,
    onLabelIsTemplate: on.template,
    offBackground: args.value(0),
    offForeground: args.value(1),
    onBackground: args.value(2),
    onForeground: args.value(3),
    enableCondition: args.enable,
    visibleCondition: args.visible,
  );
}
