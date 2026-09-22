import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_controls.dart';

/// The bar at the top of a screen - and, where the app draws its own window
/// frame, the window's title bar as well.
///
/// Use this rather than [AppBar] for any screen that fills the window. On
/// Linux and Windows the native title bar is hidden (see [initWindowFrame]),
/// so a plain [AppBar] would leave that screen with no way to move, maximize
/// or close the window. Elsewhere this is a plain [AppBar].
class WindowAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const WindowAppBar({super.key, this.title, this.actions});

  final Widget? title;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(windowControlsProvider);
    if (window == null) return AppBar(title: title, actions: actions);

    final heading = title;
    return GestureDetector(
      // Around the whole bar, buttons included: a drag recognizer only claims
      // the pointer once it moves, so taps on the buttons are not held up.
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => window.startDragging(),
      child: AppBar(
        // Double-click to maximize is kept off the buttons, unlike the drag: a
        // double-tap recognizer holds on to every tap until the double-tap
        // timeout, which would make each button that much slower to respond.
        // So it covers the empty bar behind them, and the title.
        flexibleSpace: _MaximizeOnDoubleTap(
          window: window,
          child: const SizedBox.expand(),
        ),
        title: heading == null
            ? null
            : _MaximizeOnDoubleTap(window: window, child: heading),
        actions: [
          ...?actions,
          if (actions?.isNotEmpty ?? false) const SizedBox(width: 8),
          _CaptionButtons(window: window),
        ],
      ),
    );
  }
}

class _MaximizeOnDoubleTap extends StatelessWidget {
  const _MaximizeOnDoubleTap({required this.window, required this.child});

  final WindowControls window;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onDoubleTap: window.toggleMaximize,
    child: child,
  );
}

/// Minimize, maximize or restore, and close - flush with the window's edge.
class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons({required this.window});

  final WindowControls window;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: window.maximized,
    builder: (context, maximized, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          glyph: _Glyph.minimize,
          tooltip: 'Minimize',
          onPressed: window.minimize,
        ),
        _CaptionButton(
          glyph: maximized ? _Glyph.restore : _Glyph.maximize,
          tooltip: maximized ? 'Restore' : 'Maximize',
          onPressed: window.toggleMaximize,
        ),
        _CaptionButton(
          glyph: _Glyph.close,
          tooltip: 'Close',
          onPressed: window.close,
          isClose: true,
        ),
      ],
    ),
  );
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.isClose = false,
  });

  final _Glyph glyph;
  final String tooltip;
  final VoidCallback onPressed;

  /// Turns red under the pointer, as close does on every desktop.
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  static const _closeRed = Color(0xFFC42B1C);

  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // The bar's action colour, so the glyphs match the icons beside them.
    final foreground =
        IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;

    final (Color background, Color glyph) = switch ((_hovered, _pressed)) {
      _ when widget.isClose && (_hovered || _pressed) => (
        _pressed ? _closeRed.withValues(alpha: 0.85) : _closeRed,
        Colors.white,
      ),
      (_, true) => (foreground.withValues(alpha: 0.12), foreground),
      (true, _) => (foreground.withValues(alpha: 0.08), foreground),
      _ => (Colors.transparent, foreground),
    };

    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 46,
              height: kToolbarHeight,
              color: background,
              alignment: Alignment.center,
              child: CustomPaint(
                size: const Size.square(10),
                painter: _GlyphPainter(widget.glyph, glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Glyph { minimize, maximize, restore, close }

/// Hairline caption glyphs, drawn rather than taken from the icon font so
/// they stay thin and sharp at this size.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Strokes sit on half pixels so a one-pixel line covers one pixel, not
    // two half-lit ones.
    const lo = 0.5;
    final hi = size.width - 0.5;

    switch (glyph) {
      case _Glyph.minimize:
        final y = size.height / 2 + 0.5;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      case _Glyph.maximize:
        canvas.drawRect(Rect.fromLTRB(lo, lo, hi, hi), paint);
      case _Glyph.restore:
        // A window in front, and the corner of the one behind it.
        const offset = 2.0;
        canvas.drawRect(Rect.fromLTRB(lo, lo + offset, hi - offset, hi), paint);
        canvas.drawPath(
          Path()
            ..moveTo(lo + offset, lo + offset)
            ..lineTo(lo + offset, lo)
            ..lineTo(hi, lo)
            ..lineTo(hi, hi - offset)
            ..lineTo(hi - offset, hi - offset),
          paint,
        );
      case _Glyph.close:
        canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
        canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph || color != oldDelegate.color;
}
