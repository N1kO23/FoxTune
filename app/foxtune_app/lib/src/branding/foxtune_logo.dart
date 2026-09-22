import 'package:flutter/material.dart';

/// The FoxTune app icon and wordmark, side by side, for the top of the main
/// screen.
///
/// The app icon rather than the bare emblem: the emblem's line art is drawn
/// for large sizes and turns to noise at app bar height, where the icon's
/// filled tile still reads. Both are rendered at exactly the size shown here
/// (with 2x and 3x variants) from the SVGs in `branding/`, so re-render them
/// from there if these sizes change.
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
            Image.asset('assets/branding/foxtune-icon.png', height: 36),
            const SizedBox(width: 12),
            Image.asset(
              'assets/branding/foxtune-wordmark-$variant.png',
              height: 20,
            ),
          ],
        ),
      ),
    );
  }
}
