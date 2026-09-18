import 'data_type.dart';
import 'ini_exception.dart';
import 'model/document.dart';
import 'model/fields.dart';
import 'model/sections.dart';
import 'preprocessor.dart';
import 'tokenizer.dart';

/// Parses a TunerStudio ECU definition into an [IniDocument].
///
/// Scope is deliberately the *data model* - what the bytes mean - rather than
/// TunerStudio's UI layout language. `[Menu]`, `[UserDefined]` and similar are
/// retained verbatim in [IniDocument.rawSections] but not interpreted.
///
/// Pass [defined] to select build-configuration branches. Option names from
/// `[SettingGroups]` double as preprocessor symbols, so
/// `{'CELSIUS', 'mcu_stm32'}` parses the file as that build sees it.
class IniParser {
  IniParser({Set<String>? defined}) : _defined = {...?defined};

  final Set<String> _defined;

  /// Section names parsed into the typed model. Everything else is retained raw.
  static const _modelledSections = {
    'MegaTune',
    'TunerStudio',
    'SettingGroups',
    'Constants',
    'OutputChannels',
    'PcVariables',
    'TableEditor',
    'CurveEditor',
  };

  /// Parses [source], the full text of a `.ini` file.
  IniDocument parse(String source) => parseLines(source.split('\n'));

  /// Parses pre-split [rawLines].
  IniDocument parseLines(List<String> rawLines) {
    final preprocessor = IniPreprocessor(defined: _defined);
    final pre = preprocessor.run(rawLines);
    final defines = pre.defines;

    // Identity
    String? signature, queryCommand, versionInfo, mtVersion, iniSpecVersion;

    // Constants
    final pages = <IniPage>[];
    var currentPage = <IniField>[];
    int? currentPageNumber;
    // Offset of the most recent field, for resolving `lastOffset`.
    int? previousOffset;
    final constantSettings = <String, String>{};

    // Other sections
    final settingGroups = <IniSettingGroup>[];
    final pcVariables = <IniField>[];
    final channels = <IniField>[];
    // Keyed by name so a later branch replaces an earlier one: `coolant` is
    // declared twice, once per temperature unit, and only the surviving
    // preprocessor branch should count.
    final computedChannels = <String, IniComputedChannel>{};
    String? ochGetCommand;
    int? ochBlockSize;
    final tables = <_TableBuilder>[];
    final curves = <_CurveBuilder>[];
    final rawSections = <String, List<String>>{};

    var section = '';

    void flushPage() {
      if (currentPageNumber != null) {
        pages.add(IniPage(number: currentPageNumber!, fields: currentPage));
      }
      currentPage = <IniField>[];
      currentPageNumber = null;
      previousOffset = null;
    }

    for (final line in pre.lines) {
      final text = line.text;

      if (text.startsWith('[') && text.endsWith(']')) {
        if (section == 'Constants') flushPage();
        section = text.substring(1, text.length - 1).trim();
        previousOffset = null;
        if (!_modelledSections.contains(section)) {
          rawSections.putIfAbsent(section, () => <String>[]);
        }
        continue;
      }

      if (!_modelledSections.contains(section)) {
        if (section.isNotEmpty) rawSections[section]!.add(text);
        continue;
      }

      final assignment = splitAssignment(text);
      if (assignment == null) continue;
      final key = assignment.key;
      final value = assignment.value;

      switch (section) {
        case 'MegaTune':
          switch (key) {
            case 'signature':
              signature = unquote(value);
            case 'queryCommand':
              queryCommand = unquote(value);
            case 'versionInfo':
              versionInfo = unquote(value);
            case 'MTversion':
              mtVersion = unquote(value);
          }

        case 'TunerStudio':
          if (key == 'iniSpecVersion') iniSpecVersion = unquote(value);

        case 'SettingGroups':
          _parseSettingGroup(key, value, settingGroups, line);

        case 'Constants':
          if (key == 'page') {
            flushPage();
            currentPageNumber = int.tryParse(value.trim());
            if (currentPageNumber == null) {
              throw IniParseException('Malformed page number',
                  line: text, lineNumber: line.number);
            }
          } else if (_isFieldDeclaration(value)) {
            final field = _parseField(key, value, defines, line,
                previousOffset: previousOffset);
            currentPage.add(field);
            previousOffset = field.offset ?? previousOffset;
          } else {
            // Header settings. Last write wins, which is what makes the
            // duplicate blockingFactor assignments resolve correctly.
            constantSettings[key] = value;
          }

        case 'OutputChannels':
          if (key == 'ochGetCommand') {
            ochGetCommand = unquote(value);
          } else if (key == 'ochBlockSize') {
            ochBlockSize = int.tryParse(value.trim());
          } else if (_isFieldDeclaration(value)) {
            final field = _parseField(key, value, defines, line,
                previousOffset: previousOffset);
            channels.add(field);
            previousOffset = field.offset ?? previousOffset;
          } else if (_computedChannel(key, value) case final computed?) {
            computedChannels[computed.name] = computed;
          }

        case 'PcVariables':
          if (_isFieldDeclaration(value)) {
            final field = _parseField(key, value, defines, line,
                previousOffset: previousOffset);
            pcVariables.add(field);
            previousOffset = field.offset ?? previousOffset;
          }

        case 'TableEditor':
          _parseTableLine(key, value, tables, line);

        case 'CurveEditor':
          _parseCurveLine(key, value, curves, line);
      }
    }

    if (section == 'Constants') flushPage();

    return IniDocument(
      identity: IniIdentity(
        signature: signature,
        queryCommand: queryCommand,
        versionInfo: versionInfo,
        mtVersion: mtVersion,
        iniSpecVersion: iniSpecVersion,
      ),
      settingGroups: settingGroups,
      defines: defines,
      constants: _buildConstants(pages, constantSettings),
      outputChannels: IniOutputChannels(
        getCommand: ochGetCommand,
        blockSize: ochBlockSize,
        channels: channels,
        computed: computedChannels.values.toList(growable: false),
      ),
      pcVariables: pcVariables,
      tables: [for (final t in tables) t.build()],
      curves: [for (final c in curves) c.build()],
      rawSections: {
        for (final entry in rawSections.entries)
          entry.key: IniRawSection(name: entry.key, lines: entry.value),
      },
      definedSymbols: preprocessor.symbols,
    );
  }

