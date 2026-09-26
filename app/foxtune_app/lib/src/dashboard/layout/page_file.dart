import 'dart:convert';

import 'package:foxtune_ini/foxtune_ini.dart';

import '../../storage/json_store.dart' show ecuFamily;
import '../gauge_catalog.dart';
import 'dashboard_layout.dart';
import 'default_layout.dart' show newLayoutId;
import 'grid.dart';

/// The extension a dashboard page is saved under.
const dashboardPageExtension = 'foxdash';

/// A file that cannot be read as a dashboard page.
class PageFileException implements Exception {
  const PageFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One dashboard page as a file, to keep, share or take to another ECU.
///
/// The page as the layout saves it - its width, its grid, its gauges and each
/// gauge's own look - with the limits the tuner set for the gauges on it, and
/// the signature of the ECU it was made on. Limits belong to the layout
/// rather than to a page, so only those for gauges on this page go with it.
///
/// The default look in the app settings does not: it is the reader's own, and
/// a gauge left following it follows theirs.
class DashboardPageFile {
  const DashboardPageFile({
    required this.page,
    this.limits = const {},
    this.ecu,
  });

  /// [page] of [layout], made on the ECU [definition] describes.
  factory DashboardPageFile.of(
    DashboardPage page,
    DashboardLayout layout,
    IniDocument definition,
  ) {
    final shown = {for (final item in page.items) ...item.gauges};
    return DashboardPageFile(
      page: page,
      limits: {
        for (final MapEntry(:key, :value) in layout.limits.entries)
          if (shown.contains(key)) key: value,
      },
      ecu: definition.identity.signature,
    );
  }

  static const _kind = 'foxtune-dashboard-page';

  final DashboardPage page;

  /// Limits the tuner set, by [GaugeRef], for gauges on [page].
  final Map<String, GaugeLimits> limits;

  /// The signature of the ECU the page was made on, where the file says.
  final String? ecu;

  /// Whether the page was made on the same family of ECU as [definition]
  /// describes - so everything on it should be there.
  bool isFor(IniDocument definition) =>
      ecu != null && ecuFamily(ecu) == ecuFamily(definition.identity.signature);

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'kind': _kind,
    'version': DashboardLayout.formatVersion,
    'ecu': ?ecu,
    'page': page.toJson(),
    if (limits.isNotEmpty)
      'limits': {
        for (final MapEntry(:key, :value) in limits.entries)
          key: value.toJson(),
      },
  });

  /// Reads what [encode] wrote.
  ///
  /// Throws [PageFileException] for anything else. A gauge or a limit too
  /// damaged to use is left out rather than costing the page, as it is when a
  /// saved layout loads.
  static DashboardPageFile decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw const PageFileException('This is not a FoxTune dashboard page.');
    }
    if (json is! Map || json['kind'] != _kind) {
      throw const PageFileException('This is not a FoxTune dashboard page.');
    }
    final page = DashboardPage.fromJson(json['page']);
    if (page == null) {
      throw const PageFileException('The page in this file could not be read.');
    }
    final limits = json['limits'];
    final ecu = json['ecu'];
    return DashboardPageFile(
      page: page,
      limits: {
        if (limits is Map)
          for (final MapEntry(:key, :value) in limits.entries)
            if (key is String) key: ?GaugeLimits.fromJson(value),
      },
      ecu: ecu is String ? ecu : null,
    );
  }

  /// The page as it can be added to a dashboard for the ECU [definition]
  /// describes.
  ///
  /// What the definition has is kept, and nothing else: a gauge showing
  /// something it lacks is left out, and so is a graph's lane - a graph goes
  /// only once it has no lane left. The page and its gauges get identities of
  /// their own, and every gauge is put on the grid clear of the rest.
  PageImport fitTo(IniDocument definition) {
    final catalog = GaugeCatalog(definition: definition);
    final missing = <String>{};
    final kept = <GaugePlacement>[];

    for (final item in page.items) {
      if (item.style == GaugeStyle.lamp) {
        if (catalog.indicatorFor(item.indicator) == null) {
          missing.add(item.indicator ?? 'an indicator');
        } else {
          kept.add(_renamed(item));
        }
        continue;
      }
      final found = <String>[];
      for (final ref in item.gauges) {
        if (catalog.definedSpecOf(ref) != null) {
          found.add(ref);
        } else {
          missing.add(GaugeRef.channelOf(ref) ?? ref);
        }
      }
      if (found.isNotEmpty) kept.add(_renamed(item, gauges: found));
    }

    final shown = {for (final item in kept) ...item.gauges};
    return PageImport(
      page: settlePage(
        DashboardPage(
          id: newLayoutId(),
          name: page.name,
          density: page.density,
          width: page.width,
          items: kept,
        ),
      ),
      limits: {
        for (final MapEntry(:key, :value) in limits.entries)
          if (shown.contains(key)) key: value,
      },
      missing: missing.toList(),
    );
  }

  static GaugePlacement _renamed(GaugePlacement item, {List<String>? gauges}) =>
      GaugePlacement(
        id: newLayoutId(),
        style: item.style,
        x: item.x,
        y: item.y,
        width: item.width,
        height: item.height,
        gauges: gauges ?? item.gauges,
        indicator: item.indicator,
        windowSeconds: item.windowSeconds,
        appearance: item.appearance,
      );
}

/// A page from a file, fitted to one ECU's definition. See
/// [DashboardPageFile.fitTo].
class PageImport {
  const PageImport({
    required this.page,
    required this.limits,
    required this.missing,
  });

  final DashboardPage page;

  /// Limits for gauges on [page].
  final Map<String, GaugeLimits> limits;

  /// What the file's page shows that the definition does not have, named as
  /// the dashboard names a missing gauge. Left out of [page].
  final List<String> missing;
}
