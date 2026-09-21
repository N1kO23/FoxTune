import 'package:flutter/material.dart';

import 'bar_gauge.dart';
import 'gauge_catalog.dart';
import 'layout/dashboard_layout.dart';
import 'meter_gauge.dart';
import 'sample_history.dart';
import 'stat_tile.dart';
import 'time_graph.dart';

/// Draws one placed gauge, scaled to fill the space it is given.
///
/// Every gauge is laid out at its design size - its cells times the design
/// cell of its page's grid - and then scaled, whole, to the space it actually
/// has.
class GaugeView extends StatelessWidget {
  const GaugeView({
    super.key,
    required this.placement,
    required this.designCell,
    required this.catalog,
    required this.history,
  });

  final GaugePlacement placement;

  /// The size one grid square of its page is laid out at.
  final double designCell;

  final GaugeCatalog catalog;
  final SampleHistory history;

  @override
  Widget build(BuildContext context) {
    final design = Size(
      placement.width * designCell,
      placement.height * designCell,
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
        final indicator = catalog.indicatorFor(placement.indicator);
        if (indicator == null) {
          return _Missing(what: placement.indicator ?? 'indicator');
        }
        final on = catalog.isOn(indicator);
        return FlagLamp(
          label: on ?? false ? indicator.onLabel : indicator.offLabel,
          on: on,
          onColor: GaugeCatalog.colorFor(indicator.onBackground),
          expand: true,
        );

      case GaugeStyle.graph:
        final lanes = [
          for (final ref in placement.gauges) ?catalog.specOf(ref),
        ];
        if (lanes.isEmpty) {
          return _Missing(what: placement.gauges.join(', '));
        }
        return TimeGraph(
          lanes: lanes,
          history: history,
          window: Duration(seconds: placement.windowSeconds),
        );

      case GaugeStyle.dial:
      case GaugeStyle.bar:
      case GaugeStyle.digital:
        final ref = placement.gauges.firstOrNull;
        final spec = ref == null ? null : catalog.specOf(ref);
        if (spec == null) {
          return _Missing(
            what: ref == null ? 'gauge' : (GaugeRef.channelOf(ref) ?? ref),
          );
        }

        final value = catalog.readingOf(ref!);
        return switch (placement.style) {
          GaugeStyle.dial => Center(
            child: MeterGauge(spec: spec, value: value),
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
