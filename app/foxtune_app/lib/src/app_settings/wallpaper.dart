import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../branding/smooth_svg.dart';
import '../files/file_saving.dart';

/// What is drawn behind the main screen.
enum WallpaperKind {
  /// Nothing: the plain background.
  none,

  /// The FoxTune emblem, faintly, in the middle.
  branding,

  /// An image the user chose.
  image,
}

/// How a wallpaper image is laid out.
enum WallpaperFit {
  /// Covers the whole background, cropping whatever does not fit.
  fill('Fill', BoxFit.cover),

  /// The whole image, with the background showing where its shape differs.
  fit('Fit', BoxFit.contain),

  /// At its own size, however much of the background that covers.
  actualSize('Actual size', BoxFit.none),

  /// At its own size, repeated to cover the background.
  tile('Tile', BoxFit.none);

  const WallpaperFit(this.label, this.boxFit);

  final String label;
  final BoxFit boxFit;

  ImageRepeat get repeat =>
      this == tile ? ImageRepeat.repeat : ImageRepeat.noRepeat;
}

/// Where a wallpaper image is anchored, by the name it is saved under.
const wallpaperAlignments = {
  'topLeft': Alignment.topLeft,
  'topCenter': Alignment.topCenter,
  'topRight': Alignment.topRight,
  'centerLeft': Alignment.centerLeft,
  'center': Alignment.center,
  'centerRight': Alignment.centerRight,
  'bottomLeft': Alignment.bottomLeft,
  'bottomCenter': Alignment.bottomCenter,
  'bottomRight': Alignment.bottomRight,
};

/// The wallpaper behind the main screen, as App settings describe it.
@immutable
class Wallpaper {
  const Wallpaper({
    this.kind = WallpaperKind.branding,
    this.image,
    this.imageName,
    this.fit = WallpaperFit.fill,
    this.alignment = Alignment.center,
    this.strength = defaultStrength,
  });

  /// Faint enough for the emblem to sit behind a screen as a watermark.
  static const defaultStrength = 0.15;

  final WallpaperKind kind;

  /// The chosen image: FoxTune's own copy of it - see [keepWallpaperImage].
  ///
  /// Remembered while the wallpaper is something else, so choosing an image
  /// again brings it straight back.
  final String? image;

  /// What the image was called when it was chosen, to show.
  final String? imageName;

  final WallpaperFit fit;

  /// Where the image is anchored - one of [wallpaperAlignments].
  final Alignment alignment;

  /// How strongly the wallpaper shows, from 0 to 1.
  ///
  /// The wallpaper is faded into the theme's own background colour rather
  /// than darkened. Over the dark theme that comes to the same thing; over
  /// the light theme it lightens instead - where darkening would put a grey
  /// wash under dark text. Either way, what sits on it stays readable.
  final double strength;

