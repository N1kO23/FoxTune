import 'package:flutter/material.dart';

/// The brand's pink - see `branding/README.md`.
const brandPink = Color(0xFFFF2E6E);

/// The app's theme: the brand pink as the accent, on neutral surfaces.
///
/// Put together from two seeded schemes, because neither alone matches the
/// brand. The accents - primary, secondary, tertiary and their containers -
/// come from [DynamicSchemeVariant.fidelity], which keeps the pink vivid where
/// Material's default mutes it to a dusty rose. Everything content sits on -
/// surfaces, outlines, the text on them - comes from a monochrome scheme, for
/// the brand's off-white and near-black rather than backgrounds tinted pink.
ThemeData brandTheme(Brightness brightness) {
  final accents = ColorScheme.fromSeed(
    seedColor: brandPink,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final neutral = ColorScheme.fromSeed(
    seedColor: brandPink,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: accents.copyWith(
      surface: neutral.surface,
      onSurface: neutral.onSurface,
      onSurfaceVariant: neutral.onSurfaceVariant,
      surfaceDim: neutral.surfaceDim,
      surfaceBright: neutral.surfaceBright,
      surfaceContainerLowest: neutral.surfaceContainerLowest,
      surfaceContainerLow: neutral.surfaceContainerLow,
      surfaceContainer: neutral.surfaceContainer,
      surfaceContainerHigh: neutral.surfaceContainerHigh,
      surfaceContainerHighest: neutral.surfaceContainerHighest,
      outline: neutral.outline,
      outlineVariant: neutral.outlineVariant,
      inverseSurface: neutral.inverseSurface,
      onInverseSurface: neutral.onInverseSurface,
      // Elevated surfaces are tinted with this; left pink, raised cards and
      // menus would turn pink even with the surfaces above neutral.
      surfaceTint: neutral.surfaceTint,
    ),
  );
}
