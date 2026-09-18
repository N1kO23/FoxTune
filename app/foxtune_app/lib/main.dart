import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/connection/connect_screen.dart';

void main() {
  runApp(const ProviderScope(child: FoxTuneApp()));
}

class FoxTuneApp extends StatelessWidget {
  const FoxTuneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FoxTune',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC75B12)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC75B12),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ConnectScreen(),
    );
  }
}
