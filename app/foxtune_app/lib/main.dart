import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/branding/brand_theme.dart';
import 'src/connection/connect_screen.dart';
import 'src/window/window_controls.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final window = await initWindowFrame();

  runApp(
    ProviderScope(
      overrides: [
        if (window != null) windowControlsProvider.overrideWithValue(window),
      ],
      child: const FoxTuneApp(),
    ),
  );
}

class FoxTuneApp extends StatelessWidget {
  const FoxTuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FoxTune',
      debugShowCheckedModeBanner: false,
      theme: brandTheme(Brightness.light),
      darkTheme: brandTheme(Brightness.dark),
      home: const ConnectScreen(),
    );
  }
}
