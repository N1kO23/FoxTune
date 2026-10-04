import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'window_controls.dart';

/// The keys for full screen: F11 into it and out again - or Ctrl+Cmd+F on a
/// Mac, where F11 shows the desktop - and Esc out.
///
/// Goes around the `MaterialApp`, not inside it. A key comes here only once
/// nothing in the app has taken it, so Esc still closes a dialog or a menu
/// first, through the app's own Esc - and only leaves full screen once there
/// is nothing left for it to close.
class WindowShortcuts extends StatelessWidget {
  const WindowShortcuts({super.key, required this.window, required this.child});

  final WindowControls window;
  final Widget child;

  void _toggle() => window.setFullScreen(!window.fullScreen.value);

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.f11): _toggle,
      if (defaultTargetPlatform == TargetPlatform.macOS)
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          meta: true,
        ): _toggle,
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (window.fullScreen.value) window.setFullScreen(false);
      },
    },
    child: child,
  );
}
