import 'dart:math' as math;

import '../gauge_appearance.dart';
import '../gauge_status.dart';

/// The width of a phone held upright, in design pixels: the narrowest page,
/// and the unit the wider ones are measured in.
///
/// Every gauge is drawn at a size worked out in design pixels and then scaled,
/// whole, to the space it actually has. So a page looks the same on every
/// screen it fits - larger or smaller, but not rearranged, and never with text
/// that fits on one and overflows on the other.
const phonePageWidth = 480.0;

/// How wide a page is laid out.
///
/// A wider page holds more gauges side by side at the same size; it does not
/// make them bigger. On a screen narrower than the page, the whole page
/// shrinks to fit.
enum PageWidth {
  phone('Phone', 1),
  tablet('Tablet', 2),
  laptop('Laptop', 3),
  monitor('Large monitor', 4);

  const PageWidth(this.label, this.phones);

  final String label;

  /// How many phone widths across.
  final int phones;

  /// The page's width in design pixels.
  double get designWidth => phonePageWidth * phones;

  static PageWidth byName(Object? name) =>
      values.firstWhere((w) => w.name == name, orElse: () => phone);
}

/// How fine a page's grid can be: squares across one phone's width.
///
/// A finer grid places and sizes gauges in smaller steps; it does not change
/// their size. Each is a multiple of twelve so moving between them keeps most
/// edges where they were.
const gridDensityChoices = [12, 24, 36, 48];

/// The grid a new page starts on.
const defaultGridDensity = 24;

/// The size one grid square is laid out at, on a grid [density] squares
/// across a phone's width.
double designCellFor(int density) => phonePageWidth / density;

/// How a placed gauge is drawn.
///
/// Each style knows the size it is placed at and the smallest it can be made
/// before its content stops fitting. Both are in design pixels, not cells, so
/// a dial is the same size on the page whatever grid the page uses - a finer
/// grid only lets it be nudged in smaller steps.
enum GaugeStyle {
  dial(label: 'Dial', width: 160, height: 160, minWidth: 120, minHeight: 120),
  bar(label: 'Bar', width: 160, height: 40, minWidth: 40, minHeight: 40),
  digital(
    label: 'Digital',
    width: 120,
    height: 80,
    minWidth: 80,
    minHeight: 40,
  ),
  lamp(label: 'Lamp', width: 120, height: 40, minWidth: 60, minHeight: 20),
  graph(
    label: 'Time graph',
    width: 240,
    height: 120,
    minWidth: 160,
    minHeight: 80,
  );

  const GaugeStyle({
    required this.label,
    required this.width,
    required this.height,
    required this.minWidth,
    required this.minHeight,
  });

  /// Shown in pickers.
  final String label;

  /// Size a new gauge of this style is placed at, in design pixels.
  final double width;
  final double height;

  /// Smallest it can be resized to, in design pixels.
  final double minWidth;
  final double minHeight;

  /// The size a new gauge takes, in squares of a grid [density] squares
  /// across a phone's width.
  ({int width, int height}) sizeIn(int density) =>
      (width: _cells(width, density), height: _cells(height, density));

  /// The smallest it can be, in squares of a grid [density] across a phone.
  ({int width, int height}) minimumIn(int density) =>
      (width: _cells(minWidth, density), height: _cells(minHeight, density));

  static int _cells(double pixels, int density) =>
      // The epsilon keeps an exact fit - 160 over 40 - from rounding up.
      math.max(1, (pixels / designCellFor(density) - 1e-9).ceil());

  /// Styles a numeric gauge can switch between. A lamp shows an indicator,
  /// which is on or off and has no number to put on a dial.
  static const numeric = [dial, bar, digital, graph];

  static GaugeStyle byName(String name) =>
      values.firstWhere((s) => s.name == name, orElse: () => digital);
}

/// Time windows a graph can show, in seconds.
const graphWindows = [10, 30, 60, 120];

