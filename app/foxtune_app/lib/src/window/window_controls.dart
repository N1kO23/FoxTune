import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'window_frame.dart';

/// The window operations the app's own title bar needs.
///
/// Behind an interface so the title bar can be tested without a real window,
/// and so Android never reaches the plugin.
abstract interface class WindowControls {
  /// Whether the window is maximized - kept current however that changes,
  /// including from the desktop's own shortcuts, not just the title bar.
  ValueListenable<bool> get maximized;

  /// Whether the window has the keyboard focus. The drawn window buttons dim
  /// without it, as the desktop's own do.
  ValueListenable<bool> get focused;

  /// Whether the window fills the screen, with no frame of any kind.
  ValueListenable<bool> get fullScreen;

  /// Whether the desktop draws the window's frame, where that was settled
  /// when the window was made and holds until the app restarts - on Linux.
  /// `null` where [applyFrame] can change it at once.
  bool? get nativeFrameFixed;

  /// Whether the window keeps its own macOS window buttons for
  /// [WindowFrame.macos], with the app bar drawn under them - on a Mac.
  bool get hasNativeTrafficLights;

  /// Shows or hides the window's own title bar for [frame]. Does nothing
  /// where the frame is [nativeFrameFixed].
  Future<void> applyFrame(WindowFrame frame);

  /// Hands the drag in progress to the window manager, which moves the window
  /// from here on - so snapping and tiling work as they do for native frames.
  Future<void> startDragging();

  Future<void> minimize();

  Future<void> toggleMaximize();

  Future<void> setFullScreen(bool on);

  Future<void> close();
}

/// The window, on a desktop; `null` on Android, in the widget tests, and if
/// the window could not be reached.
///
/// `null` unless `main` sets it after [initWindowFrame] - so Android and the
/// widget tests get a plain [AppBar] and never touch the plugin.
final windowControlsProvider = Provider<WindowControls?>((ref) => null);

/// Takes charge of the window on Linux, Windows and macOS, and gives it the
/// title bar [frame] asks for.
///
/// On Linux the runner has already decided whether the desktop draws the
/// frame - [nativeAtStart] - since that cannot change once the window is
/// made. Elsewhere [frame] is applied here, and can be changed later.
///
/// Returns `null` everywhere else, and on any failure: a window left with its
/// native frame is fine, one left with no title bar at all is not. Run before
/// `runApp` - the Linux and Windows runners only show the window on the first
/// frame, so a hidden title bar is gone before it is ever drawn.
Future<WindowControls?> initWindowFrame(
  WindowFrame frame, {
  required bool nativeAtStart,
}) async {
  if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
    return null;
  }

  try {
    await windowManager.ensureInitialized();
    final controls = _WindowManagerControls(
      maximized: await windowManager.isMaximized(),
      focused: await windowManager.isFocused(),
      fullScreen: await windowManager.isFullScreen(),
      nativeFrameFixed: Platform.isLinux ? nativeAtStart : null,
    );
    // Last, so nothing after it can fail with the title bar already gone.
    if (Platform.isLinux) {
      if (!nativeAtStart) {
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      }
    } else {
      await controls.applyFrame(frame);
    }
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
  _WindowManagerControls({
    required bool maximized,
    required bool focused,
    required bool fullScreen,
    required this.nativeFrameFixed,
  }) : _maximized = ValueNotifier(maximized),
       _focused = ValueNotifier(focused),
       _fullScreen = ValueNotifier(fullScreen) {
    windowManager.addListener(this);
  }

  final ValueNotifier<bool> _maximized;
  final ValueNotifier<bool> _focused;
  final ValueNotifier<bool> _fullScreen;

  @override
  ValueListenable<bool> get maximized => _maximized;

  @override
  ValueListenable<bool> get focused => _focused;

  @override
  ValueListenable<bool> get fullScreen => _fullScreen;

  @override
  final bool? nativeFrameFixed;

  @override
  bool get hasNativeTrafficLights => Platform.isMacOS;

  @override
  Future<void> applyFrame(WindowFrame frame) async {
    if (nativeFrameFixed != null) return;
    await windowManager.setTitleBarStyle(
      frame.isDrawn ? TitleBarStyle.hidden : TitleBarStyle.normal,
      // Only a Mac has buttons that outlive a hidden title bar: kept for its
      // own style, hidden where the app draws others.
      windowButtonVisibility: !frame.isDrawn || frame == WindowFrame.macos,
    );
  }

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
  Future<void> setFullScreen(bool on) async {
    await windowManager.setFullScreen(on);
    // Linux and macOS say when the window enters or leaves full screen; the
    // Win32 side of the plugin does not, but has finished by now.
    if (Platform.isWindows) {
      _fullScreen.value = await windowManager.isFullScreen();
    }
  }

  @override
  Future<void> close() => windowManager.close();

  @override
  void onWindowMaximize() => _maximized.value = true;

  @override
  void onWindowUnmaximize() => _maximized.value = false;

  @override
  void onWindowFocus() => _focused.value = true;

  @override
  void onWindowBlur() => _focused.value = false;

  @override
  void onWindowEnterFullScreen() => _fullScreen.value = true;

  @override
  void onWindowLeaveFullScreen() => _fullScreen.value = false;
}
