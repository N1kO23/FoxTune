import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../logging/record_button.dart';
import '../tune/tune_controller.dart';
import 'dashboard_controller.dart';
import 'gauge_status.dart';
import 'meter_gauge.dart';
import 'stat_tile.dart';

/// The live gauge cluster.
///
/// Read-only by construction: nothing here can change the tune. That is what
/// makes it safe to hand to someone with an engine running.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, required this.connection});

  final EcuConnected connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sample = ref.watch(realtimeProvider);
    final monitor = ref.watch(realtimeMonitorProvider);
    final snapshot = sample.valueOrNull;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 600;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusBar(
              connection: connection,
              monitor: monitor,
              hasData: snapshot != null,
            ),
            const SizedBox(height: 16),
            if (snapshot == null)
              const _WaitingForData()
            else ...[
              _MeterRow(snapshot: snapshot, narrow: narrow),
              const SizedBox(height: 20),
              _FlagRow(snapshot: snapshot),
              const SizedBox(height: 20),
              _TileGrid(snapshot: snapshot, width: constraints.maxWidth),
            ],
          ],
        );
      },
    );
  }
}

class _WaitingForData extends StatelessWidget {
  const _WaitingForData();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 64),
    child: Column(
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Waiting for the first realtime sample...'),
      ],
    ),
  );
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.connection,
    required this.monitor,
    required this.hasData,
  });

  final EcuConnected connection;
  final RealtimeMonitor? monitor;
  final bool hasData;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stalled = monitor != null && !monitor!.isRunning && hasData;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  stalled ? Icons.link_off : Icons.link,
                  size: 16,
                  color: stalled ? StatusPalette.critical : StatusPalette.good,
                ),
                const SizedBox(width: 6),
                Text(
                  stalled ? 'Polling stopped' : 'Live',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: stalled ? StatusPalette.critical : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Text(
              connection.identification.signature,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (monitor != null)
              Text(
                // The achieved rate, not the requested one.
                '${monitor!.measuredHz.toStringAsFixed(1)} Hz · '
                '${monitor!.pollCount} polls',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            const RecordButton(),
            if (!ref.watch(writePermissionProvider).allowed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Read-only',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MeterRow extends ConsumerWidget {
  const _MeterRow({required this.snapshot, required this.narrow});

  final RealtimeSnapshot snapshot;
  final bool narrow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meters = DefaultGauges.primary(ref.watch(temperatureUnitProvider));
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      alignment: WrapAlignment.center,
      children: [
        for (final spec in meters)
          SizedBox(
            width: narrow ? 150 : 200,
            child: MeterGauge(
              spec: spec,
              value: snapshot[spec.channel],
              compact: narrow,
            ),
          ),
      ],
    );
  }
}

class _FlagRow extends StatelessWidget {
  const _FlagRow({required this.snapshot});

  final RealtimeSnapshot snapshot;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final flag in DefaultGauges.flags)
        FlagLamp(label: flag.label, on: snapshot.flag(flag.channel)),
    ],
  );
}

class _TileGrid extends ConsumerWidget {
  const _TileGrid({required this.snapshot, required this.width});

  final RealtimeSnapshot snapshot;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = DefaultGauges.secondary(ref.watch(temperatureUnitProvider));
    // Roughly 160px per tile, at least two across even on a phone.
    final columns = (width / 170).floor().clamp(2, 6);
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: tiles.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        mainAxisExtent: 104,
      ),
      itemBuilder: (context, index) {
        final spec = tiles[index];
        return StatTile(spec: spec, value: snapshot[spec.channel]);
      },
    );
  }
}
