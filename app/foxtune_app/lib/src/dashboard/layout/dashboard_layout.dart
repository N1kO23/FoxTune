/// How a placed gauge is drawn.
///
/// Each style knows the size it is placed at and the smallest it can be made
/// before its content stops fitting. Sizes are in grid cells.
enum GaugeStyle {
  dial(label: 'Dial', width: 4, height: 4, minWidth: 3, minHeight: 3),
  bar(label: 'Bar', width: 4, height: 1, minWidth: 1, minHeight: 1),
  digital(label: 'Digital', width: 3, height: 2, minWidth: 2, minHeight: 1),
  lamp(label: 'Lamp', width: 3, height: 1, minWidth: 2, minHeight: 1),
  graph(label: 'Time graph', width: 6, height: 3, minWidth: 4, minHeight: 2);

  const GaugeStyle({
    required this.label,
    required this.width,
    required this.height,
    required this.minWidth,
    required this.minHeight,
  });

  /// Shown in pickers.
  final String label;

  /// Size a new gauge of this style is placed at.
  final int width;
  final int height;

  /// Smallest it can be resized to.
  final int minWidth;
  final int minHeight;

  /// Styles a numeric gauge can switch between. A lamp shows an indicator,
  /// which is on or off and has no number to put on a dial.
  static const numeric = [dial, bar, digital, graph];

  static GaugeStyle byName(String name) =>
      values.firstWhere((s) => s.name == name, orElse: () => digital);
}

/// Time windows a graph can show, in seconds.
const graphWindows = [10, 30, 60, 120];

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
  });

  /// Stable identity, for editing.
  final String id;

  final GaugeStyle style;

  /// Grid position and size, in cells.
  final int x;
  final int y;
  final int width;
  final int height;

  /// `[GaugeConfigurations]` names shown. One for a dial, bar or digital
  /// readout; one to four for a graph.
  final List<String> gauges;

  /// The expression of the `[FrontPage]` indicator a lamp shows.
  ///
  /// Indicators have no names, so the expression is what identifies one. It is
  /// also what stays the same when a firmware update rewords the label.
  final String? indicator;

  /// How much history a graph shows.
  final int windowSeconds;

  GaugePlacement copyWith({
    GaugeStyle? style,
    int? x,
    int? y,
    int? width,
    int? height,
    List<String>? gauges,
    String? indicator,
    int? windowSeconds,
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
  };

  /// Reads a placement back, or returns `null` for one too damaged to use.
  static GaugePlacement? fromJson(Object? json) {
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
      x: x,
      y: y,
      width: w,
      height: h,
      gauges: [
        for (final g in (json['gauges'] as List?) ?? const [])
          if (g is String) g,
      ],
      indicator: json['indicator'] as String?,
      windowSeconds: (json['window'] as int?) ?? 30,
    );
  }
}

/// A named page of gauges.
class DashboardPage {
  const DashboardPage({
    required this.id,
    required this.name,
    this.items = const [],
  });

  final String id;
  final String name;
  final List<GaugePlacement> items;

  /// Rows the page's content reaches down to.
  int get rows => items.fold(0, (deepest, item) {
    final bottom = item.y + item.height;
    return bottom > deepest ? bottom : deepest;
  });

  DashboardPage copyWith({String? name, List<GaugePlacement>? items}) =>
      DashboardPage(
        id: id,
        name: name ?? this.name,
        items: items ?? this.items,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'items': [for (final item in items) item.toJson()],
  };

  static DashboardPage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) return null;
    return DashboardPage(
      id: id,
      name: name,
      items: [
        for (final item in (json['items'] as List?) ?? const [])
          ?GaugePlacement.fromJson(item),
      ],
    );
  }
}

/// Every page of the dashboard, for one ECU family.
class DashboardLayout {
  const DashboardLayout({required this.pages});

  /// Version of the saved format, so a later change can read an older file.
  static const formatVersion = 1;

  final List<DashboardPage> pages;

  DashboardPage? pageById(String id) =>
      pages.where((p) => p.id == id).firstOrNull;

  Map<String, Object?> toJson() => {
    'version': formatVersion,
    'pages': [for (final page in pages) page.toJson()],
  };

  /// Reads a saved layout, or returns `null` for one that cannot be used.
  static DashboardLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    final pages = [
      for (final page in (json['pages'] as List?) ?? const [])
        ?DashboardPage.fromJson(page),
    ];
    return pages.isEmpty ? null : DashboardLayout(pages: pages);
  }
}
