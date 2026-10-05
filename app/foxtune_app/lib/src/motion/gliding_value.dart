import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Builds with [value] - or, with live data motion on, with a value that
/// glides to it from the last one over [Motion.glide], so a dial's arc or the
/// table's live marker moves between readings rather than jumping.
///
/// For the drawing only: anything that states the reading, such as the number
/// under a dial, takes it as it is, never the glide.
///
/// [T] is anything [Tween] can blend: a `double` or an `Offset`.
class GlidingValue<T extends Object> extends StatelessWidget {
  const GlidingValue({
    super.key,
    required this.value,
    required this.builder,
    this.child,
    this.curve = Curves.linear,
    this.duration,
  });

  final T value;
  final ValueWidgetBuilder<T> builder;

  /// Handed to [builder] as it is, not built again on every frame of the
  /// glide.
  final Widget? child;

  /// Linear by default: each new reading lands while the last glide is still
  /// running, and steady motion between them reads as one smooth movement.
  final Curve curve;

  /// How long the glide takes; [Motion.glide] unless given.
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context);
    if (!motion.liveData) return builder(context, value, child);
    return TweenAnimationBuilder<T>(
      tween: Tween<T>(end: value),
      duration: duration ?? motion.glide,
      curve: curve,
      builder: builder,
      child: child,
    );
  }
}