/// Names what a numeric gauge shows.
///
/// Most references are the name of a `[GaugeConfigurations]` gauge. A live
/// channel the definition has no gauge for is referenced as `channel:<name>`:
/// gauge and channel names overlap - `batteryVoltage` is both - so the prefix
/// is what keeps the two apart.
abstract final class GaugeRef {
  static const _channelPrefix = 'channel:';

  /// The reference for a bare output channel.
  static String channel(String name) => '$_channelPrefix$name';

  /// The channel [ref] names, or `null` if it names a defined gauge.
  static String? channelOf(String ref) => ref.startsWith(_channelPrefix)
      ? ref.substring(_channelPrefix.length)
      : null;
}

/// Range, alarm points and precision a tuner has set for one gauge.
///
/// Replaces what the definition says, whole: a band left out here is off, even
/// if the definition has one. Partial overrides would leave no way to switch a
/// definition's band off - which is exactly what some of them need.
class GaugeLimits {
  const GaugeLimits({
    required this.min,
    required this.max,
    required this.decimals,
    this.dangerBelow,
    this.warnBelow,
    this.warnAbove,
    this.dangerAbove,
    this.temperatureUnit,
  });

  final double min;
  final double max;
  final int decimals;
  final double? dangerBelow;
  final double? warnBelow;
  final double? warnAbove;
  final double? dangerAbove;

  /// The scale these were set in, for a gauge reading a temperature; `null`
  /// for any other.
  ///
  /// The numbers mean nothing without it. Switching between Celsius and
  /// Fahrenheit changes what the gauge reads, and a danger point of 105 has
  /// to become 221 along with it - see [inUnits].
  final TemperatureUnit? temperatureUnit;

  /// These limits, for a gauge whose units are [gaugeUnits].
  ///
  /// Converted where the gauge reads the other temperature scale from the one
  /// they were set in. Limits set before the scale was recorded count as
  /// Celsius, the only one FoxTune had.
  GaugeLimits inUnits(String gaugeUnits) {
    final target = TemperatureUnit.ofUnits(gaugeUnits);
    final from = temperatureUnit ?? TemperatureUnit.celsius;
    if (target == null || target == from) return this;
    double convert(double value) => from.convert(value, to: target);
    double? convertSet(double? value) => value == null ? null : convert(value);
    return GaugeLimits(
      min: convert(min),
      max: convert(max),
      decimals: decimals,
      dangerBelow: convertSet(dangerBelow),
      warnBelow: convertSet(warnBelow),
      warnAbove: convertSet(warnAbove),
      dangerAbove: convertSet(dangerAbove),
      temperatureUnit: target,
    );
  }

