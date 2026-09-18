import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('shows the connect screen on launch', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: FoxTuneApp()));
    await tester.pump();

    expect(find.text('FoxTune'), findsOneWidget);
    // Port enumeration is async; the screen must render something meaningful
    // rather than a blank frame while it runs.
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
