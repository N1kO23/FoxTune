import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/window/window_shortcuts.dart';

import 'fake_window.dart';

void main() {
  late FakeWindow window;

  setUp(() => window = FakeWindow());

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      WindowShortcuts(
        window: window,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(content: Text('A dialog')),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('F11 goes full screen, and back', (tester) async {
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    expect(window.fullScreen.value, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    expect(window.fullScreen.value, isFalse);
    expect(window.calls, ['setFullScreen(true)', 'setFullScreen(false)']);
  });

  testWidgets('Esc leaves full screen, and does nothing outside it', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(window.calls, isEmpty);

    window.fullScreen.value = true;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(window.calls, ['setFullScreen(false)']);
  });

  testWidgets('Esc closes a dialog before it leaves full screen', (
    tester,
  ) async {
    window.fullScreen.value = true;
    await pumpApp(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('A dialog'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('A dialog'), findsNothing);
    expect(window.fullScreen.value, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(window.fullScreen.value, isFalse);
  });

  testWidgets('Ctrl+Cmd+F goes full screen on a Mac', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await pumpApp(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(window.fullScreen.value, isTrue);

    debugDefaultTargetPlatformOverride = null;
  });
}
