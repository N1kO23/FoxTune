import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/window/window_app_bar.dart';
import 'package:foxtune_app/src/window/window_controls.dart';
import 'package:foxtune_app/src/window/window_frame.dart';

import 'fake_window.dart';

void main() {
  late FakeWindow window;
  late int rescans;

  setUp(() {
    window = FakeWindow();
    rescans = 0;
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    WindowControls? controls,
    WindowFrame? frame,
    GlobalKey<NavigatorState>? navigator,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (controls != null)
          windowControlsProvider.overrideWithValue(controls),
        initialAppSettingsProvider.overrideWithValue(
          AppSettings(windowFrame: frame),
        ),
      ],
      child: MaterialApp(
        navigatorKey: navigator,
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

  testWidgets('is a plain app bar where there is no window to control', (
    tester,
  ) async {
    // Android and every other widget test: nothing overrides the provider, so
    // nothing may reach for a window.
    await pumpBar(tester);

    expect(find.text('FoxTune'), findsOneWidget);
    expect(find.byTooltip('Rescan ports'), findsOneWidget);
    expect(find.byTooltip('Minimize'), findsNothing);
    expect(find.byTooltip('Maximize'), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);
  });

  testWidgets('is a plain app bar with the native frame', (tester) async {
    await pumpBar(tester, controls: window, frame: WindowFrame.native);

    expect(find.text('FoxTune'), findsOneWidget);
    expect(find.byTooltip('Rescan ports'), findsOneWidget);
    expect(find.byType(WindowButtons), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);

    // The desktop's frame moves the window; the bar under it does not.
    await tester.dragFrom(
      emptyBar(tester),
      const Offset(40, 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(window.calls, isEmpty);
  });

  testWidgets('draws the Windows buttons where nothing has been chosen', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    expect(
      tester.widget<WindowButtons>(find.byType(WindowButtons)).style,
      WindowFrame.windows,
    );
  });

  for (final frame in WindowFrame.values.where((f) => f.isDrawn)) {
    group('drawn as ${frame.label}', () {
      testWidgets('the window buttons act on the window at once', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);

        // No pump in between: a button under a double-tap recognizer would
        // still be waiting out the double-tap timeout here.
        await tester.tap(
          find.byTooltip('Minimize'),
          kind: PointerDeviceKind.mouse,
        );
        expect(window.calls, ['minimize']);
        await tester.tap(
          find.byTooltip('Maximize'),
          kind: PointerDeviceKind.mouse,
        );
        expect(window.calls, ['minimize', 'toggleMaximize']);
        await tester.tap(
          find.byTooltip('Close'),
          kind: PointerDeviceKind.mouse,
        );
        expect(window.calls, ['minimize', 'toggleMaximize', 'close']);
      });

      testWidgets('the screen actions still respond at once', (tester) async {
        await pumpBar(tester, controls: window, frame: frame);

        await tester.tap(
          find.byTooltip('Rescan ports'),
          kind: PointerDeviceKind.mouse,
        );
        expect(rescans, 1);
        expect(window.calls, isEmpty);
      });

      testWidgets('shows restore while maximized', (tester) async {
        await pumpBar(tester, controls: window, frame: frame);
        expect(find.byTooltip('Maximize'), findsOneWidget);

        // As the desktop reports it - maximizing need not come from the
        // button.
        window.maximized.value = true;
        await tester.pump();
        expect(find.byTooltip('Restore'), findsOneWidget);
        expect(find.byTooltip('Maximize'), findsNothing);

        window.maximized.value = false;
        await tester.pump();
        expect(find.byTooltip('Maximize'), findsOneWidget);
      });

      testWidgets('dims the buttons while the window is in the background', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);
        bool dimmed() =>
            tester.widget<WindowButtons>(find.byType(WindowButtons)).dimmed;
        expect(dimmed(), isFalse);

        window.focused.value = false;
        await tester.pump();
        expect(dimmed(), isTrue);

        window.focused.value = true;
        await tester.pump();
        expect(dimmed(), isFalse);
      });

      testWidgets('double-clicking the bar or the title toggles maximize', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);

        await doubleTapAt(tester, emptyBar(tester));
        expect(window.calls, ['toggleMaximize']);

        await doubleTapAt(tester, tester.getCenter(find.text('FoxTune')));
        expect(window.calls, ['toggleMaximize', 'toggleMaximize']);
      });

      testWidgets('double-clicking a button is two clicks, not a maximize', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);

        await doubleTapAt(
          tester,
          tester.getCenter(find.byTooltip('Rescan ports')),
        );
        expect(rescans, 2);
        expect(window.calls, isEmpty);
      });

      testWidgets('dragging the bar or the title moves the window', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);

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

      testWidgets('right-clicking the bar opens the window menu', (
        tester,
      ) async {
        await pumpBar(tester, controls: window, frame: frame);

        await tester.tapAt(
          emptyBar(tester),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('Minimize'), findsOneWidget);
        expect(find.text('Maximize'), findsOneWidget);
        expect(find.text('Close'), findsOneWidget);

        await tester.tap(find.text('Full screen'));
        await tester.pumpAndSettle();
        expect(window.calls, ['setFullScreen(true)']);
      });
    });
  }

  testWidgets('Windows: the buttons follow the actions, flush right', (
    tester,
  ) async {
    await pumpBar(tester, controls: window, frame: WindowFrame.windows);

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

  testWidgets('GNOME: round buttons follow the actions, in from the edge', (
    tester,
  ) async {
    await pumpBar(tester, controls: window, frame: WindowFrame.gnome);

    final bar = tester.getRect(find.byType(AppBar));
    final rescan = tester.getRect(find.byTooltip('Rescan ports'));
    final minimize = tester.getRect(find.byTooltip('Minimize'));
    final maximize = tester.getRect(find.byTooltip('Maximize'));
    final close = tester.getRect(find.byTooltip('Close'));

    expect(rescan.right, lessThanOrEqualTo(minimize.left));
    expect(minimize.right, lessThan(maximize.left));
    expect(maximize.right, lessThan(close.left));
    expect(close.right, lessThan(bar.right));
    expect(close.size, const Size.square(24));
    expect(close.center.dy, bar.center.dy);
  });

  testWidgets('macOS: the lights lead, close first, and the actions end the '
      'bar', (tester) async {
    await pumpBar(tester, controls: window, frame: WindowFrame.macos);

    final bar = tester.getRect(find.byType(AppBar));
    final close = tester.getRect(find.byTooltip('Close'));
    final minimize = tester.getRect(find.byTooltip('Minimize'));
    final maximize = tester.getRect(find.byTooltip('Maximize'));
    final title = tester.getRect(find.text('FoxTune'));
    final rescan = tester.getRect(find.byTooltip('Rescan ports'));

    expect(close.left, greaterThan(bar.left));
    expect(close.right, lessThanOrEqualTo(minimize.left));
    expect(minimize.right, lessThanOrEqualTo(maximize.left));
    expect(maximize.right, lessThan(title.left));
    // Nothing after the actions but the bar's own padding.
    expect(bar.right - rescan.right, lessThanOrEqualTo(4));
  });

  testWidgets('macOS: the way back follows the lights', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await pumpBar(
      tester,
      controls: window,
      frame: WindowFrame.macos,
      navigator: navigator,
    );
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(appBar: WindowAppBar(title: Text('Second'))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final maximize = tester.getRect(find.byTooltip('Maximize'));
    final back = tester.getRect(find.byType(BackButton));
    final title = tester.getRect(find.text('Second'));
    expect(maximize.right, lessThanOrEqualTo(back.left));
    expect(back.right, lessThanOrEqualTo(title.left));

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('FoxTune'), findsOneWidget);
  });

  testWidgets("macOS on a Mac: leaves room for the window's own buttons", (
    tester,
  ) async {
    await pumpBar(
      tester,
      controls: FakeWindow(hasNativeTrafficLights: true),
      frame: WindowFrame.macos,
    );

    expect(find.byType(WindowButtons), findsNothing);
    expect(find.byTooltip('Close'), findsNothing);
    expect(tester.getRect(find.text('FoxTune')).left, greaterThanOrEqualTo(76));
  });

  testWidgets('the window menu does not open on a held mouse button', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    final mouse = await tester.startGesture(
      emptyBar(tester),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text('Full screen'), findsNothing);
  });

  testWidgets('a long press on a touch screen opens the window menu', (
    tester,
  ) async {
    await pumpBar(tester, controls: window);

    await tester.longPressAt(emptyBar(tester));
    await tester.pumpAndSettle();
    expect(find.text('Full screen'), findsOneWidget);
  });

  group('in full screen', () {
    for (final frame in WindowFrame.values) {
      testWidgets('as ${frame.label}, offers a way out instead of the window '
          'buttons', (tester) async {
        window.fullScreen.value = true;
        await pumpBar(tester, controls: window, frame: frame);

        expect(find.byType(WindowButtons), findsNothing);
        expect(find.byTooltip('Minimize'), findsNothing);
        expect(find.byTooltip('Rescan ports'), findsOneWidget);

        await tester.tap(find.byTooltip('Exit full screen'));
        await tester.pumpAndSettle();
        expect(window.calls, ['setFullScreen(false)']);
        // Back to the bar for the frame.
        expect(find.byTooltip('Exit full screen'), findsNothing);
      });
    }

    testWidgets('neither drags nor maximizes the window', (tester) async {
      window.fullScreen.value = true;
      await pumpBar(tester, controls: window);

      await tester.dragFrom(
        emptyBar(tester),
        const Offset(40, 20),
        kind: PointerDeviceKind.mouse,
      );
      await doubleTapAt(tester, emptyBar(tester));
      expect(window.calls, isEmpty);
    });

    testWidgets('the window menu leads out of it', (tester) async {
      window.fullScreen.value = true;
      await pumpBar(tester, controls: window);

      await tester.tapAt(
        emptyBar(tester),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Minimize'), findsNothing);

      await tester.tap(find.text('Exit full screen'));
      await tester.pumpAndSettle();
      expect(window.calls, ['setFullScreen(false)']);
    });
  });

  group('the frame in force', () {
    late Directory storage;
    setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_app'));
    tearDown(() => storage.deleteSync(recursive: true));

    ProviderContainer containerFor(WindowControls? controls, WindowFrame? to) {
      final container = ProviderContainer(
        overrides: [
          jsonStoreProvider.overrideWithValue(JsonStore(() async => storage)),
          if (controls != null)
            windowControlsProvider.overrideWithValue(controls),
          initialAppSettingsProvider.overrideWithValue(
            AppSettings(windowFrame: to),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    void choose(ProviderContainer container, WindowFrame frame) => container
        .read(appSettingsProvider.notifier)
        .update((s) => s.copyWith(windowFrame: frame));

    test('is native with no window to draw on', () {
      final container = containerFor(null, WindowFrame.gnome);
      expect(container.read(windowFrameProvider), WindowFrame.native);
    });

    test("is the platform's own until one is chosen", () {
      expect(
        containerFor(window, null).read(windowFrameProvider),
        WindowFrame.windows,
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        containerFor(window, null).read(windowFrameProvider),
        WindowFrame.native,
      );
    });

    test('follows every choice where the window can change at once', () {
      final container = containerFor(window, WindowFrame.windows);
      for (final frame in WindowFrame.values) {
        choose(container, frame);
        expect(container.read(windowFrameProvider), frame);
      }
    });

    test('stays native until a restart where the desktop has the frame', () {
      final container = containerFor(
        FakeWindow(nativeFrameFixed: true),
        WindowFrame.native,
      );
      expect(container.read(windowFrameProvider), WindowFrame.native);

      choose(container, WindowFrame.gnome);
      expect(container.read(windowFrameProvider), WindowFrame.native);
    });

    test('keeps a drawn style until a restart brings the native frame', () {
      final container = containerFor(
        FakeWindow(nativeFrameFixed: false),
        WindowFrame.gnome,
      );
      expect(container.read(windowFrameProvider), WindowFrame.gnome);

      choose(container, WindowFrame.native);
      expect(container.read(windowFrameProvider), WindowFrame.gnome);

      // The drawn styles still change at once.
      choose(container, WindowFrame.macos);
      expect(container.read(windowFrameProvider), WindowFrame.macos);
    });
  });
}
