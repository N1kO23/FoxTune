import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_controls.dart';
import 'window_frame.dart';

/// The bar at the top of a screen - and, where the app draws its own window
/// frame, the window's title bar as well.
///
/// Use this rather than [AppBar] for any screen that fills the window. Where
/// the window's own title bar is hidden (see [windowFrameProvider]), a plain
/// [AppBar] would leave that screen with no way to move, maximize or close the
/// window. With the native frame, and on Android, this is a plain [AppBar] -
/// but for full screen, where there is no frame at all.
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
    final frame = ref.watch(windowFrameProvider);

    return ValueListenableBuilder<bool>(
      valueListenable: window.fullScreen,
      builder: (context, fullScreen, _) {
        if (fullScreen) return _fullScreenBar(window);
        if (!frame.isDrawn) return AppBar(title: title, actions: actions);
        return _drawnBar(context, window, frame);
      },
    );
  }

  /// With no frame, and nothing to drag or maximize: a way out of full screen
  /// takes the window buttons' place, for a screen with no keyboard.
  Widget _fullScreenBar(WindowControls window) {
    final heading = title;
    return AppBar(
      flexibleSpace: _TitleArea(
        window: window,
        maximizes: false,
        child: const SizedBox.expand(),
      ),
      title: heading == null
          ? null
          : _TitleArea(window: window, maximizes: false, child: heading),
      actions: [
        ...?actions,
        IconButton(
          tooltip: 'Exit full screen',
          icon: const Icon(Icons.fullscreen_exit),
          onPressed: () => window.setFullScreen(false),
        ),
      ],
    );
  }

  Widget _drawnBar(
    BuildContext context,
    WindowControls window,
    WindowFrame frame,
  ) {
    final heading = title;
    final buttons = ValueListenableBuilder<bool>(
      valueListenable: window.focused,
      builder: (context, focused, _) =>
          WindowButtons(window: window, style: frame, dimmed: !focused),
    );

    // The macOS buttons lead, before the way back - so the bar takes over
    // what AppBar would otherwise imply there.
    final Widget? leading;
    final double? leadingWidth;
    if (frame == WindowFrame.macos) {
      final implied = _impliedLeading(context);
      final lights = window.hasNativeTrafficLights
          ? const SizedBox(width: _TrafficLights.nativeInset)
          : buttons;
      leading = Row(children: [lights, ?implied]);
      leadingWidth =
          (window.hasNativeTrafficLights
              ? _TrafficLights.nativeInset
              : _TrafficLights.width) +
          (implied == null ? 0 : kToolbarHeight);
    } else {
      leading = null;
      leadingWidth = null;
    }

    return GestureDetector(
      // Around the whole bar, buttons included: a drag recognizer only claims
      // the pointer once it moves, so taps on the buttons are not held up.
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => window.startDragging(),
      child: AppBar(
        leading: leading,
        leadingWidth: leadingWidth,
        // Double-click to maximize is kept off the buttons, unlike the drag: a
        // double-tap recognizer holds on to every tap until the double-tap
        // timeout, which would make each button that much slower to respond.
        // So it covers the empty bar behind them, and the title.
        flexibleSpace: _TitleArea(
          window: window,
          child: const SizedBox.expand(),
        ),
        title: heading == null
            ? null
            : _TitleArea(window: window, child: heading),
        actions: [
          ...?actions,
          if (frame != WindowFrame.macos) ...[
            if (actions?.isNotEmpty ?? false) const SizedBox(width: 8),
            buttons,
          ],
        ],
      ),
    );
  }

  /// The button [AppBar] would put at the start of the bar on its own: the
  /// drawer's, or the way back from this route.
  static Widget? _impliedLeading(BuildContext context) {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.hasDrawer ?? false) return const DrawerButton();
    final route = ModalRoute.of(context);
    final canPop = route?.canPop ?? false;
    if (!((!(scaffold?.hasEndDrawer ?? false) && canPop) ||
        (route?.impliesAppBarDismissal ?? false))) {
      return null;
    }
    return route is PageRoute && route.fullscreenDialog
        ? const CloseButton()
        : const BackButton();
  }
}

/// Where the bar stands for the title bar: double-click to maximize, and
/// right-click - or, on a touch screen, a long press - for the window menu.
class _TitleArea extends StatelessWidget {
  const _TitleArea({
    required this.window,
    required this.child,
    this.maximizes = true,
  });

  final WindowControls window;
  final Widget child;

