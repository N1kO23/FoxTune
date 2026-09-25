import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/branding/smooth_svg.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('each pixel drawn is the average of the sixteen it covers', () async {
    // Seventeen 4 x 4 blocks, the kth with k of its pixels inked: an edge as
    // a renderer that does not smooth leaves it, from missed to covered.
    const blocks = 17;
    final pixels = Uint8List(blocks * 4 * 4 * 4);
    for (var k = 0; k < blocks; k++) {
      for (var i = 0; i < k; i++) {
        final x = k * 4 + i % 4;
        final y = i ~/ 4;
        pixels[(y * blocks * 4 + x) * 4 + 3] = 255;
      }
    }
    final decoded = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      blocks * 4,
      4,
      ui.PixelFormat.rgba8888,
      decoded.complete,
    );

    final image = await halve(await halve(await decoded.future));
    expect((image.width, image.height), (blocks, 1));
    final drawn = (await image.toByteData())!;
    for (var k = 0; k < blocks; k++) {
      expect(
        drawn.getUint8(k * 4 + 3),
        closeTo(255 * k / 16, 2),
        reason: '$k of 16 covered',
      );
    }
  });

  test(
    'renders at exactly the pixels asked for, within budget or not',
    () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawCircle(const Offset(50, 50), 40, Paint());
      final circle = recorder.endRecording();

      final small = await rasteriseSmooth(circle, const Size(100, 100), 36, 36);
      expect((small.width, small.height), (36, 36));
      final pixels = (await small.toByteData())!;
      int alphaAt(int x, int y) => pixels.getUint8((y * 36 + x) * 4 + 3);
      expect(alphaAt(18, 18), 255);
      expect(alphaAt(0, 0), 0);

      // Too many pixels to render sixteen times over: fewer, but the same size.
      final big = await rasteriseSmooth(
        circle,
        const Size(100, 100),
        300,
        300,
        budget: 400 * 400,
      );
      expect((big.width, big.height), (300, 300));
    },
  );

  testWidgets('draws its SVG at exactly the pixels it covers, coloured as '
      'it is drawn', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(devicePixelRatio: 1.5),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SmoothSvg(
              'assets/branding/foxtune-icon.svg',
              width: 36,
              height: 36,
              color: Color(0x80FF2E6E),
            ),
          ),
        ),
      ),
    );
    // Loading and rendering run off the test's clock.
    for (var i = 0; i < 100 && find.byType(RawImage).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }

    final drawn = tester.widget<RawImage>(find.byType(RawImage));
    expect((drawn.image!.width, drawn.image!.height), (54, 54));
    expect((drawn.width, drawn.height), (36, 36));
    expect(drawn.color, const Color(0x80FF2E6E));
  });
}
