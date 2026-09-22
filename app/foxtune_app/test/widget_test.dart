import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  testWidgets('shows the connect screen on launch', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const ProviderScope(child: FoxTuneApp()));
    await tester.pump();

    // The logo is artwork, so it is found by the name it is announced by.
    expect(find.bySemanticsLabel('FoxTune'), findsOneWidget);
    // Port enumeration is async; the screen must render something meaningful
    // rather than a blank frame while it runs.
    expect(find.byType(Scaffold), findsOneWidget);
    semantics.dispose();
  });
}
