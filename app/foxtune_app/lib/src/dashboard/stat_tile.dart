import 'package:flutter/material.dart';

import 'gauge_appearance.dart';
import 'gauge_status.dart';

/// A single reading as a number with its label and units.
///
/// The form heuristic calls for a stat tile rather than a chart for a single
/// current value, so the secondary channels are numbers with a thin magnitude
/// bar rather than ten more dials competing for attention.
///
/// [look] can take away its card and its bar, and make the number larger.
/// See [ReadoutLook].
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.spec,
    required this.value,
    this.look = GaugeAppearance.builtIn,
  });

  final GaugeSpec spec;
  final double? value;
  final GaugeAppearance look;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final readout = look.readout.resolved;
    final colours = look.colours;
    final status = spec.statusFor(value);
    final accent = colours.forStatus(status, normal: scheme.onSurface);
    final caption = theme.textTheme.labelSmall?.copyWith(
      color: colours.captionOn(scheme),
    );

    return Semantics(
      label:
          '${spec.label}: ${spec.format(value)} ${spec.units}'
          '${status.isAlarm ? ', ${StatusPalette.labelFor(status)}' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // Without its card an alarm loses the outline, but not its icon and
        // word.
        decoration: readout.framed
            ? BoxDecoration(
                color: colours.background ?? scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: status.isAlarm ? accent : scheme.outlineVariant,
                  width: status.isAlarm ? 1.5 : 1,
                ),
              )
            : BoxDecoration(
                color: colours.background,
                borderRadius: BorderRadius.circular(12),
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
                    style: caption,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status.isAlarm)
                  Icon(StatusPalette.iconFor(status), size: 13, color: accent),
              ],
            ),
            const SizedBox(height: 2),
            // Shrinks rather than overflows: a tile can be made narrow on a
            // dashboard page, and a long reading with long units - "13.80
            // volts" - must still show whole.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    spec.format(value),
                    style:
                        (readout.valueSize == ValueSize.large
                                ? theme.textTheme.headlineMedium
                                : theme.textTheme.titleLarge)
                            ?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w600,
                              color: colours.textOn(scheme),
                            ),
                  ),
                  if (spec.units.isNotEmpty) ...[
                    const SizedBox(width: 3),
                    Text(spec.units, style: caption),
                  ],
                ],
              ),
            ),
            if (status.isAlarm)
              Text(
                StatusPalette.labelFor(status)!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            // A thin magnitude track, recessive by design - and only where
            // there is a real range for it to measure against.
            if (readout.magnitudeBar && spec.hasRange) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: spec.fractionFor(value),
                  minHeight: 3,
                  backgroundColor:
                      colours.track ?? scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(accent),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// An on/off indicator lamp for a status flag.
class FlagLamp extends StatelessWidget {
  const FlagLamp({
    super.key,
    required this.label,
    required this.on,
    this.onColor,
    this.expand = false,
    this.look = GaugeAppearance.builtIn,
  });

  final String label;
  final bool? on;

  /// The colour it lights in, where the definition names one. Defaults to the
  /// palette's "good" green.
  final Color? onColor;

  /// Its shape, and a colour to light in over the definition's. See
  /// [LampLook].
  final GaugeAppearance look;

  /// Whether it fills the space it is given rather than hugging its label.
  ///
  /// On a dashboard page a lamp fills its cells, so a column of lamps lines up
  /// edge to edge whatever their labels say. A label too long for the lamp
  /// shrinks rather than being cut off - a truncated "Launch Con..." reads as
  /// the wrong thing.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lamp = look.lamp.resolved;
    final colours = look.colours;
    final active = on ?? false;
    final lit = lamp.onColour ?? onColor ?? StatusPalette.good;
    final background = colours.background;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Shape as well as colour: a filled circle when on, an outline when
        // off, so the state survives a colour-blind reading.
        Icon(
          active ? Icons.circle : Icons.circle_outlined,
          size: 9,
          color: active ? lit : scheme.outline,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          maxLines: 1,
          style: theme.textTheme.labelSmall?.copyWith(
            color: active ? colours.textOn(scheme) : colours.captionOn(scheme),
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );

    final glow = lit.withValues(alpha: 0.14);
    final decoration = switch (lamp.shape) {
      // The light and its label alone - over the background, where one is
      // set.
      LampShape.plain => BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      LampShape.pill || LampShape.square => BoxDecoration(
        color: switch ((active, background)) {
          (true, null) => glow,
          (true, final behind?) => Color.alphaBlend(glow, behind),
          (false, final behind) => behind ?? scheme.surfaceContainerLow,
        },
        borderRadius: BorderRadius.circular(
          lamp.shape == LampShape.pill ? 20 : 4,
        ),
        border: Border.all(color: active ? lit : scheme.outlineVariant),
      ),
    };

    if (!expand) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: decoration,
        child: content,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: decoration,
      alignment: Alignment.centerLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: content,
      ),
    );
  }
}
