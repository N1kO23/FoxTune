import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// An [IndexedStack] whose newly shown child fades in, rising a little, when
/// [index] changes - with transitions on. Every child keeps its state, as in
/// a plain [IndexedStack].
///
/// A fade-through rather than a cross-fade: the child going away goes at
/// once, so two screens never show through each other.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  static const duration = Duration(milliseconds: 180);

  /// How far the shown child rises as it fades in.
  static const rise = 8.0;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: FadeIndexedStack.duration,
    value: 1,
  );
  late final _shown = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && Motion.of(context).transitions) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _shown,
    child: AnimatedBuilder(
      animation: _shown,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, FadeIndexedStack.rise * (1 - _shown.value)),
        child: child,
      ),
      child: IndexedStack(index: widget.index, children: widget.children),
    ),
  );
}

/// Eases in the [EntranceItem]s below it one after another, once - when it
/// is first built - with transitions on.
///
/// Once in, an item costs nothing: fully shown and at full size, it is drawn
/// with no layer of its own.
class StaggeredEntrance extends StatefulWidget {
  const StaggeredEntrance({super.key, required this.child});

  final Widget child;

  /// How long each item takes to come in.
  static const item = Duration(milliseconds: 220);

  /// How long after the one before each item starts.
  static const stagger = Duration(milliseconds: 25);

  /// The latest any item starts, however many there are: a full page is not
  /// kept waiting for its last gauge.
  static const latestStart = Duration(milliseconds: 300);

  static const total = Duration(milliseconds: 520);

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: StaggeredEntrance.total,
    value: 1,
  );
  var _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.of(context).transitions) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _EntranceScope(animation: _controller, child: widget.child);
}

class _EntranceScope extends InheritedWidget {
  const _EntranceScope({required this.animation, required super.child});

  final Animation<double> animation;

  @override
  bool updateShouldNotify(_EntranceScope old) => animation != old.animation;
}

/// The [index]th thing to come in under a [StaggeredEntrance]: it fades in
/// and grows to full size from a little under it. Shown as it is with no
/// [StaggeredEntrance] above it.
class EntranceItem extends StatelessWidget {
  const EntranceItem({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_EntranceScope>();
    if (scope == null) return child;

    final total = StaggeredEntrance.total.inMicroseconds;
    final start = math.min(
      index * StaggeredEntrance.stagger.inMicroseconds,
      StaggeredEntrance.latestStart.inMicroseconds,
    );
    final end = start + StaggeredEntrance.item.inMicroseconds;
    // Driven rather than curved: a CurvedAnimation would listen to the
    // controller from the moment it is made, and one is made every build.
    final shown = scope.animation.drive(
      CurveTween(
        curve: Interval(start / total, end / total, curve: Curves.easeOutCubic),
      ),
    );
    return FadeTransition(
      opacity: shown,
      child: ScaleTransition(
        scale: shown.drive(Tween(begin: 0.96, end: 1.0)),
        child: child,
      ),
    );
  }
}
