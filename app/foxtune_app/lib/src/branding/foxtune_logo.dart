import 'package:flutter/material.dart';

import 'smooth_svg.dart';

/// The FoxTune app icon and wordmark, side by side, for the top of the main
/// screen.
///
/// The app icon rather than the bare emblem: the emblem's line art is drawn
/// for large sizes and turns to noise at app bar height, where the icon's
/// filled tile still reads. Both are drawn from their SVGs - see [SmoothSvg] -
/// so they are sharp and smooth at any pixel density: Windows at 125%, a
/// phone at 2.75x, where PNGs are sharp only at the densities they were
/// rendered for. See `branding/` for where each SVG comes from.
class FoxTuneLogo extends StatelessWidget {
  const FoxTuneLogo({super.key});

  @override
  Widget build(BuildContext context) {
    // The brand's "dark" artwork is the one drawn for dark backgrounds.
    final variant = Theme.of(context).brightness == Brightness.dark
        ? 'dark'
        : 'light';

    return Semantics(
      label: 'FoxTune',
      image: true,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SmoothSvg(
              'assets/branding/foxtune-icon.svg',
              width: 36,
              height: 36,
            ),
            const SizedBox(width: 12),
            // Sized up front, as it will be drawn - its art is 540 by 132 -
            // so nothing shifts once the SVG has loaded.
            SmoothSvg(
              'assets/branding/foxtune-wordmark-$variant.svg',
              width: 82,
              height: 20,
            ),
          ],
        ),
      ),
    );
  }
}
