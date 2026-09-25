import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

/// The brand artwork the app bundles, as flutter_svg draws it.
///
/// flutter_svg skips a nested `<svg>` element, and everything inside it,
/// without a word. The master artwork in `branding/` is built from them, and
/// through flutter_svg draws as nothing at all - or, for the app icon, as its
/// bare black tile. So every SVG the app bundles is flattened first (see
/// `branding/README.md`), and this checks that each one really draws.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final artwork = [
    for (final entity in Directory('assets/branding').listSync())
      if (entity is File && entity.path.endsWith('.svg')) entity,
  ];

  test('there is artwork to check', () => expect(artwork, isNotEmpty));

  for (final file in artwork) {
    test('${file.uri.pathSegments.last} is flat, and draws', () async {
      final svg = file.readAsStringSync();
      expect(
        '<svg'.allMatches(svg),
        hasLength(1),
        reason: 'a nested <svg> is skipped; flatten it',
      );

      final info = await vg.loadPicture(SvgStringLoader(svg), null);
      final width = info.size.width.ceil();
      final height = info.size.height.ceil();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawPicture(info.picture);
      final image = await recorder.endRecording().toImage(width, height);
      final pixels = (await image.toByteData())!;

      var inked = 0;
      for (var alpha = 3; alpha < pixels.lengthInBytes; alpha += 4) {
        if (pixels.getUint8(alpha) > 0) inked++;
      }
      // The sparsest, the emblem's line art, inks about a sixth of its box.
      expect(inked / (width * height), greaterThan(0.05));
    });
  }
}
