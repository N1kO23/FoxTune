import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

/// The window operations the app's own title bar needs.
///
/// Behind an interface so the title bar can be tested without a real window,
/// and so the platforms that keep their native frame never reach the plugin.
abstract interface class WindowControls {
  /// Whether the window is maximized - kept current however that changes,
  /// including from the desktop's own shortcuts, not just the title bar.
  ValueListenable<bool> get maximized;

  /// Hands the drag in progress to the window manager, which moves the window
  /// from here on - so snapping and tiling work as they do for native frames.
  Future<void> startDragging();

  Future<void> minimize();

  Future<void> toggleMaximize();

  Future<void> close();
}

/// The window, when the app draws its own frame; `null` when the platform's
/// native frame is kept.
///
/// `null` unless `main` sets it after [initWindowFrame] - so Android, macOS
/// and the widget tests get a plain [AppBar] and never touch the plugin.
final windowControlsProvider = Provider<WindowControls?>((ref) => null);

/// Hides the native title bar on Linux and Windows, where the app draws its
/// own in `WindowAppBar`.
///
/// Returns `null` everywhere else, and on any failure: a window left with its
/// native frame is fine, one left with no title bar at all is not. Run before
/// `runApp` - the runners only show the window on the first frame, so the
/// native title bar is gone before it is ever drawn.
Future<WindowControls?> initWindowFrame() async {
  if (!Platform.isLinux && !Platform.isWindows) return null;

  try {
    await windowManager.ensureInitialized();
    final controls = _WindowManagerControls(
      maximized: await windowManager.isMaximized(),
    );
    // Last, so nothing after it can fail with the title bar already gone.
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    return controls;
  } catch (error) {
    debugPrint('Keeping the native window frame: $error');
    return null;
  }
}

/// [WindowControls] on the `window_manager` plugin.
///
/// Lives as long as the app, so it never stops listening.
class _WindowManagerControls with WindowListener implements WindowControls {
  _WindowManagerControls({required bool maximized})
    : _maximized = ValueNotifier(maximized) {
    windowManager.addListener(this);
  }

  final ValueNotifier<bool> _maximized;

  @override
  ValueListenable<bool> get maximized => _maximized;

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> toggleMaximize() async {
    // Asked rather than taken from [maximized], which trails the window by an
    // event.
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> close() => windowManager.close();

  @override
  void onWindowMaximize() => _maximized.value = true;

  @override
  void onWindowUnmaximize() => _maximized.value = false;
}