  Wallpaper copyWith({
    WallpaperKind? kind,
    String? image,
    String? imageName,
    WallpaperFit? fit,
    Alignment? alignment,
    double? strength,
  }) => Wallpaper(
    kind: kind ?? this.kind,
    image: image ?? this.image,
    imageName: imageName ?? this.imageName,
    fit: fit ?? this.fit,
    alignment: alignment ?? this.alignment,
    strength: strength ?? this.strength,
  );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'image': ?image,
    'imageName': ?imageName,
    'fit': fit.name,
    'alignment': wallpaperAlignments.entries
        .firstWhere(
          (entry) => entry.value == alignment,
          orElse: () => const MapEntry('center', Alignment.center),
        )
        .key,
    'strength': strength,
  };

  /// Reads what [toJson] wrote, keeping the default for anything it cannot
  /// use.
  static Wallpaper fromJson(Object? json) {
    const defaults = Wallpaper();
    if (json is! Map) return defaults;
    String? text(Object? value) => value is String ? value : null;
    final strength = json['strength'];
    return Wallpaper(
      kind: WallpaperKind.values.asNameMap()[json['kind']] ?? defaults.kind,
      image: text(json['image']),
      imageName: text(json['imageName']),
      fit: WallpaperFit.values.asNameMap()[json['fit']] ?? defaults.fit,
      alignment: wallpaperAlignments[json['alignment']] ?? defaults.alignment,
      strength: strength is num && strength >= 0 && strength <= 1
          ? strength.toDouble()
          : defaults.strength,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Wallpaper &&
      other.kind == kind &&
      other.image == image &&
      other.imageName == imageName &&
      other.fit == fit &&
      other.alignment == alignment &&
      other.strength == strength;

  @override
  int get hashCode =>
      Object.hash(kind, image, imageName, fit, alignment, strength);
}

/// Draws [wallpaper], filling the space it is given.
class WallpaperView extends StatelessWidget {
  const WallpaperView({super.key, required this.wallpaper});

  final Wallpaper wallpaper;

  /// The emblem the branding wallpaper draws: the single-colour one the brand
  /// keeps for watermarks. It is drawn in the theme's text colour - light
  /// lines on the dark theme, dark on the light one.
  static const emblem = 'assets/branding/foxtune-emblem-mono.svg';

  /// The most pixels a side a chosen image is decoded to: plenty for any
  /// screen, and a 48-megapixel photo is not held in memory whole.
  static const maxDecodedSize = 2560;

  @override
  Widget build(BuildContext context) {
    // The strength is applied as a colour, never as an opacity animation: an
    // image repaints when it is given a new colour, but not when it is given
    // a new animation that stands still - so a new strength would not show
    // until something else, such as resizing the window, redrew it.
    final Widget drawn;
    switch (wallpaper.kind) {
      case WallpaperKind.none:
        return const SizedBox.expand();

      case WallpaperKind.branding:
        drawn = Center(
          child: FractionallySizedBox(
            widthFactor: 0.6,
            heightFactor: 0.6,
            // Coloured as it is drawn, so a new strength shows at once and
            // never renders the SVG again.
            child: SmoothSvg(
              emblem,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: wallpaper.strength),
            ),
          ),
        );

      case WallpaperKind.image:
        final path = wallpaper.image;
        if (path == null) return const SizedBox.expand();
        drawn = SizedBox.expand(
          child: Image(
            image: ResizeImage(
              FileImage(File(path)),
              width: maxDecodedSize,
              height: maxDecodedSize,
              policy: ResizeImagePolicy.fit,
              allowUpscaling: false,
            ),
            fit: wallpaper.fit.boxFit,
            alignment: wallpaper.alignment,
            repeat: wallpaper.fit.repeat,
            // White changes no colour; its alpha scales the image's.
            color: Colors.white.withValues(alpha: wallpaper.strength),
            colorBlendMode: BlendMode.modulate,
            excludeFromSemantics: true,
            gaplessPlayback: true,
            // A file gone missing, or one that will not decode: nothing, not
            // an error drawn behind every screen.
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          ),
        );
    }
    // A layer of its own, so it is not drawn again every time something in
    // front of it changes - the gauges do, many times a second.
    return RepaintBoundary(child: drawn);
  }
}

/// The file types offered when choosing a wallpaper image.
const wallpaperImageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];

/// Whether [bytes] begin as an image FoxTune can show does: PNG, JPEG, WebP,
/// GIF or BMP. Checked before a file is kept, so what is kept can be drawn.
bool looksLikeImage(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  return at(0, const [0x89, 0x50, 0x4E, 0x47]) ||
      at(0, const [0xFF, 0xD8, 0xFF]) ||
      (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) ||
      at(0, 'GIF8'.codeUnits) ||
      at(0, 'BM'.codeUnits);
}

/// Keeps a copy of [picked] among FoxTune's own files under [root], and
/// returns it.
///
/// A copy, because the original can be moved or deleted - and a phone's
/// picker only hands over a temporary one anyway. Each copy has a name of its
/// own: images are cached by path, and one written over the last would go on
/// showing the last. The copy it takes over from, [replacing], is deleted -
/// but only ever one of FoxTune's own.
File keepWallpaperImage(
  Directory root,
  PickedFile picked, {
  String? replacing,
}) {
  final folder = Directory('${root.path}/wallpapers')
    ..createSync(recursive: true);
  final dot = picked.name.lastIndexOf('.');
  final extension = dot < 0 ? 'image' : picked.name.substring(dot + 1);
  final kept = File(
    '${folder.path}/wallpaper-${DateTime.now().microsecondsSinceEpoch}'
    '.${extension.toLowerCase()}',
  )..writeAsBytesSync(picked.bytes, flush: true);

  if (replacing != null) {
    final old = File(replacing);
    if (old.parent.path == folder.path && old.path != kept.path) {
      try {
        old.deleteSync();
      } on FileSystemException {
        // Gone already.
      }
    }
  }
  return kept;
}
