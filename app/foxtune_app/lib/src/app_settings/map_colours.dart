import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A colour at one point of a [MapGradient].
@immutable
class GradientStop {
  const GradientStop(this.position, this.color);

  /// Where, from 0 - a table's lowest value - to 1, its highest.
  final double position;

  final Color color;

  @override
  bool operator ==(Object other) =>
      other is GradientStop &&
      other.position == position &&
      other.color == color;

  @override
  int get hashCode => Object.hash(position, color);

  @override
  String toString() => 'GradientStop($position, $color)';
}

/// How the maps are coloured: a gradient from a table's lowest value to its
/// highest.
///
/// Its colours can be partly transparent. A map is drawn on the theme's own
/// surface, and a transparent stop shows that - which is how one set of
/// colours suits the light theme and the dark alike.
@immutable
class MapGradient {
  const MapGradient(this.name, this.stops);

  final String name;

  /// In order of position; two at least, which [fromJson] and the editor
  /// see to.
  final List<GradientStop> stops;

  /// The colour at [t], from 0 to 1: blended from the stops either side of
  /// it, and the outermost colour beyond them.
  Color colorAt(double t) {
    final at = t.isNaN ? 0.0 : t.clamp(0.0, 1.0);
    if (at <= stops.first.position) return stops.first.color;
    for (var i = 1; i < stops.length; i++) {
      final right = stops[i];
      if (at <= right.position) {
        final left = stops[i - 1];
        final span = right.position - left.position;
        return span <= 0
            ? right.color
            : Color.lerp(left.color, right.color, (at - left.position) / span)!;
      }
    }
    return stops.last.color;
  }

  /// The same colours the other way round, under [name].
  MapGradient reversed(String name) => MapGradient(name, [
    for (final stop in stops.reversed)
      GradientStop(1 - stop.position, stop.color),
  ]);

  /// Whether [other] colours a map exactly as this does, whatever it is
  /// called.
  bool sameColoursAs(MapGradient other) => listEquals(stops, other.stops);

  Map<String, Object?> toJson() => {
    'name': name,
    'stops': [
      for (final stop in stops)
        {'at': stop.position, 'color': hexOf(stop.color)},
    ],
  };

  /// Reads what [toJson] wrote, or `null` if it is not a gradient - one with
  /// fewer than two colours, say.
  static MapGradient? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final stops = json['stops'];
    if (name is! String || stops is! List) return null;
    final read = <GradientStop>[];
    for (final stop in stops) {
      if (stop is! Map) return null;
      final at = stop['at'];
      final color = colorFromHex('${stop['color']}');
      if (at is! num || color == null) return null;
      read.add(GradientStop(at.toDouble().clamp(0.0, 1.0), color));
    }
    if (read.length < 2) return null;
    read.sort((a, b) => a.position.compareTo(b.position));
    return MapGradient(name, read);
  }

  @override
  bool operator ==(Object other) =>
      other is MapGradient && other.name == name && sameColoursAs(other);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(stops));

  @override
  String toString() => 'MapGradient($name, $stops)';
}

/// The FoxTune pink, from nothing to 55%: a map shaded in the brand's one
/// hue, light to dark - as it always was.
const foxTuneGradient = MapGradient('FoxTune', [
  GradientStop(0, Color(0x00FF2E6E)),
  GradientStop(1, Color(0x8CFF2E6E)),
]);

/// The gradients FoxTune comes with.
///
/// A single hue, light to dark, reads as more or less and nothing else, so
/// those come first. Viridis and Inferno go through several hues but still
/// only one way in lightness, which keeps them readable to colour-blind eyes.
/// Classic is the blue, green, yellow and red TunerStudio shades its tables
/// with: familiar, but the bands it draws are not there in the numbers.
const builtInGradients = [
  foxTuneGradient,
  MapGradient('Ocean', [
    GradientStop(0, Color(0x000277BD)),
    GradientStop(1, Color(0xA60277BD)),
  ]),
  MapGradient('Grey', [
    GradientStop(0, Color(0x00808080)),
    GradientStop(1, Color(0xB3808080)),
  ]),
  MapGradient('Viridis', [
    GradientStop(0, Color(0xFF440154)),
    GradientStop(0.25, Color(0xFF3B528B)),
    GradientStop(0.5, Color(0xFF21918C)),
    GradientStop(0.75, Color(0xFF5EC962)),
    GradientStop(1, Color(0xFFFDE725)),
  ]),
  MapGradient('Inferno', [
    GradientStop(0, Color(0xFF000004)),
    GradientStop(0.25, Color(0xFF57106E)),
    GradientStop(0.5, Color(0xFFBC3754)),
    GradientStop(0.75, Color(0xFFF98E09)),
    GradientStop(1, Color(0xFFFCFFA4)),
  ]),
  MapGradient('Classic', [
    GradientStop(0, Color(0xCC1E88E5)),
    GradientStop(1 / 3, Color(0xCC43A047)),
    GradientStop(2 / 3, Color(0xCCFDD835)),
    GradientStop(1, Color(0xCCE53935)),
  ]),
];

/// The map gradient in force, as the theme carries it to every table grid,
/// 3D surface and coverage map.
@immutable
class MapColours extends ThemeExtension<MapColours> {
  const MapColours(this.gradient);

  final MapGradient gradient;

  /// The theme's, or the FoxTune gradient where it has none.
  static MapColours of(BuildContext context) =>
      Theme.of(context).extension<MapColours>() ??
      const MapColours(foxTuneGradient);

  /// The colour of a map at [t] on [base]: opaque, whatever the gradient's
  /// alpha, so a wallpaper never shows through a cell.
  Color on(Color base, double t) => Color.alphaBlend(gradient.colorAt(t), base);

  @override
  MapColours copyWith({MapGradient? gradient}) =>
      MapColours(gradient ?? this.gradient);

  @override
  MapColours lerp(MapColours? other, double t) =>
      other == null || t < 0.5 ? this : other;
}

/// [preferred], where it stands out from [background] by [minContrast] -
/// otherwise black or white, whichever stands out more.
///
/// A gradient is the user's to choose, so the text on it cannot be: the
/// numbers have to stay readable on any colour a map can be.
Color readableOn(
  Color background,
  Color preferred, {
  double minContrast = 4.5,
}) {
  if (contrastOf(preferred, background) >= minContrast) return preferred;
  const black = Color(0xFF000000);
  const white = Color(0xFFFFFFFF);
  return contrastOf(black, background) >= contrastOf(white, background)
      ? black
      : white;
}

/// The WCAG contrast ratio of [a] and [b], from 1 to 21.
double contrastOf(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [color] as `#RRGGBB`, or `#RRGGBBAA` where it is not opaque - the way a
/// web page or a design tool writes it.
String hexOf(Color color) {
  String two(double channel) =>
      (channel * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
  final rgb = '#${two(color.r)}${two(color.g)}${two(color.b)}';
  return color.a >= 1 ? rgb : '$rgb${two(color.a)}';
}

/// The colour [text] spells as `#RRGGBB` or `#RRGGBBAA`, the `#` optional; or
/// `null` if it does not.
Color? colorFromHex(String text) {
  final hex = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(hex)) {
    return null;
  }
  final value = int.parse(hex, radix: 16);
  return hex.length == 6
      ? Color(0xFF000000 | value)
      : Color(((value & 0xFF) << 24) | (value >> 8));
}