  /// Off in full screen, where there is nothing to maximize.
  final bool maximizes;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onDoubleTap: maximizes ? window.toggleMaximize : null,
    onSecondaryTapUp: (details) =>
        _showWindowMenu(context, window, details.globalPosition),
    // Touch only: a mouse held still a moment before dragging the bar is a
    // drag, not a call for the menu.
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onLongPressStart: (details) =>
          _showWindowMenu(context, window, details.globalPosition),
      child: child,
    ),
  );
}

enum _WindowAction { minimize, maximize, fullScreen, close }

/// What the desktop's own window menu offers, and full screen - which a
/// screen with no keyboard has no other way into.
Future<void> _showWindowMenu(
  BuildContext context,
  WindowControls window,
  Offset position,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final fullScreen = window.fullScreen.value;
  final hint = Theme.of(context).textTheme.bodySmall
      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

  final picked = await showMenu<_WindowAction>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      if (!fullScreen) ...[
        const PopupMenuItem(
          value: _WindowAction.minimize,
          child: Text('Minimize'),
        ),
        PopupMenuItem(
          value: _WindowAction.maximize,
          child: Text(window.maximized.value ? 'Restore' : 'Maximize'),
        ),
      ],
      PopupMenuItem(
        value: _WindowAction.fullScreen,
        child: Row(
          children: [
            Expanded(
              child: Text(fullScreen ? 'Exit full screen' : 'Full screen'),
            ),
            const SizedBox(width: 24),
            Text('F11', style: hint),
          ],
        ),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: _WindowAction.close, child: Text('Close')),
    ],
  );

  switch (picked) {
    case _WindowAction.minimize:
      await window.minimize();
    case _WindowAction.maximize:
      await window.toggleMaximize();
    case _WindowAction.fullScreen:
      await window.setFullScreen(!fullScreen);
    case _WindowAction.close:
      await window.close();
    case null:
      break;
  }
}

/// Minimize, maximize or restore, and close, drawn in [style].
@visibleForTesting
class WindowButtons extends StatelessWidget {
  const WindowButtons({
    super.key,
    required this.window,
    required this.style,
    required this.dimmed,
  });

  final WindowControls window;
  final WindowFrame style;

  /// Whether the window is in the background, which the buttons show as the
  /// desktop's own do.
  final bool dimmed;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: window.maximized,
    builder: (context, maximized, _) => switch (style) {
      WindowFrame.windows => _CaptionButtons(
        window: window,
        maximized: maximized,
        dimmed: dimmed,
      ),
      WindowFrame.gnome => _GnomeButtons(
        window: window,
        maximized: maximized,
        dimmed: dimmed,
      ),
      WindowFrame.macos => _TrafficLights(
        window: window,
        maximized: maximized,
        dimmed: dimmed,
      ),
      WindowFrame.native => const SizedBox.shrink(),
    },
  );
}

// -- Windows ------------------------------------------------------------------

/// Square buttons the bar's full height, flush with the window's edge.
class _CaptionButtons extends StatelessWidget {
  const _CaptionButtons({
    required this.window,
    required this.maximized,
    required this.dimmed,
  });

  final WindowControls window;
  final bool maximized;
  final bool dimmed;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _CaptionButton(
        glyph: _Glyph.minimize,
        tooltip: 'Minimize',
        onPressed: window.minimize,
        dimmed: dimmed,
      ),
      _CaptionButton(
        glyph: maximized ? _Glyph.restore : _Glyph.maximize,
        tooltip: maximized ? 'Restore' : 'Maximize',
        onPressed: window.toggleMaximize,
        dimmed: dimmed,
      ),
      _CaptionButton(
        glyph: _Glyph.close,
        tooltip: 'Close',
        onPressed: window.close,
        dimmed: dimmed,
        isClose: true,
      ),
    ],
  );
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    required this.dimmed,
    this.isClose = false,
  });

  final _Glyph glyph;
  final String tooltip;
  final VoidCallback onPressed;
  final bool dimmed;

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
    final foreground = _barForeground(context);

    final (Color background, Color glyph) = switch ((_hovered, _pressed)) {
      _ when widget.isClose && (_hovered || _pressed) => (
        _pressed ? _closeRed.withValues(alpha: 0.85) : _closeRed,
        Colors.white,
      ),
      (_, true) => (foreground.withValues(alpha: 0.12), foreground),
      (true, _) => (foreground.withValues(alpha: 0.08), foreground),
      _ => (
        Colors.transparent,
        widget.dimmed ? foreground.withValues(alpha: 0.45) : foreground,
      ),
    };

    return _Pressable(
      tooltip: widget.tooltip,
      onPressed: widget.onPressed,
      onHover: (hovered) => setState(() => _hovered = hovered),
      onPress: (pressed) => setState(() => _pressed = pressed),
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
    );
  }
}

