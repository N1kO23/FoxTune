import 'package:flutter/material.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import 'bar_gauge.dart';
import 'gauge_catalog.dart';
import 'layout/dashboard_layout.dart';
import 'meter_gauge.dart';
import 'sample_history.dart';
import 'stat_tile.dart';
import 'time_graph.dart';

/// The size one grid cell is laid out at, before scaling to the screen.
///
/// Every gauge is drawn at this design size and then scaled, whole, to the
/// cell it actually has. So a page looks the same on a phone and a laptop -
/// larger or smaller, but not rearranged, and never with text that fits on
/// one and overflows on the other.
const designCellSize = 40.0;

/// Draws one placed gauge, scaled to fill the space it is given.
class GaugeView extends StatelessWidget {
  const GaugeView({
    super.key,
    required this.placement,
    required this.definition,
    required this.catalog,
    required this.history,
  });

  final GaugePlacement placement;
  final IniDocument definition;
  final GaugeCatalog catalog;
  final SampleHistory history;

  @override
  Widget build(BuildContext context) {
    final design = Size(
      placement.width * designCellSize,
      placement.height * designCellSize,
    );
    return FittedBox(
      child: SizedBox.fromSize(
        size: design,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _content(context, design),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, Size design) {
    switch (placement.style) {
      case GaugeStyle.lamp:
        final indicator = definition.frontPage.indicators
            .where((i) => i.expression == placement.indicator)
            .firstOrNull;
        if (indicator == null) {
          return _Missing(what: placement.indicator ?? 'indicator');
        }
        final on = catalog.isOn(indicator);
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: FlagLamp(
              label: on ?? false ? indicator.onLabel : indicator.offLabel,
              on: on,
              onColor: GaugeCatalog.colorFor(indicator.onBackground),
            ),
          ),
        );

      case GaugeStyle.graph:
        final gauges = [
          for (final name in placement.gauges) ?definition.gaugeNamed(name),
        ];
        if (gauges.isEmpty) {
          return _Missing(what: placement.gauges.join(', '));
        }
        return TimeGraph(
          lanes: [for (final gauge in gauges) catalog.specFor(gauge)],
          history: history,
          window: Duration(seconds: placement.windowSeconds),
        );

      case GaugeStyle.dial:
      case GaugeStyle.bar:
      case GaugeStyle.digital:
        final name = placement.gauges.firstOrNull;
        final gauge = name == null ? null : definition.gaugeNamed(name);
        if (gauge == null) return _Missing(what: name ?? 'gauge');

        final spec = catalog.specFor(gauge);
        final value = catalog.valueOf(gauge);
        return switch (placement.style) {
          GaugeStyle.dial => Center(
            child: MeterGauge(
              spec: spec,
              value: value,
              // The full-size value only fits a roomy dial.
              compact: design.shortestSide < 160,
            ),
          ),
          GaugeStyle.bar => BarGauge(spec: spec, value: value),
          // The tile sizes its own height; give it the width and let it
          // shrink if its content runs taller than the space.
          _ => FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: design.width - 6,
              child: StatTile(spec: spec, value: value),
            ),
          ),
        };
    }
  }
}

/// A gauge this definition does not have.
///
/// A layout outlives firmware versions, and a gauge the current definition
/// has dropped is shown as missing rather than vanishing - so its place on the
/// page, and the fact it was there, are not lost without a word.
class _Missing extends StatelessWidget {
  const _Missing({required this.what});

  final String what;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(6),
      child: Center(
        child: Text(
          '$what is not in this ECU definition',
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
