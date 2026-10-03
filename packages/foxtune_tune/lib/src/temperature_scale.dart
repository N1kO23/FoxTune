/// A temperature scale, as named by a units string.
enum TemperatureScale {
  celsius,
  fahrenheit;

  /// The scale [units] names - `C`, `°C`, `deg F` - or `null` for units that
  /// name none, plain `deg` of ignition timing included.
  static TemperatureScale? of(String units) {
    final bare = units
        .replaceAll('°', '')
        .replaceAll(RegExp('deg', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s'), '')
        .toLowerCase();
    return switch (bare) {
      'c' => celsius,
      'f' => fahrenheit,
      _ => null,
    };
  }
}