// -- GNOME --------------------------------------------------------------------

/// Round buttons, softly filled, a little in from the window's edge.
class _GnomeButtons extends StatelessWidget {
  const _GnomeButtons({
    required this.window,
    required this.maximized,
    required this.dimmed,
  });

  final WindowControls window;
  final bool maximized;
  final bool dimmed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, right: 10),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 10,
      children: [
        _GnomeButton(
          glyph: _Glyph.minimize,
          tooltip: 'Minimize',
          onPressed: window.minimize,
          dimmed: dimmed,
        ),
        _GnomeButton(
          glyph: maximized ? _Glyph.restore : _Glyph.maximize,
          tooltip: maximized ? 'Restore' : 'Maximize',
          onPressed: window.toggleMaximize,
          dimmed: dimmed,
        ),
        _GnomeButton(
          glyph: _Glyph.close,
          tooltip: 'Close',
          onPressed: window.close,
          dimmed: dimmed,
        ),
      ],
    ),
  );
}

class _GnomeButton extends StatefulWidget {
  const _GnomeButton({
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    required this.dimmed,
  });

  final _Glyph glyph;
  final String tooltip;
  final VoidCallback onPressed;
  final bool dimmed;

  @override
  State<_GnomeButton> createState() => _GnomeButtonState();
}

class _GnomeButtonState extends State<_GnomeButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final foreground = _barForeground(context);
    final fill = switch ((_hovered, _pressed)) {
      (_, true) => 0.26,
      (true, _) => 0.17,
      _ when widget.dimmed => 0.06,
      _ => 0.1,
    };
    final glyph = widget.dimmed && !_hovered
        ? foreground.withValues(alpha: 0.5)
        : foreground;

    return _Pressable(
      tooltip: widget.tooltip,
      onPressed: widget.onPressed,
      onHover: (hovered) => setState(() => _hovered = hovered),
      onPress: (pressed) => setState(() => _pressed = pressed),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: foreground.withValues(alpha: fill),
        ),
        alignment: Alignment.center,
        child: CustomPaint(
          size: const Size.square(8),
          painter: _GlyphPainter(widget.glyph, glyph, strokeWidth: 1.5),
        ),
      ),
    );
  }
}

// -- macOS --------------------------------------------------------------------

/// Red, yellow and green, on the left: close, minimize, maximize. Their
/// glyphs show while the pointer is over any of them; in the background they
/// are grey.
class _TrafficLights extends StatefulWidget {
  const _TrafficLights({
    required this.window,
    required this.maximized,
    required this.dimmed,
  });

  final WindowControls window;
  final bool maximized;
  final bool dimmed;

  /// Across the three, and the space either side of them.
  static const double width = _edge + 3 * _target + _gapAfter;

  /// The room a Mac's own buttons take at the start of the bar.
  static const double nativeInset = 76;

  /// Each light, and the area that takes a click on it.
  static const double _diameter = 12;
  static const double _target = 20;
  static const double _edge = 12;
  static const double _gapAfter = 4;

  @override
  State<_TrafficLights> createState() => _TrafficLightsState();
}

class _TrafficLightsState extends State<_TrafficLights> {
  static const _red = Color(0xFFFF5F57);
  static const _yellow = Color(0xFFFEBC2E);
  static const _green = Color(0xFF28C840);

  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final grey = _barForeground(context).withValues(alpha: 0.25);
    Color lit(Color colour) => widget.dimmed && !_hovered ? grey : colour;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.only(
          left: _TrafficLights._edge,
          right: _TrafficLights._gapAfter,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Light(
              colour: lit(_red),
              glyph: _Glyph.close,
              showGlyph: _hovered,
              tooltip: 'Close',
              onPressed: widget.window.close,
            ),
            _Light(
              colour: lit(_yellow),
              glyph: _Glyph.minimize,
              showGlyph: _hovered,
              tooltip: 'Minimize',
              onPressed: widget.window.minimize,
            ),
            _Light(
              colour: lit(_green),
              glyph: widget.maximized ? _Glyph.restore : _Glyph.maximize,
              showGlyph: _hovered,
              tooltip: widget.maximized ? 'Restore' : 'Maximize',
              onPressed: widget.window.toggleMaximize,
            ),
          ],
        ),
      ),
    );
  }
}

class _Light extends StatefulWidget {
  const _Light({
    required this.colour,
    required this.glyph,
    required this.showGlyph,
    required this.tooltip,
    required this.onPressed,
  });

  final Color colour;
  final _Glyph glyph;
  final bool showGlyph;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_Light> createState() => _LightState();
}