  // --- Constants -----------------------------------------------------------

  IniConstants _buildConstants(
      List<IniPage> pages, Map<String, String> settings) {
    List<String> stringList(String key) {
      final raw = settings[key];
      if (raw == null) return const [];
      return [for (final token in splitTopLevel(raw)) unquote(token)];
    }

    List<int> intList(String key) {
      final raw = settings[key];
      if (raw == null) return const [];
      return [
        for (final token in splitTopLevel(raw))
          if (int.tryParse(token.trim()) case final v?) v,
      ];
    }

    int? intSetting(String key) {
      final raw = settings[key];
      return raw == null ? null : int.tryParse(raw.trim());
    }

    return IniConstants(
      pages: pages,
      pageSizes: intList('pageSize'),
      endianness: (settings['endianness'] ?? 'little').trim(),
      blockingFactor: intSetting('blockingFactor'),
      pageReadCommands: stringList('pageReadCommand'),
      pageWriteCommands: stringList('pageValueWrite').isNotEmpty
          ? stringList('pageValueWrite')
          : stringList('pageChunkWrite'),
      burnCommands: stringList('burnCommand'),
      crcCheckCommands: stringList('crc32CheckCommand'),
      pageIdentifiers: stringList('pageIdentifier'),
      interWriteDelayMs: intSetting('interWriteDelay'),
      blockReadTimeoutMs: intSetting('blockReadTimeout'),
      pageActivationDelayMs: intSetting('pageActivationDelay'),
    );
  }

  // --- Fields --------------------------------------------------------------

  /// Recognises `name = { expression }`, optionally followed by `, "units"`.
  ///
  /// These carry no offset and no type: they are formulas over other channels.
  static IniComputedChannel? _computedChannel(String key, String value) {
    final tokens = splitTopLevel(value);
    if (tokens.isEmpty) return null;
    final first = tokens.first.trim();
    if (!first.startsWith('{') || !first.endsWith('}')) return null;
    return IniComputedChannel(
      name: key,
      expression: first.substring(1, first.length - 1).trim(),
      units: tokens.length > 1 ? unquote(tokens[1]) : '',
    );
  }

  static bool _isFieldDeclaration(String value) {
    final first = splitTopLevel(value).firstOrNull?.trim().toLowerCase();
    return first == 'scalar' || first == 'bits' || first == 'array';
  }

