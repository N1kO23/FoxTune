import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// An SVG asset, drawn smooth at any size and pixel density.
///
/// Impeller, the renderer Flutter draws with, smooths the edge of a shape only
/// by four-sample multisampling - five shades from outside to inside - and on
/// a GPU that cannot multisample, not at all. Line art as fine as the FoxTune
/// icon at 36 pixels comes out stepped, where the same art rendered by rsvg
/// into a PNG is smooth.
///
/// So the SVG is rendered off screen at four times the pixels it covers, and
/// halved twice with bilinear filtering - which, halving at exact pixel
/// alignment, averages each 2 x 2 block. Every pixel shown is the average of
/// sixteen, whatever the GPU offers. What is drawn is a bitmap of exactly the
/// pixels covered: sharp at any density, 125% included, where PNGs rendered
/// for 1x and 2x are resampled.
class SmoothSvg extends StatefulWidget {
  const SmoothSvg(this.asset, {super.key, this.width, this.height, this.color});

  /// The SVG, flattened - see `branding/README.md`.
  final String asset;

  final double? width;
  final double? height;

  /// Paints the artwork in this colour, its alpha included - for
  /// single-colour art such as the wallpaper's watermark. Applied as the
  /// bitmap is drawn, so a new colour never renders the SVG again.
  final Color? color;

  @override
  State<SmoothSvg> createState() => _SmoothSvgState();
}

class _SmoothSvgState extends State<SmoothSvg> {
  PictureInfo? _picture;
  ui.Image? _image;
  bool _loading = false;
  bool _rendering = false;

  /// The pixels [_image] was rendered at, and the ones last asked for.
  (int, int)? _rendered;
  (int, int)? _wanted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_picture == null && !_loading) _load();
  }

  @override
  void didUpdateWidget(SmoothSvg old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) {
      _forget();
      _load();
    }
  }

  @override
  void dispose() {
    _forget();
    super.dispose();
  }

  void _forget() {
    _picture?.picture.dispose();
    _picture = null;
    _image?.dispose();
    _image = null;
    _rendered = null;
  }

  Future<void> _load() async {
    final asset = widget.asset;
    _loading = true;
    try {
      final picture = await vg.loadPicture(SvgAssetLoader(asset), context);
      if (!mounted || asset != widget.asset) {
        picture.picture.dispose();
        return;
      }
      setState(() => _picture = picture);
    } on Object catch (error) {
      debugPrint('FoxTune: could not load $asset: $error');
    } finally {
      _loading = false;
    }
  }

  /// Asks for the artwork at [pixels], rendering it unless it is already, or
  /// is being.
  void _ask((int, int) pixels) {
    _wanted = pixels;
    if (!_rendering && pixels != _rendered) _render();
  }

  Future<void> _render() async {
    final picture = _picture;
    final wanted = _wanted;
    if (picture == null || wanted == null) return;
    _rendering = true;
    try {
      final image = await rasteriseSmooth(
        picture.picture,
        picture.size,
        wanted.$1,
        wanted.$2,
      );
      if (!mounted || !identical(picture, _picture)) {
        image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = image;
        _rendered = wanted;
      });
    } on Object catch (error) {
      debugPrint('FoxTune: could not draw ${widget.asset}: $error');
      // Not tried again at this size.
      _rendered = wanted;
    } finally {
      _rendering = false;
    }
    // Asked for other pixels meanwhile - a window being resized, say. The
    // latest is all that matters, however many came in between.
    if (mounted && _wanted != _rendered) _render();
  }

  @override
  Widget build(BuildContext context) {
    final ratio =
        MediaQuery.maybeDevicePixelRatioOf(context) ??
        View.of(context).devicePixelRatio;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final picture = _picture;
          if (picture == null) return const SizedBox.shrink();

          // Fitted into the space given, as SvgPicture would be.
          final space = constraints.biggest.isFinite
              ? constraints.biggest
              : picture.size;
          final fitted = applyBoxFit(
            BoxFit.contain,
            picture.size,
            space,
          ).destination;
          final pixels = (
            (fitted.width * ratio).round(),
            (fitted.height * ratio).round(),
          );
          if (pixels.$1 <= 0 || pixels.$2 <= 0) return const SizedBox.shrink();
          _ask(pixels);

          final image = _image;
          if (image == null) return const SizedBox.shrink();
          return Center(
            child: RawImage(
              image: image,
              // One image pixel to one screen pixel. Until an image for a new
              // size is ready, the last one is stretched to fit.
              width: pixels.$1 / ratio,
              height: pixels.$2 / ratio,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
              color: widget.color,
              colorBlendMode: BlendMode.srcIn,
            ),
          );
        },
      ),
    );
  }
}

/// Renders [picture], drawn [size] big, into an image [width] by [height]
/// pixels - from sixteen times as many, halved twice. See [SmoothSvg].
///
/// Where sixteen times as many would come to more than [budget] pixels - a
/// wallpaper-sized emblem on a large screen - it starts from four times as
/// many, or as a last resort from as many: at that size the steps are small
/// enough to need less.
Future<ui.Image> rasteriseSmooth(
  ui.Picture picture,
  Size size,
  int width,
  int height, {
  int budget = 16 * 1024 * 1024,
}) async {
  var factor = 4;
  while (factor > 1 && width * factor * height * factor > budget) {
    factor ~/= 2;
  }

  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(width * factor / size.width, height * factor / size.height)
    ..drawPicture(picture);
  final recording = recorder.endRecording();
  var image = await recording.toImage(width * factor, height * factor);
  recording.dispose();

  for (; factor > 1; factor ~/= 2) {
    image = await halve(image);
  }
  return image;
}

/// [source] at half its width and height, each pixel the average of the 2 x
/// 2 block it covered. [source] is disposed.
///
/// Bilinear filtering does the averaging: halving at exact pixel alignment,
/// each pixel of the result samples the point where four of the source's
/// meet, and weighs them equally.
@visibleForTesting
Future<ui.Image> halve(ui.Image source) async {
  assert(source.width.isEven && source.height.isEven);
  final width = source.width ~/ 2;
  final height = source.height ~/ 2;
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..filterQuality = FilterQuality.low,
  );
  final recording = recorder.endRecording();
  final half = await recording.toImage(width, height);
  recording.dispose();
  source.dispose();
  return half;
}