class _LightState extends State<_Light> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => _Pressable(
    tooltip: widget.tooltip,
    onPressed: widget.onPressed,
    onPress: (pressed) => setState(() => _pressed = pressed),
    child: SizedBox.square(
      dimension: _TrafficLights._target,
      child: Center(
        child: CustomPaint(
          size: const Size.square(_TrafficLights._diameter),
          painter: _LightPainter(
            colour: _pressed
                ? Color.alphaBlend(
                    Colors.black.withValues(alpha: 0.2),
                    widget.colour,
                  )
                : widget.colour,
            glyph: widget.showGlyph ? widget.glyph : null,
          ),
        ),
      ),
    ),
  );
}

class _LightPainter extends CustomPainter {
  _LightPainter({required this.colour, required this.glyph});

  final Color colour;

  /// `null` while the pointer is elsewhere.
  final _Glyph? glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    canvas
      ..drawCircle(centre, radius, Paint()..color = colour)
      ..drawCircle(
        centre,
        radius - 0.25,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5
          ..color = Colors.black.withValues(alpha: 0.12),
      );

    final glyph = this.glyph;
    if (glyph == null) return;
    final ink = Colors.black.withValues(alpha: 0.55);
    final line = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    final solid = Paint()..color = ink;
    final (x, y) = (centre.dx, centre.dy);

    // A right triangle with its square corner at [at], its legs [reach] long,
    // running towards [dx] and [dy].
    Path corner(Offset at, double dx, double dy, double reach) => Path()
      ..moveTo(at.dx, at.dy)
      ..lineTo(at.dx + dx * reach, at.dy)
      ..lineTo(at.dx, at.dy + dy * reach)
      ..close();

    switch (glyph) {
      case _Glyph.close:
        canvas
          ..drawLine(Offset(x - 2.5, y - 2.5), Offset(x + 2.5, y + 2.5), line)
          ..drawLine(Offset(x + 2.5, y - 2.5), Offset(x - 2.5, y + 2.5), line);
      case _Glyph.minimize:
        canvas.drawLine(Offset(x - 3, y), Offset(x + 3, y), line);
      case _Glyph.maximize:
        // Two corners pointing out: grow.
        canvas
          ..drawPath(corner(Offset(x - 3, y - 3), 1, 1, 4.5), solid)
          ..drawPath(corner(Offset(x + 3, y + 3), -1, -1, 4.5), solid);
      case _Glyph.restore:
        // Two corners pointing in: shrink.
        canvas
          ..drawPath(corner(Offset(x - 0.6, y - 0.6), -1, -1, 3.5), solid)
          ..drawPath(corner(Offset(x + 0.6, y + 0.6), 1, 1, 3.5), solid);
    }
  }

  @override
  bool shouldRepaint(_LightPainter oldDelegate) =>
      colour != oldDelegate.colour || glyph != oldDelegate.glyph;
}

// -- Shared -------------------------------------------------------------------

/// The bar's action colour, so the window buttons match the icons beside
/// them.
Color _barForeground(BuildContext context) =>
    IconTheme.of(context).color ?? Theme.of(context).colorScheme.onSurface;

/// A window button's behaviour, whatever it looks like: a tooltip, a button to
/// screen readers, and hover and press reported for the look to follow.
class _Pressable extends StatelessWidget {
  const _Pressable({
    required this.tooltip,
    required this.onPressed,
    required this.child,
    this.onHover,
    this.onPress,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final ValueChanged<bool>? onHover;
  final ValueChanged<bool>? onPress;
  final Widget child;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      child: MouseRegion(
        onEnter: (_) => onHover?.call(true),
        onExit: (_) => onHover?.call(false),
        child: GestureDetector(
          onTapDown: (_) => onPress?.call(true),
          onTapCancel: () => onPress?.call(false),
          onTapUp: (_) => onPress?.call(false),
          onTap: onPressed,
          child: child,
        ),
      ),
    ),
  );
}

enum _Glyph { minimize, maximize, restore, close }

/// Hairline caption glyphs, drawn rather than taken from the icon font so
/// they stay thin and sharp at this size.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color, {this.strokeWidth = 1});

  final _Glyph glyph;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    // Strokes sit half their width in, so a one-pixel line covers one pixel,
    // not two half-lit ones.
    final lo = strokeWidth / 2;
    final hi = size.width - lo;

    switch (glyph) {
      case _Glyph.minimize:
        final y = (size.height / 2).floorToDouble() + lo;
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
      glyph != oldDelegate.glyph ||
      color != oldDelegate.color ||
      strokeWidth != oldDelegate.strokeWidth;
}