  /// Why these limits cannot be used, or `null` if they can.
  String? get problem {
    if (!min.isFinite || !max.isFinite) return 'Set both ends of the range.';
    if (max <= min) return 'The top of the range must be above the bottom.';
    if (decimals < 0 || decimals > 4) return 'Decimals must be 0 to 4.';
    if (dangerBelow case final low? when warnBelow != null) {
      if (low > warnBelow!) {
        return 'Low danger must be at or below low warning.';
      }
    }
    if (dangerAbove case final high? when warnAbove != null) {
      if (high < warnAbove!) {
        return 'High danger must be at or above high warning.';
      }
    }
    final lows = [?dangerBelow, ?warnBelow];
    final highs = [?warnAbove, ?dangerAbove];
    if (lows.isNotEmpty && highs.isNotEmpty) {
      if (lows.reduce(math.max) >= highs.reduce(math.min)) {
        return 'The low alarms must sit below the high ones, with room '
            'between them for a normal reading.';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'min': min,
    'max': max,
    'decimals': decimals,
    'dangerBelow': ?dangerBelow,
    'warnBelow': ?warnBelow,
    'warnAbove': ?warnAbove,
    'dangerAbove': ?dangerAbove,
    'temperature': ?temperatureUnit?.name,
  };

  static GaugeLimits? fromJson(Object? json) {
    if (json is! Map) return null;
    double? number(String key) => switch (json[key]) {
      final num n => n.toDouble(),
      _ => null,
    };
    final min = number('min');
    final max = number('max');
    final decimals = json['decimals'];
    if (min == null || max == null || decimals is! int) return null;
    final limits = GaugeLimits(
      min: min,
      max: max,
      decimals: decimals,
      dangerBelow: number('dangerBelow'),
      warnBelow: number('warnBelow'),
      warnAbove: number('warnAbove'),
      dangerAbove: number('dangerAbove'),
      temperatureUnit: TemperatureUnit.values.asNameMap()[json['temperature']],
    );
    return limits.problem == null ? limits : null;
  }
}

/// One gauge on a page.
class GaugePlacement {
  const GaugePlacement({
    required this.id,
    required this.style,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.gauges = const [],
    this.indicator,
    this.windowSeconds = 30,
    this.appearance = const GaugeAppearance(),
  });

  /// Stable identity, for editing.
  final String id;

  final GaugeStyle style;

  /// Grid position and size, in cells.
  final int x;
  final int y;
  final int width;
  final int height;

  /// What is shown, as [GaugeRef] references. One for a dial, bar or digital
  /// readout; one to four for a graph.
  final List<String> gauges;

  /// The expression a lamp shows: a `[FrontPage]` indicator's, or the name of
  /// a one-bit status channel.
  ///
  /// Indicators have no names, so the expression is what identifies one. It is
  /// also what stays the same when a firmware update rewords the label.
  final String? indicator;

  /// How much history a graph shows.
  final int windowSeconds;

  /// How this gauge looks where it differs from the default in the app
  /// settings. Empty for one that follows the default in everything.
  ///
  /// Kept whole when the gauge is switched to another style, so switching it
  /// back finds its dial or its bar as it was left.
  final GaugeAppearance appearance;

  GaugePlacement copyWith({
    GaugeStyle? style,
    int? x,
    int? y,
    int? width,
    int? height,
    List<String>? gauges,
    String? indicator,
    int? windowSeconds,
    GaugeAppearance? appearance,
  }) => GaugePlacement(
    id: id,
    style: style ?? this.style,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    gauges: gauges ?? this.gauges,
    indicator: indicator ?? this.indicator,
    windowSeconds: windowSeconds ?? this.windowSeconds,
    appearance: appearance ?? this.appearance,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'style': style.name,
    'x': x,
    'y': y,
    'w': width,
    'h': height,
    if (gauges.isNotEmpty) 'gauges': gauges,
    if (indicator != null) 'indicator': indicator,
    if (style == GaugeStyle.graph) 'window': windowSeconds,
    if (!appearance.isEmpty) 'look': appearance.toJson(),
  };

  /// Reads a placement back, or returns `null` for one too damaged to use.
  ///
  /// [scale] multiplies the geometry, for a page saved on a coarser grid.
  static GaugePlacement? fromJson(Object? json, {int scale = 1}) {
    if (json is! Map) return null;
    final id = json['id'];
    final x = json['x'];
    final y = json['y'];
    final w = json['w'];
    final h = json['h'];
    if (id is! String || x is! int || y is! int || w is! int || h is! int) {
      return null;
    }
    return GaugePlacement(
      id: id,
      style: GaugeStyle.byName('${json['style']}'),
      x: x * scale,
      y: y * scale,
      width: w * scale,
      height: h * scale,
      gauges: [
        for (final g in (json['gauges'] as List?) ?? const [])
          if (g is String) g,
      ],
      indicator: json['indicator'] as String?,
      windowSeconds: (json['window'] as int?) ?? 30,
      appearance: GaugeAppearance.fromJson(json['look']),
    );
  }
}

/// A named page of gauges.
class DashboardPage {
  const DashboardPage({
    required this.id,
    required this.name,
    this.density = defaultGridDensity,
    this.width = PageWidth.phone,
    this.items = const [],
  });

  final String id;
  final String name;

  /// Grid squares across one phone's width. See [gridDensityChoices].
  final int density;

  /// How wide the page is laid out.
  final PageWidth width;

  final List<GaugePlacement> items;

  /// Grid squares across the whole page.
  int get columns => density * width.phones;

  /// The size one square is laid out at, before scaling to the screen.
  double get designCell => designCellFor(density);

  /// Rows the page's content reaches down to.
  int get rows => items.fold(0, (deepest, item) {
    final bottom = item.y + item.height;
    return bottom > deepest ? bottom : deepest;
  });

  DashboardPage copyWith({
    String? name,
    int? density,
    PageWidth? width,
    List<GaugePlacement>? items,
  }) => DashboardPage(
    id: id,
    name: name ?? this.name,
    density: density ?? this.density,
    width: width ?? this.width,
    items: items ?? this.items,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'density': density,
    'width': width.name,
    'items': [for (final item in items) item.toJson()],
  };

  static DashboardPage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;

    // Version 2 called the density "columns", when every page was a phone's
    // width and the two were the same number.
    final saved = json['density'] ?? json['columns'];
    // Version 1 pages were all twelve across. Doubling them onto the default
    // grid is exact - every edge lands on a line of the finer grid - so they
    // keep their look and gain the finer steps.
    final legacy = saved == null;
    final density = legacy
        ? 12 * 2
        : (saved is int && gridDensityChoices.contains(saved)
              ? saved
              : defaultGridDensity);
    return DashboardPage(
      id: id,
      name: name,
      density: density,
      width: PageWidth.byName(json['width']),
      items: [
        for (final item in (json['items'] as List?) ?? const [])
          ?GaugePlacement.fromJson(item, scale: legacy ? 2 : 1),
      ],
    );
  }
}

/// Every page of the dashboard, for one ECU family.
class DashboardLayout {
  const DashboardLayout({required this.pages, this.limits = const {}});