  /// Parses a scalar, bits or array declaration.
  ///
  /// Argument lists differ by section: `[PcVariables]` omits the byte offset
  /// and `[OutputChannels]` omits the display bounds. Rather than keeping three
  /// near-identical parsers, position 2 is inspected - a bracketed token or a
  /// quoted string there means no offset was supplied.
  IniField _parseField(String name, String value,
      Map<String, List<String>> defines, SourceLine line,
      {int? previousOffset}) {
    final tokens = splitTopLevel(value);
    if (tokens.length < 2) {
      throw IniParseException('Field "$name" has too few arguments',
          line: line.text, lineNumber: line.number);
    }

    final kind = tokens[0].trim().toLowerCase();
    final type = IniDataType.tryParse(tokens[1]);
    if (type == null) {
      throw IniParseException('Field "$name" has unknown type "${tokens[1]}"',
          line: line.text, lineNumber: line.number);
    }

    var i = 2;
    int? offset;
    // An offset is present only when position 2 is a bare integer, or the
    // symbolic `lastOffset`.
    if (i < tokens.length) {
      final candidate = tokens[i].trim();
      if (!candidate.startsWith('[') && !candidate.startsWith('"')) {
        if (candidate.toLowerCase() == 'lastoffset') {
          // `lastOffset` repeats the PREVIOUS field's offset - it is an alias
          // for the same bytes, not an append. The file relies on this to
          // present one byte two ways: `ego_min_afr` at offset 8 is followed
          // by `ego_min_lambda` at lastOffset, with `ego_max_afr` at 9.
          // Treating it as "previous offset + previous size" would silently
          // shift these fields onto their neighbours.
          if (previousOffset == null) {
            throw IniParseException(
                'Field "$name" uses lastOffset with no preceding field',
                line: line.text,
                lineNumber: line.number);
          }
          offset = previousOffset;
          i++;
        } else {
          final parsed = int.tryParse(candidate);
          if (parsed != null) {
            offset = parsed;
            i++;
          }
        }
      }
    }

    String? comment;

    switch (kind) {
      case 'bits':
        final range =
            i < tokens.length ? parseBracketed(tokens[i]) : const <int>[];
        if (range.length != 2) {
          throw IniParseException('Field "$name" has a malformed bit range',
              line: line.text, lineNumber: line.number);
        }
        i++;
        final options = <String>[];
        for (; i < tokens.length; i++) {
          options.addAll(_expandOption(tokens[i], defines));
        }
        return IniBitsField(
          name: name,
          type: type,
          offset: offset,
          lowBit: range[0],
          highBit: range[1],
          options: options,
          comment: comment,
        );

      case 'array':
        final shape =
            i < tokens.length ? parseBracketed(tokens[i]) : const <int>[];
        if (shape.isEmpty) {
          throw IniParseException('Field "$name" has no array shape',
              line: line.text, lineNumber: line.number);
        }
        i++;
        final rest = _parseNumericTail(tokens, i);
        return IniArrayField(
          name: name,
          type: type,
          offset: offset,
          shape: shape,
          units: rest.units,
          scale: rest.scale,
          translate: rest.translate,
          low: rest.low,
          high: rest.high,
          digits: rest.digits,
          comment: comment,
        );

      case 'scalar':
        final rest = _parseNumericTail(tokens, i);
        return IniScalarField(
          name: name,
          type: type,
          offset: offset,
          units: rest.units,
          scale: rest.scale,
          translate: rest.translate,
          low: rest.low,
          high: rest.high,
          digits: rest.digits,
          comment: comment,
        );

      default:
        throw IniParseException('Field "$name" has unknown kind "$kind"',
            line: line.text, lineNumber: line.number);
    }
  }

  /// Parses the `"units", scale, translate[, lo, hi, digits]` tail shared by
  /// scalar and array declarations.
  ({
    String units,
    IniScalarValue scale,
    IniScalarValue translate,
    IniScalarValue? low,
    IniScalarValue? high,
    int? digits,
  }) _parseNumericTail(List<String> tokens, int start) {
    String at(int index) => index < tokens.length ? tokens[index] : '';
    final units = unquote(at(start));
    final scale = at(start + 1).isEmpty
        ? const IniLiteral(1)
        : IniScalarValue.parse(at(start + 1));
    final translate = at(start + 2).isEmpty
        ? const IniLiteral(0)
        : IniScalarValue.parse(at(start + 2));
    final low =
        at(start + 3).isEmpty ? null : IniScalarValue.parse(at(start + 3));
    final high =
        at(start + 4).isEmpty ? null : IniScalarValue.parse(at(start + 4));
    final digits = int.tryParse(at(start + 5).trim());
    return (
      units: units,
      scale: scale,
      translate: translate,
      low: low,
      high: high,
      digits: digits,
    );
  }

  /// Resolves a bits option token, expanding `$define` references in place.
  List<String> _expandOption(String token, Map<String, List<String>> defines) {
    final trimmed = token.trim();
    if (isDefineReference(trimmed)) {
      final name = defineReferenceName(trimmed);
      final repeat = RegExp(r'^invalid_x(\d+)$').firstMatch(name);
      if (repeat != null) {
        return List<String>.filled(int.parse(repeat.group(1)!), 'INVALID');
      }
      final target = defines[name];
      if (target != null) return List<String>.of(target);
    }
    return [unquote(trimmed)];
  }

  // --- SettingGroups -------------------------------------------------------

