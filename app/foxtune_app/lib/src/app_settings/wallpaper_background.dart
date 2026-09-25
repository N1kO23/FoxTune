import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart';
import 'wallpaper.dart';

/// The wallpaper chosen in App settings, drawn behind [child].
class WallpaperBackground extends ConsumerWidget {
  const WallpaperBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wallpaper = ref.watch(appSettingsProvider.select((s) => s.wallpaper));
    // A stack even with no wallpaper: were [child] handed back bare instead,
    // turning the wallpaper off would move it in the tree, and everything
    // under it would start over - the tab shown, a table being edited.
    return Stack(
      fit: StackFit.expand,
      children: [
        WallpaperView(wallpaper: wallpaper),
        child,
      ],
    );
  }
}
