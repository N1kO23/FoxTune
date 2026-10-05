import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../branding/brand_theme.dart';
import '../motion/motion.dart';

/// The website's backdrop: a hairline grid, and a soft pink glow towards the
/// upper right - drifting slowly about, where glow is on and motion allowed.
///
/// Both are as strong as [strength] makes them, given as colour like the
/// other wallpapers' strength.
class GridWallpaper extends StatefulWidget {
  const GridWallpaper({super.key, required this.strength});

  final double strength;

  /// The grid's pitch, as on the website.
  static const pitch = 44.0;

  /// How often the drifting glow moves. It moves a fraction of a pixel each
  /// time, so this is plenty - and a full-screen layer redrawn on every frame
  /// would cost a phone's battery for no visible gain.
  static const driftStep = Duration(milliseconds: 83);

  @override
  State<GridWallpaper> createState() => GridWallpaperState();
}

class GridWallpaperState extends State<GridWallpaper> {
  final _seconds = ValueNotifier<double>(0);
  final _clock = Stopwatch();
  Timer? _timer;

  /// Whether the glow is drifting now.
  @visibleForTesting
  bool get drifting => _timer != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Drifts only while it can be seen: not under a screen pushed over it.
    final drift =
        Motion.of(context).drift && TickerMode.valuesOf(context).enabled;
    if (drift && _timer == null) {
      _clock.start();
      _timer = Timer.periodic(GridWallpaper.driftStep, (_) {
        _seconds.value = _clock.elapsedMicroseconds / 1e6;
      });
    } else if (!drift && _timer != null) {
      _clock.stop();
      _timer!.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The glow moves; the grid does not - a layer each, so the grid is
        // not drawn again with every step of the glow.
        RepaintBoundary(
          child: CustomPaint(
            painter: _GlowPainter(
              seconds: _seconds,
              colour: brandPink.withValues(
                alpha: (widget.strength * 0.9).clamp(0.0, 1.0),
              ),
            ),
          ),
        ),
        RepaintBoundary(
          child: CustomPaint(
            painter: _GridPainter(
              colour: ink.withValues(
                alpha: (widget.strength * 0.4).clamp(0.0, 1.0),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.colour});

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    const pitch = GridWallpaper.pitch;
    final line = Paint()
      ..color = colour
      ..strokeWidth = 1;
    // Centred across, from the top down - as the website lays it.
    for (var x = (size.width / 2) % pitch; x < size.width; x += pitch) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y < size.height; y += pitch) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.colour != colour;
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({required this.seconds, required this.colour})
    : super(repaint: seconds);

  final ValueListenable<double> seconds;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final t = seconds.value;
    // A slow Lissajous wander about the upper right, never settling into an
    // obvious loop.
    final centre = Offset(
      size.width * (0.8 + 0.08 * math.sin(2 * math.pi * t / 40)),
      size.height * (0.25 + 0.07 * math.sin(2 * math.pi * t / 27)),
    );
    final radius = 0.6 * math.max(size.width, size.height);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(colors: [colour, colour.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: centre, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) =>
      old.colour != colour || old.seconds != seconds;
}
