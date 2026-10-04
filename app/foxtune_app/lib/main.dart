import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app_settings/app_settings.dart';
import 'src/app_settings/map_colours.dart';
import 'src/branding/brand_theme.dart';
import 'src/connection/connect_screen.dart';
import 'src/window/window_controls.dart';
import 'src/window/window_frame.dart';
import 'src/window/window_shortcuts.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first frame, so the app opens in the theme it was left in
  // rather than flipping to it a moment later - and before the window frame,
  // which follows them.
  final settings = await loadAppSettings();
  final window = await initWindowFrame(
    settings.windowFrame ?? WindowFrame.platformDefault,
    // The Linux runner says when it left the frame to the desktop.
    nativeAtStart: args.contains('--native-frame'),
  );

  runApp(
    ProviderScope(
      // Riverpod retries a failed provider on its own by default. Here that
      // would mean reading the whole tune from the ECU again, unasked, after a
      // read failed part-way - so a failure is shown instead, and retried
      // only when the user asks.
      retry: (_, _) => null,
      overrides: [
        if (window != null) windowControlsProvider.overrideWithValue(window),
        initialAppSettingsProvider.overrideWithValue(settings),
      ],
      child: const FoxTuneApp(),
    ),
  );
}

class FoxTuneApp extends ConsumerWidget {
  const FoxTuneApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Carried by the theme, so every map - table grid, 3D surface, coverage -
    // reaches it without being handed it.
    final maps = MapColours(
      ref.watch(appSettingsProvider.select((s) => s.mapGradient)),
    );
    final window = ref.watch(windowControlsProvider);
    if (window != null) {
      ref.listen(windowFrameProvider, (_, frame) => window.applyFrame(frame));
    }
    final app = MaterialApp(
      title: 'FoxTune',
      debugShowCheckedModeBanner: false,
      theme: brandTheme(Brightness.light).copyWith(extensions: [maps]),
      darkTheme: brandTheme(Brightness.dark).copyWith(extensions: [maps]),
      themeMode: ref.watch(appSettingsProvider.select((s) => s.themeMode)),
      home: const ConnectScreen(),
    );
    return window == null ? app : WindowShortcuts(window: window, child: app);
  }
}
