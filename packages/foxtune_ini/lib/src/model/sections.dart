import 'fields.dart';

/// One configuration page: a contiguous block of bytes in the ECU.
class IniPage {
  const IniPage({required this.number, required this.fields});

  /// Page number as declared by `page = N`. 1-based.
  final int number;

  /// Fields declared within this page, in source order.
  final List<IniField> fields;

  /// Looks up a field by name.
  IniField? fieldNamed(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }

  /// The highest byte touched by any field, exclusive.
  ///
  /// Useful as a sanity check against the declared `pageSize`: a value larger
  /// than the declared size means offsets were misread.
  int get extent {
    var max = 0;
    for (final field in fields) {
      final offset = field.offset;
      if (offset == null) continue;
      final end = offset + field.sizeInBytes;
      if (end > max) max = end;
    }
    return max;
  }

  @override
  String toString() => 'page $number (${fields.length} fields)';
}

/// The `[Constants]` section: page layout plus the transport settings that
/// govern how those pages are read and written.
class IniConstants {
  const IniConstants({
    required this.pages,
    required this.pageSizes,
    required this.endianness,
    required this.blockingFactor,
    required this.pageReadCommands,
    required this.pageWriteCommands,
    required this.burnCommands,
    required this.crcCheckCommands,
    required this.pageIdentifiers,
    required this.interWriteDelayMs,
    required this.blockReadTimeoutMs,
    required this.pageActivationDelayMs,
  });

  /// Pages in declaration order.
  final List<IniPage> pages;

  /// Declared size in bytes of each page, indexed from 0.
  final List<int> pageSizes;

  /// `little` or `big`. Speeduino is little-endian.
  final String endianness;

  /// Maximum payload bytes per transfer. Reads and writes larger than this
  /// must be chunked; the firmware silently misbehaves otherwise.
  final int? blockingFactor;

  /// Per-page read command templates, e.g. `p%2i%2o%2c`.
  final List<String> pageReadCommands;

  /// Per-page write command templates, e.g. `M%2i%2o%2c%v`.
  final List<String> pageWriteCommands;

  /// Per-page burn command templates. `b%2i`, or `B%2i` under COMMS_COMPAT.
  final List<String> burnCommands;

  /// Per-page CRC-32 verification command templates, e.g. `d%2i`.
  final List<String> crcCheckCommands;

  /// Per-page identifier byte strings.
  final List<String> pageIdentifiers;

  /// Delay between consecutive writes, in milliseconds.
  final int? interWriteDelayMs;

  /// Read timeout in milliseconds.
  final int? blockReadTimeoutMs;

  /// Delay after switching pages, in milliseconds.
  final int? pageActivationDelayMs;

  /// Number of declared pages.
  int get pageCount => pageSizes.length;

  /// Looks up a field by name across every page.
  ({IniPage page, IniField field})? findField(String name) {
    for (final page in pages) {
      final field = page.fieldNamed(name);
      if (field != null) return (page: page, field: field);
    }
    return null;
  }
}

/// A channel with no bytes of its own, derived from other channels.
///
/// `coolant = { coolantRaw - 40 }` is the canonical example: the ECU sends a
/// raw temperature offset by 40, and the definition - not the firmware -
/// describes how to turn it into a reading. Several primary gauges are only
/// available this way, so dropping these would leave a dashboard unable to
/// show coolant or intake temperature at all.
class IniComputedChannel {
  const IniComputedChannel({
    required this.name,
    required this.expression,
    this.units = '',
  });

  /// Channel name, as other expressions and gauges reference it.
  final String name;

  /// The expression source, without the surrounding braces.
  final String expression;

  /// Display units, where the declaration supplies them.
  final String units;

  @override
  String toString() => '$name = { $expression }';
}

/// The `[OutputChannels]` section: the layout of the realtime data block.
class IniOutputChannels {
  const IniOutputChannels({
    required this.getCommand,
    required this.blockSize,
    required this.channels,
    this.computed = const [],
  });

  /// Command template used to fetch realtime data,
  /// e.g. `r\$tsCanId\x30%2o%2c`.
  final String? getCommand;

  /// Size of the realtime block in bytes.
  final int? blockSize;

  /// Byte-backed channels in declaration order.
  final List<IniField> channels;

  /// Channels derived from others by expression, in declaration order.
  final List<IniComputedChannel> computed;

  /// Looks up a byte-backed channel by name.
  IniField? channelNamed(String name) {
    for (final channel in channels) {
      if (channel.name == name) return channel;
    }
    return null;
  }

  /// Looks up a computed channel by name.
  IniComputedChannel? computedNamed(String name) {
    for (final channel in computed) {
      if (channel.name == name) return channel;
    }
    return null;
  }