  /// Version of the saved format, so a later change can read an older file.
  ///
  /// 2 added per-page grids and gauge limits, 3 page widths, 4 each gauge's
  /// own look. Older files still load.
  static const formatVersion = 4;

  final List<DashboardPage> pages;

  /// Limits the tuner has set, by [GaugeRef].
  ///
  /// Kept for the whole dashboard rather than per placement: a limit belongs
  /// to the gauge, so a coolant warning moved on one page is moved on all of
  /// them - and on every lane of every graph showing coolant.
  final Map<String, GaugeLimits> limits;

  DashboardPage? pageById(String id) =>
      pages.where((p) => p.id == id).firstOrNull;

  DashboardLayout copyWith({
    List<DashboardPage>? pages,
    Map<String, GaugeLimits>? limits,
  }) => DashboardLayout(
    pages: pages ?? this.pages,
    limits: limits ?? this.limits,
  );

  Map<String, Object?> toJson() => {
    'version': formatVersion,
    'pages': [for (final page in pages) page.toJson()],
    if (limits.isNotEmpty)
      'limits': {
        for (final entry in limits.entries) entry.key: entry.value.toJson(),
      },
  };

  /// Reads a saved layout, or returns `null` for one that cannot be used.
  static DashboardLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    final pages = [
      for (final page in (json['pages'] as List?) ?? const [])
        ?DashboardPage.fromJson(page),
    ];
    final savedLimits = json['limits'];
    return pages.isEmpty
        ? null
        : DashboardLayout(
            pages: pages,
            limits: {
              if (savedLimits is Map)
                for (final MapEntry(:key, :value) in savedLimits.entries)
                  if (key is String) key: ?GaugeLimits.fromJson(value),
            },
          );
  }
}