  void _parseSettingGroup(
      String key, String value, List<IniSettingGroup> groups, SourceLine line) {
    final tokens = splitTopLevel(value);
    if (key == 'settingGroup') {
      groups.add(IniSettingGroup(
        name: unquote(tokens.isNotEmpty ? tokens[0] : ''),
        label: unquote(tokens.length > 1 ? tokens[1] : ''),
        options: <({String name, String label})>[],
      ));
    } else if (key == 'settingOption' && groups.isNotEmpty) {
      groups.last.options.add((
        name: unquote(tokens.isNotEmpty ? tokens[0] : ''),
        label: unquote(tokens.length > 1 ? tokens[1] : ''),
      ));
    }
  }

  // --- TableEditor / CurveEditor -------------------------------------------

  void _parseTableLine(
      String key, String value, List<_TableBuilder> tables, SourceLine line) {
    final tokens = splitTopLevel(value);
    if (key == 'table') {
      tables.add(_TableBuilder(
        id: unquote(tokens.isNotEmpty ? tokens[0] : ''),
        mapId: unquote(tokens.length > 1 ? tokens[1] : ''),
        title: unquote(tokens.length > 2 ? tokens[2] : ''),
        page: tokens.length > 3 ? int.tryParse(tokens[3].trim()) : null,
      ));
      return;
    }
    if (tables.isEmpty) return;
    final table = tables.last;
    switch (key) {
      case 'xBins':
        table.xBins = _binsRef(tokens);
      case 'yBins':
        table.yBins = _binsRef(tokens);
      case 'zBins':
        table.zBins = unquote(tokens.isNotEmpty ? tokens[0] : '');
      case 'xyLabels':
        table.xyLabels = [for (final t in tokens) unquote(t)];
      case 'upDownLabel':
        table.upDownLabel = [for (final t in tokens) unquote(t)];
      case 'topicHelp':
        table.topicHelp = unquote(value);
      case 'gridHeight':
        table.gridHeight = double.tryParse(value.trim());
      case 'gridOrient':
        table.gridOrient = [
          for (final t in tokens)
            if (double.tryParse(t.trim()) case final v?) v,
        ];
    }
  }

  void _parseCurveLine(
      String key, String value, List<_CurveBuilder> curves, SourceLine line) {
    final tokens = splitTopLevel(value);
    if (key == 'curve') {
      curves.add(_CurveBuilder(
        id: unquote(tokens.isNotEmpty ? tokens[0] : ''),
        title: unquote(tokens.length > 1 ? tokens[1] : ''),
      ));
      return;
    }
    if (curves.isEmpty) return;
    final curve = curves.last;
    switch (key) {
      case 'xBins':
        curve.xBins = _binsRef(tokens);
      case 'yBins':
        curve.yBins = _binsRef(tokens);
      case 'columnLabel':
        curve.columnLabels = [for (final t in tokens) unquote(t)];
      case 'xAxis':
        curve.xAxis = [
          for (final t in tokens)
            if (double.tryParse(t.trim()) case final v?) v,
        ];
      case 'yAxis':
        curve.yAxis = [
          for (final t in tokens)
            if (double.tryParse(t.trim()) case final v?) v,
        ];
    }
  }

  ({String constant, String? channel}) _binsRef(List<String> tokens) => (
        constant: unquote(tokens.isNotEmpty ? tokens[0] : ''),
        channel: tokens.length > 1 ? unquote(tokens[1]) : null,
      );
}

class _TableBuilder {
  _TableBuilder({
    required this.id,
    required this.mapId,
    required this.title,
    required this.page,
  });

  final String id;
  final String mapId;
  final String title;
  final int? page;

  ({String constant, String? channel}) xBins = (constant: '', channel: null);
  ({String constant, String? channel}) yBins = (constant: '', channel: null);
  String zBins = '';
  List<String> xyLabels = const [];
  List<String> upDownLabel = const [];
  String? topicHelp;
  double? gridHeight;
  List<double> gridOrient = const [];

  IniTable build() => IniTable(
        id: id,
        mapId: mapId,
        title: title,
        page: page,
        xBins: xBins,
        yBins: yBins,
        zBins: zBins,
        xyLabels: xyLabels,
        upDownLabel: upDownLabel,
        topicHelp: topicHelp,
        gridHeight: gridHeight,
        gridOrient: gridOrient,
      );
}

class _CurveBuilder {
  _CurveBuilder({required this.id, required this.title});

  final String id;
  final String title;

  ({String constant, String? channel}) xBins = (constant: '', channel: null);
  ({String constant, String? channel}) yBins = (constant: '', channel: null);
  List<String> columnLabels = const [];
  List<double> xAxis = const [];
  List<double> yAxis = const [];

  IniCurve build() => IniCurve(
        id: id,
        title: title,
        xBins: xBins,
        yBins: yBins,
        columnLabels: columnLabels,
        xAxis: xAxis,
        yAxis: yAxis,
      );
}
