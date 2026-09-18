import 'package:flutter/material.dart';

import 'gauge_status.dart';

/// A single reading as a number with its label and units.
///
/// The form heuristic calls for a stat tile rather than a chart for a single
/// current value, so the secondary channels are numbers with a thin magnitude
/// bar rather than ten more dials competing for attention.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.spec, required this.value});

  final GaugeSpec spec;
  final double? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = spec.statusFor(value);
    final accent = StatusPalette.forStatus(status, scheme);

    return Semantics(
      label:
          '${spec.label}: ${spec.format(value)} ${spec.units}'
          '${status.isAlarm ? ', ${StatusPalette.labelFor(status)}' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: status.isAlarm ? accent : scheme.outlineVariant,
            width: status.isAlarm ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    spec.label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status.isAlarm)
                  Icon(StatusPalette.iconFor(status), size: 13, color: accent),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  spec.format(value),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                if (spec.units.isNotEmpty) ...[
                  const SizedBox(width: 3),
                  Text(
                    spec.units,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            if (status.isAlarm)
              Text(
                StatusPalette.labelFor(status)!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(height: 6),
            // A thin magnitude track, recessive by design.
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: spec.fractionFor(value),
                minHeight: 3,
                backgroundColor: scheme.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An on/off indicator lamp for a status flag.
class FlagLamp extends StatelessWidget {
  const FlagLamp({super.key, required this.label, required this.on});

  final String label;
  final bool? on;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = on ?? false;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active
            ? StatusPalette.good.withValues(alpha: 0.14)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active ? StatusPalette.good : scheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Shape as well as colour: a filled circle when on, an outline when
          // off, so the state survives a colour-blind reading.
          Icon(
            active ? Icons.circle : Icons.circle_outlined,
            size: 9,
            color: active ? StatusPalette.good : scheme.outline,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: active ? scheme.onSurface : scheme.onSurfaceVariant,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