  /// Every channel name, byte-backed and computed.
  Set<String> get allNames => {
        for (final c in channels) c.name,
        for (final c in computed) c.name,
      };
}

/// A 3D table definition from `[TableEditor]`.
class IniTable {
  const IniTable({
    required this.id,
    required this.mapId,
    required this.title,
    required this.page,
    required this.xBins,
    required this.yBins,
    required this.zBins,
    this.xyLabels = const [],
    this.upDownLabel = const [],
    this.topicHelp,
    this.gridHeight,
    this.gridOrient = const [],
  });

  /// Table identifier, e.g. `veTable1Tbl`.
  final String id;

  /// The associated map identifier, e.g. `veTable1Map`.
  final String mapId;

  /// Human-readable title, e.g. "VE Table".
  final String title;

  /// Page this table lives on.
  final int? page;

  /// `(constant, channel)` naming the X axis bins and its realtime channel.
  final ({String constant, String? channel}) xBins;

  /// `(constant, channel)` naming the Y axis bins and its realtime channel.
  final ({String constant, String? channel}) yBins;

  /// The constant holding the table values.
  final String zBins;

  /// Axis labels.
  final List<String> xyLabels;

  /// Labels for the increase/decrease directions.
  final List<String> upDownLabel;

  /// Documentation URL.
  final String? topicHelp;

  /// Rendering hint for the 3D view.
  final double? gridHeight;

  /// Rendering orientation for the 3D view.
  final List<double> gridOrient;

  @override
  String toString() => 'table $id ($title) page $page';
}

/// A 2D curve definition from `[CurveEditor]`.
class IniCurve {
  const IniCurve({
    required this.id,
    required this.title,
    required this.xBins,
    required this.yBins,
    this.columnLabels = const [],
    this.xAxis = const [],
    this.yAxis = const [],
  });

  /// Curve identifier, e.g. `dwell_correction_curve`.
  final String id;

  /// Human-readable title.
  final String title;

  /// `(constant, channel)` naming the X axis bins.
  final ({String constant, String? channel}) xBins;

  /// `(constant, channel)` naming the Y axis bins.
  final ({String constant, String? channel}) yBins;

  /// Column headings for the tabular view.
  final List<String> columnLabels;

  /// `min, max, divisions` for the X axis.
  final List<double> xAxis;

  /// `min, max, divisions` for the Y axis.
  final List<double> yAxis;

  @override
  String toString() => 'curve $id ($title)';
}

/// A build-configuration group from `[SettingGroups]`.
///
/// Each option name doubles as a preprocessor symbol, which is how a user's
/// choice of units or MCU selects `#if` branches.
class IniSettingGroup {
  const IniSettingGroup({
    required this.name,
    required this.label,
    required this.options,
  });

  /// Symbol name for the group itself.
  final String name;

  /// Display label.
  final String label;

  /// Selectable options. `DEFAULT` means "none of the others".
  final List<({String name, String label})> options;

  /// Option symbols excluding the `DEFAULT` sentinel - the ones that actually
  /// become preprocessor defines when selected.
  List<String> get selectableSymbols => [
        for (final option in options)
          if (option.name != 'DEFAULT') option.name,
      ];

  @override
  String toString() => 'settingGroup $name (${options.length} options)';
}

/// How a value is converted before being written to a log.
enum IniDatalogType { integer, float }

/// One column of the datalog, from the `[Datalog]` section.
///
/// The definition - not FoxTune - decides what gets logged and what each column
/// is called, because tools like MegaLogViewer key off specific column names.
class IniDatalogEntry {
  const IniDatalogEntry({
    required this.channel,
    required this.label,
    required this.type,
    required this.format,
    this.labelExpression,
    this.condition,
  });

  /// Output channel to log. Case sensitive.
  final String channel;

  /// Column heading written to the log's header line.
  ///
  /// When the definition supplies an expression instead of a literal - an
  /// aliased auxiliary input, say - this falls back to [channel] and the
  /// source is kept in [labelExpression].
  final String label;

  /// The unevaluated label expression, when the definition used one.
  final String? labelExpression;

  /// Whether the value is written as an integer or a decimal.
  final IniDatalogType type;

  /// C-style format string, e.g. `%.3f`.
  final String format;

  /// Expression gating whether this column is logged at all.
  ///
  /// Typically tests a configuration constant, so a log does not carry columns
  /// for hardware that is not fitted.
  final String? condition;

  /// Decimal places implied by [format].
  int get decimals {
    final match = RegExp(r'%\.(\d+)f').firstMatch(format);
    if (match != null) return int.parse(match.group(1)!);
    return 0;
  }

  @override
  String toString() => 'entry $channel as "$label"';
}
