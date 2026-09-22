import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import 'bar_gauge.dart';
import 'dashboard_controller.dart';
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
///
/// Each gauge follows the realtime feed itself, and rebuilds only when what it
/// shows has changed. The page around it is not rebuilt per sample, and a lamp
/// that stays off or a temperature that holds costs nothing while the rest of
/// the page moves.
class GaugeView extends ConsumerWidget {
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

  /// The page's catalog, without a sample: each gauge adds the latest itself.
  final GaugeCatalog catalog;
  final SampleHistory history;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    watchWhileVisible(
      ref,
      context,
      realtimeProvider.select(
        (live) => _shown(catalog.withRealtime(live.valueOrNull)),
      ),
    );
    final live = catalog.withRealtime(ref.read(realtimeProvider).valueOrNull);

    final design = Size(
      placement.width * designCell,
      placement.height * designCell,
    );
    return FittedBox(
      child: SizedBox.fromSize(
        size: design,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _content(context, design, live),
        ),
      ),
    );
  }

  /// What this gauge draws from a sample, compared from one sample to the
  /// next to decide whether it needs rebuilding.
  Object? _shown(GaugeCatalog live) {
    switch (placement.style) {
      case GaugeStyle.lamp:
        final indicator = live.indicatorFor(placement.indicator);
        if (indicator == null) return null;
        final on = live.isOn(indicator);
        return (
          on,
          indicatorLabel(
            indicator,
            on: on ?? false,
            definition: live.definition,
            resolve: live.resolveLive,
          ),
        );

      case GaugeStyle.graph:
        // The traces follow the history without a rebuild; see TimeGraph.
        return null;

      case GaugeStyle.dial:
      case GaugeStyle.bar:
      case GaugeStyle.digital:
        final ref = placement.gauges.firstOrNull;
        final spec = ref == null ? null : live.specOf(ref);
        if (spec == null) return null;
        // The limits as well as the reading: expression limits can follow
        // live values.
        return (
          live.readingOf(ref!),
          spec.min,
          spec.max,
          spec.dangerBelow,
          spec.warnBelow,
          spec.warnAbove,
          spec.dangerAbove,
        );
    }
  }

  Widget _content(BuildContext context, Size design, GaugeCatalog catalog) {
    switch (placement.style) {
      case GaugeStyle.lamp:
        final indicator = catalog.indicatorFor(placement.indicator);
        if (indicator == null) {
          return _Missing(what: placement.indicator ?? 'indicator');
        }
        final on = catalog.isOn(indicator);
        return FlagLamp(
          label: indicatorLabel(
            indicator,
            on: on ?? false,
            definition: catalog.definition,
            resolve: catalog.resolveLive,
          ),
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
