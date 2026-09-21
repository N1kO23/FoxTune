import 'package:foxtune_ini/foxtune_ini.dart';

import 'dashboard_layout.dart';
import 'grid.dart';

var _sequence = 0;

/// A new identifier for a page or placement.
String newLayoutId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
    '${(_sequence++).toRadixString(36)}';

/// Channels worth a number on the first page that `[FrontPage]` leaves off.
///
/// Speeduino's front page has no AFR, which is the first thing a tuner looks
/// for. These are the readouts FoxTune's dashboard has always shown; each is
/// looked up in `[GaugeConfigurations]` by channel, so its range, units and
/// limits still come from the definition, and one the definition has no gauge
/// for is simply left out.
const _extraReadouts = [
  'afr',
  'batteryVoltage',
  'advance',
  'VE1',
  'egoCorrection',
];

/// How many `[FrontPage]` indicators the first page starts with.
///
/// The section lists over fifty, most for hardware few engines have. The
/// first twelve are the engine's own state - running, cranking, enrichments,
/// errors - which is what a first page should show; the rest are one tap away
/// in the gauge picker.
const _startingIndicators = 12;

/// The first page, built from the definition's own front page.
DashboardPage defaultPage(IniDocument definition, {String name = 'Main'}) {
  var page = DashboardPage(id: newLayoutId(), name: name);

  void place(GaugeStyle style, {String? gauge, String? indicator}) {
    final spot = firstFreeSpot(page, style.width, style.height);
    page = page.copyWith(
      items: [
        ...page.items,
        GaugePlacement(
          id: newLayoutId(),
          style: style,
          x: spot.x,
          y: spot.y,
          width: spot.width,
          height: spot.height,
          gauges: gauge == null ? const [] : [gauge],
          indicator: indicator,
        ),
      ],
    );
  }

  final shown = <String>{};
  for (final name in definition.frontPage.gauges) {
    final gauge = definition.gaugeNamed(name);
    if (gauge == null) continue;
    place(GaugeStyle.dial, gauge: name);
    shown.add(gauge.channel);
  }

  for (final channel in _extraReadouts) {
    if (shown.contains(channel)) continue;
    final gauge = definition.gaugeForChannel(channel);
    if (gauge == null) continue;
    place(GaugeStyle.digital, gauge: gauge.name);
    shown.add(channel);
  }

  for (final indicator in definition.frontPage.indicators.take(
    _startingIndicators,
  )) {
    place(GaugeStyle.lamp, indicator: indicator.expression);
  }

  return page;
}

/// A whole dashboard for a definition nobody has arranged yet.
DashboardLayout defaultLayout(IniDocument definition) =>
    DashboardLayout(pages: [defaultPage(definition)]);
