import 'package:flutter/foundation.dart';

/// Which of FoxTune's animations and effects are wanted. All on unless turned
/// off - and the movement stays still anyway where the system asks for
/// reduced motion; see `Motion.of`.
@immutable
class MotionSettings {
  const MotionSettings({
    this.liveData = true,
    this.transitions = true,
    this.glow = true,
  });

  /// Nothing moves that does not have to, and nothing glows.
  static const off = MotionSettings(
    liveData: false,
    transitions: false,
    glow: false,
  );

  /// Dials, bars and the live table marker glide from one reading to the
  /// next rather than jumping; lamps fade; graphs scroll smoothly.
  final bool liveData;

  /// Tabs, dashboard pages and screens fade as they change, and gauges ease
  /// in when a page opens.
  final bool transitions;

  /// A soft glow under live readings and on buttons under the pointer - and
  /// the Grid wallpaper's glow drifts.
  final bool glow;

  bool get allOn => liveData && transitions && glow;

  bool get allOff => !liveData && !transitions && !glow;

  MotionSettings copyWith({bool? liveData, bool? transitions, bool? glow}) =>
      MotionSettings(
        liveData: liveData ?? this.liveData,
        transitions: transitions ?? this.transitions,
        glow: glow ?? this.glow,
      );

  Map<String, Object?> toJson() => {
    'liveData': liveData,
    'transitions': transitions,
    'glow': glow,
  };

  /// Reads what [toJson] wrote; anything missing or not understood keeps its
  /// default, one switch at a time.
  static MotionSettings fromJson(Object? json) {
    const defaults = MotionSettings();
    if (json is! Map) return defaults;
    bool? flag(Object? value) => value is bool ? value : null;
    return MotionSettings(
      liveData: flag(json['liveData']) ?? defaults.liveData,
      transitions: flag(json['transitions']) ?? defaults.transitions,
      glow: flag(json['glow']) ?? defaults.glow,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MotionSettings &&
      other.liveData == liveData &&
      other.transitions == transitions &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(liveData, transitions, glow);
}
