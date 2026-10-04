import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_settings/app_settings.dart';
import 'window_controls.dart';

/// How the window's title bar is drawn on a desktop.
///
/// All but [native] are drawn by the app itself, in `WindowAppBar`, with the
/// window's own title bar hidden.
enum WindowFrame {
  /// Square caption buttons flush with the right edge, close turning red.
  windows('Windows'),

  /// Red, yellow and green lights on the left. On a Mac they are the window's
  /// own, with the app bar drawn beneath them.
  macos('macOS'),

  /// Round, softly filled buttons on the right, as GNOME apps have.
  gnome('GNOME'),

  /// The title bar the desktop draws, with the app bar below it.
  native('Native');

  const WindowFrame(this.label);

  final String label;

  /// Whether the app draws the title bar itself.
  bool get isDrawn => this != native;

  /// What a desktop shows until another is chosen: what FoxTune has always
  /// shown there - its own bar, but the native one on a Mac.
  static WindowFrame get platformDefault =>
      defaultTargetPlatform == TargetPlatform.macOS ? native : windows;
}

/// The title bar in force - what [AppSettings.windowFrame] asks for, where
/// the window can change to it.
///
/// It can always change between the drawn styles, and on Windows and macOS to
/// and from [WindowFrame.native] as well. On Linux, whether the desktop draws
/// the frame is settled as the window is made, so a change to or from native
/// waits for the next start; until then, the frame the app started with stays.
///
/// [WindowFrame.native] wherever there is no [WindowControls] - the native
/// frame is all there is.
final windowFrameProvider = NotifierProvider<WindowFrameInForce, WindowFrame>(
  WindowFrameInForce.new,
);

class WindowFrameInForce extends Notifier<WindowFrame> {
  @override
  WindowFrame build() {
    final window = ref.watch(windowControlsProvider);
    if (window == null) return WindowFrame.native;
    final chosen =
        ref.watch(appSettingsProvider.select((s) => s.windowFrame)) ??
        WindowFrame.platformDefault;
    return switch (window.nativeFrameFixed) {
      null => chosen,
      true => WindowFrame.native,
      false when chosen.isDrawn => chosen,
      // Native asked for, but this window draws its own: the drawn style it
      // had stays until the restart that brings the native frame.
      false => switch (stateOrNull) {
        final WindowFrame shown? when shown.isDrawn => shown,
        _ => WindowFrame.windows,
      },
    };
  }
}
