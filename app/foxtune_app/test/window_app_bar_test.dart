import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/window/window_app_bar.dart';
import 'package:foxtune_app/src/window/window_controls.dart';

void main() {
  late _FakeWindow window;
  late int rescans;

  setUp(() {
    window = _FakeWindow();
    rescans = 0;
  });

  Future<void> pumpBar(WidgetTester tester, {WindowControls? controls}) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (controls != null)
              windowControlsProvider.overrideWithValue(controls),
          ],
          child: MaterialApp(
            home: Scaffold(
              appBar: WindowAppBar(
                title: const Text('FoxTune'),
                actions: [
                  IconButton(
                    tooltip: 'Rescan ports',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => rescans++,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// A point on the bar with nothing drawn on it - between the title and the
  /// actions.
  Offset emptyBar(WidgetTester tester) =>
      tester.getRect(find.byType(AppBar)).center;

  Future<void> doubleTapAt(WidgetTester tester, Offset position) async {
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
  }

  testWidgets('is a plain app bar where the native frame is kept', (
    tester,
  ) async {
    // Android, macOS and every other widget test: nothing overrides the
    // provider, so nothing may reach for a window.
    await pumpBar(tester);

    expect(find.text('FoxTune'), findsOneWidget);
    expect(find.byTooltip('Rescan ports'), findsOneWidget);
    expect(find.byTooltip('Minimize'), findsNothing);
    expect(find.byTooltip('Maximize'), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);
  });

  testWidgets('puts the window buttons after the actions, flush right', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    final bar = tester.getRect(find.byType(AppBar));
    final rescan = tester.getRect(find.byTooltip('Rescan ports'));
    final minimize = tester.getRect(find.byTooltip('Minimize'));
    final maximize = tester.getRect(find.byTooltip('Maximize'));
    final close = tester.getRect(find.byTooltip('Close'));

    expect(rescan.right, lessThanOrEqualTo(minimize.left));
    expect(minimize.right, maximize.left);
    expect(maximize.right, close.left);
    expect(close.right, bar.right);
    // Full height, so the corner of the window is a target, not a gap.
    expect(close.height, bar.height);
  });

  testWidgets('the window buttons act on the window at once', (tester) async {
    await pumpBar(tester, controls: window);

    // No pump in between: a button under a double-tap recognizer would still
    // be waiting out the double-tap timeout here.
    await tester.tap(find.byTooltip('Minimize'), kind: PointerDeviceKind.mouse);
    expect(window.calls, ['minimize']);
    await tester.tap(find.byTooltip('Maximize'), kind: PointerDeviceKind.mouse);
    expect(window.calls, ['minimize', 'toggleMaximize']);
    await tester.tap(find.byTooltip('Close'), kind: PointerDeviceKind.mouse);
    expect(window.calls, ['minimize', 'toggleMaximize', 'close']);
  });

  testWidgets('the screen actions still respond at once', (tester) async {
    await pumpBar(tester, controls: window);

    await tester.tap(
      find.byTooltip('Rescan ports'),
      kind: PointerDeviceKind.mouse,
    );
    expect(rescans, 1);
    expect(window.calls, isEmpty);
  });

  testWidgets('shows restore while maximized', (tester) async {
    await pumpBar(tester, controls: window);
    expect(find.byTooltip('Maximize'), findsOneWidget);

    // As the desktop reports it - maximizing need not come from the button.
    window.maximized.value = true;
    await tester.pump();
    expect(find.byTooltip('Restore'), findsOneWidget);
    expect(find.byTooltip('Maximize'), findsNothing);

    window.maximized.value = false;
    await tester.pump();
    expect(find.byTooltip('Maximize'), findsOneWidget);
  });

  testWidgets('double-clicking the bar or the title toggles maximize', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    await doubleTapAt(tester, emptyBar(tester));
    expect(window.calls, ['toggleMaximize']);

    await doubleTapAt(tester, tester.getCenter(find.text('FoxTune')));
    expect(window.calls, ['toggleMaximize', 'toggleMaximize']);
  });

  testWidgets('double-clicking a button is two clicks, not a maximize', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    await doubleTapAt(tester, tester.getCenter(find.byTooltip('Rescan ports')));
    expect(rescans, 2);
    expect(window.calls, isEmpty);
  });

  testWidgets('dragging the bar or the title moves the window', (tester) async {
    await pumpBar(tester, controls: window);

    await tester.dragFrom(
      emptyBar(tester),
      const Offset(40, 20),
      kind: PointerDeviceKind.mouse,
    );
    // Lets the double-click recognizer that saw the press time out.
    await tester.pumpAndSettle();
    expect(window.calls, ['startDragging']);

    await tester.drag(
      find.text('FoxTune'),
      const Offset(40, 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(window.calls, ['startDragging', 'startDragging']);
  });
}

class _FakeWindow implements WindowControls {
  final calls = <String>[];

  @override
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> toggleMaximize() async => calls.add('toggleMaximize');

  @override
  Future<void> close() async => calls.add('close');
}
