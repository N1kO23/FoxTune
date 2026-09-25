import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/app_settings/wallpaper.dart';
import 'package:foxtune_app/src/connection/connect_screen.dart';
import 'package:foxtune_app/src/connection/connection_controller.dart';
import 'package:foxtune_app/src/connection/connection_watchdog.dart';
import 'package:foxtune_app/src/files/file_saving.dart';

/// A one-pixel PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _NoWake implements ScreenWake {
  @override
  Future<void> hold() async {}

  @override
  Future<void> release() async {}
}

void main() {
  late Directory storage;

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_wall'));
  tearDown(() => storage.deleteSync(recursive: true));

  group('an image to keep', () {
    test('is recognised by how its file begins', () {
      Uint8List bytes(List<int> start) =>
          Uint8List.fromList([...start, ...List.filled(16, 0)]);

      expect(looksLikeImage(_png), isTrue);
      expect(looksLikeImage(bytes([0xFF, 0xD8, 0xFF, 0xE0])), isTrue);
      expect(looksLikeImage(bytes('GIF89a'.codeUnits)), isTrue);
      expect(looksLikeImage(bytes('BM'.codeUnits)), isTrue);
      expect(
        looksLikeImage(
          bytes([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits]),
        ),
        isTrue,
      );
      expect(
        looksLikeImage(Uint8List.fromList(utf8.encode('[MegaTune]'))),
        isFalse,
      );
      expect(looksLikeImage(Uint8List(0)), isFalse);
    });

    test('is copied into FoxTune\'s own files, and replaces the last copy', () {
      final first = keepWallpaperImage(
        storage,
        PickedFile(name: 'Beach.PNG', bytes: _png),
      );
      expect(first.parent.path, '${storage.path}/wallpapers');
      expect(first.path, endsWith('.png'));
      expect(first.readAsBytesSync(), _png);

      final second = keepWallpaperImage(
        storage,
        PickedFile(name: 'dash.png', bytes: _png),
        replacing: first.path,
      );
      expect(second.path, isNot(first.path));
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);
    });

    test('never deletes a file of the user\'s own', () {
      final theirs = File('${storage.path}/mine.png')..writeAsBytesSync(_png);
      keepWallpaperImage(
        storage,
        PickedFile(name: 'dash.png', bytes: _png),
        replacing: theirs.path,
      );
      expect(theirs.existsSync(), isTrue);
    });
  });

  group('Wallpaper', () {
    test('reads back what it writes', () {
      const wallpaper = Wallpaper(
        kind: WallpaperKind.image,
        image: '/data/wallpapers/wallpaper-1.png',
        imageName: 'dash.png',
        fit: WallpaperFit.tile,
        alignment: Alignment.bottomRight,
        strength: 0.4,
      );
      expect(Wallpaper.fromJson(wallpaper.toJson()), wallpaper);
      expect(
        AppSettings.fromJson(const AppSettings(wallpaper: wallpaper).toJson())
            .wallpaper,
        wallpaper,
      );
    });

    test('keeps the default for anything it cannot use', () {
      expect(Wallpaper.fromJson(null), const Wallpaper());
      expect(
        Wallpaper.fromJson({
          'kind': 'poster',
          'fit': 'squash',
          'alignment': 'middle',
          'strength': 7,
        }),
        const Wallpaper(),
      );
    });

    test('is the FoxTune emblem unless chosen otherwise', () {
      expect(const AppSettings().wallpaper.kind, WallpaperKind.branding);
    });
  });

  group('drawn', () {
    /// Shows [wallpaper] in a theme of [brightness] - once the app has
    /// finished animating to it.
    Future<void> pumpView(
      WidgetTester tester,
      Wallpaper wallpaper, {
      Brightness brightness = Brightness.dark,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: WallpaperView(wallpaper: wallpaper),
        ),
      );
      await tester.pumpAndSettle();
    }

    Image drawnImage(WidgetTester tester) =>
        tester.widget<Image>(find.byType(Image));

    testWidgets('as nothing at all, when there is none', (tester) async {
      await pumpView(tester, const Wallpaper(kind: WallpaperKind.none));
      expect(find.byType(Image), findsNothing);
      expect(find.byType(SvgPicture), findsNothing);
    });

    testWidgets('as the emblem, in the theme\'s text colour at the strength '
        'set', (tester) async {
      SvgPicture emblem() => tester.widget<SvgPicture>(find.byType(SvgPicture));
      Color text(Brightness brightness) =>
          ThemeData(brightness: brightness).colorScheme.onSurface;

      await pumpView(tester, const Wallpaper(strength: 0.3));
      expect(
        (emblem().bytesLoader as SvgAssetLoader).assetName,
        WallpaperView.emblem,
      );
      expect(
        emblem().colorFilter,
        ColorFilter.mode(
          text(Brightness.dark).withValues(alpha: 0.3),
          BlendMode.srcIn,
        ),
      );

      await pumpView(tester, const Wallpaper(), brightness: Brightness.light);
      expect(
        emblem().colorFilter,
        ColorFilter.mode(
          text(Brightness.light).withValues(alpha: Wallpaper.defaultStrength),
          BlendMode.srcIn,
        ),
      );
    });

    testWidgets('as the chosen image, laid out as set', (tester) async {
      final file = File('${storage.path}/dash.png')..writeAsBytesSync(_png);
      await pumpView(
        tester,
        Wallpaper(
          kind: WallpaperKind.image,
          image: file.path,
          fit: WallpaperFit.tile,
          alignment: Alignment.topLeft,
          strength: 0.5,
        ),
      );

      final image = drawnImage(tester);
      final resized = image.image as ResizeImage;
      expect((resized.imageProvider as FileImage).file.path, file.path);
      expect(resized.width, WallpaperView.maxDecodedSize);
      expect(image.repeat, ImageRepeat.repeat);
      expect(image.alignment, Alignment.topLeft);
      expect(image.color!.a, 0.5);
      expect(image.colorBlendMode, BlendMode.modulate);
    });

    testWidgets('again at once, when the strength changes', (tester) async {
      // An image repaints when given a new colour, but not when given a new
      // opacity animation that stands still - which is how the strength once
      // went unseen until the window was resized.
      final file = File('${storage.path}/dash.png')..writeAsBytesSync(_png);
      Widget at(double strength) => MaterialApp(
        home: WallpaperView(
          wallpaper: Wallpaper(
            kind: WallpaperKind.image,
            image: file.path,
            strength: strength,
          ),
        ),
      );

      await tester.pumpWidget(at(0.2));
      final image = tester.renderObject<RenderImage>(find.byType(RawImage));
      expect(image.debugNeedsPaint, isFalse);

      // Only as far as building: the change alone has to ask for a repaint.
      await tester.pumpWidget(at(0.8), phase: EnginePhase.build);
      expect(image.debugNeedsPaint, isTrue);
      await tester.pump();
    });
  });

  testWidgets('the main screen has it behind it', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          portsProvider.overrideWith((ref) async => const []),
          screenWakeProvider.overrideWithValue(_NoWake()),
        ],
        child: const MaterialApp(home: ConnectScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final behind = find.descendant(
      of: find.byType(ConnectScreen),
      matching: find.byType(WallpaperView),
    );
    expect(behind, findsOneWidget);
    expect(
      tester.widget<WallpaperView>(behind).wallpaper,
      const AppSettings().wallpaper,
    );
  });
}
