import 'package:flutter/material.dart';

import '../app_settings/motion_settings.dart';
import '../branding/brand_theme.dart';

/// The animations and effects in force, carried by the theme so every widget
/// reaches them without being handed them - as the map colours are.
///
/// Read through [Motion.of], which also takes in what the system asks for.
@immutable
class Motion extends ThemeExtension<Motion> {
  const Motion({
    this.liveData = false,
    this.transitions = false,
    this.glow = false,
    this.drift = false,
    this.glide = const Duration(milliseconds: 80),
  });

  /// [settings] as the app wants them, for live data read every
  /// [liveDataInterval].
  factory Motion.from(
    MotionSettings settings, {
    required Duration liveDataInterval,
  }) => Motion(
    liveData: settings.liveData,
    transitions: settings.transitions,
    glow: settings.glow,
    drift: settings.glow,
    glide: glideFor(liveDataInterval),
  );

  /// Nothing moves and nothing glows: what a widget gets with no [Motion] in
  /// its theme - the widget tests, among others.
  static const still = Motion();

  /// Live values glide to each new reading rather than jump.
  final bool liveData;

  /// Tabs, pages and screens fade as they change.
  final bool transitions;

  /// Glows under live readings and on buttons under the pointer.
  final bool glow;

  /// The Grid wallpaper's glow drifts. Follows [glow], where motion is
  /// allowed.
  final bool drift;

  /// How long a live value takes to reach a new reading: a little longer than
  /// the time between readings, so it is still moving when the next one comes
  /// and the motion runs on rather than stopping and starting.
  final Duration glide;

  /// The [glide] for live data read every [interval].
  static Duration glideFor(Duration interval) {
    final micros = (interval.inMicroseconds * 1.25).round();
    return Duration(microseconds: micros.clamp(60000, 250000));
  }

  /// The motion in force at [context]: the theme's, with the movement left
  /// out where the system asks for reduced motion. Glow stays - it does not
  /// move.
  static Motion of(BuildContext context) {
    final chosen = Theme.of(context).extension<Motion>() ?? still;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return chosen.copyWith(liveData: false, transitions: false, drift: false);
    }
    return chosen;
  }

  @override
  Motion copyWith({
    bool? liveData,
    bool? transitions,
    bool? glow,
    bool? drift,
    Duration? glide,
  }) => Motion(
    liveData: liveData ?? this.liveData,
    transitions: transitions ?? this.transitions,
    glow: glow ?? this.glow,
    drift: drift ?? this.drift,
    glide: glide ?? this.glide,
  );

  /// Switches, not quantities: there is nothing between on and off.
  @override
  Motion lerp(Motion? other, double t) =>
      t < 0.5 || other == null ? this : other;

  @override
  bool operator ==(Object other) =>
      other is Motion &&
      other.liveData == liveData &&
      other.transitions == transitions &&
      other.glow == glow &&
      other.drift == drift &&
      other.glide == glide;

  @override
  int get hashCode => Object.hash(liveData, transitions, glow, drift, glide);
}

/// [theme] with [motion] in it, and the parts of the theme it decides: how
/// screens come and go, and whether buttons glow under the pointer.
ThemeData applyMotion(ThemeData theme, Motion motion) {
  final PageTransitionsBuilder pages = motion.transitions
      ? const FadeForwardsPageTransitionsBuilder()
      : const _InstantPageTransitionsBuilder();
  bool hovered(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) &&
      !states.contains(WidgetState.disabled);

  return theme.copyWith(
    extensions: [...theme.extensions.values, motion],
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final platform in TargetPlatform.values) platform: pages},
    ),
    // Lifted on a pink glow under the pointer, as the website's buttons are.
    // Anything left null here falls through to the button's own default.
    filledButtonTheme: motion.glow
        ? FilledButtonThemeData(
            style: ButtonStyle(
              elevation: WidgetStateProperty.resolveWith(
                (states) => hovered(states) ? 4 : null,
              ),
              shadowColor: WidgetStatePropertyAll(
                brandPink.withValues(alpha: 0.7),
              ),
            ),
          )
        : null,
    // An outline has nothing under it to glow; it takes the accent instead.
    outlinedButtonTheme: motion.glow
        ? OutlinedButtonThemeData(
            style: ButtonStyle(
              side: WidgetStateProperty.resolveWith(
                (states) => hovered(states)
                    ? BorderSide(color: theme.colorScheme.primary)
                    : null,
              ),
            ),
          )
        : null,
  );
}

/// Screens that come and go at once.
class _InstantPageTransitionsBuilder extends PageTransitionsBuilder {
  const _InstantPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
