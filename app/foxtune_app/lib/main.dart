import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app_settings/app_settings.dart';
import 'src/app_settings/map_colours.dart';
import 'src/branding/brand_theme.dart';
import 'src/connection/connect_screen.dart';
import 'src/window/window_controls.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final window = await initWindowFrame();
  // Before the first frame, so the app opens in the theme it was left in
  // rather than flipping to it a moment later.
  final settings = await loadAppSettings();

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
    return MaterialApp(
      title: 'FoxTune',
      debugShowCheckedModeBanner: false,
      theme: brandTheme(Brightness.light).copyWith(extensions: [maps]),
      darkTheme: brandTheme(Brightness.dark).copyWith(extensions: [maps]),
      themeMode: ref.watch(appSettingsProvider.select((s) => s.themeMode)),
      home: const ConnectScreen(),
    );
  }
}
