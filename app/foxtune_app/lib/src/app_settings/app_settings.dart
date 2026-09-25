import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/gauge_status.dart';
import '../storage/json_store.dart';

/// Choices about FoxTune itself, as against the ECU's own settings.
///
/// Kept in `settings.json` in the app's storage folder, and read before the
/// first frame - see [loadAppSettings] - so the app never opens in one theme
/// and flips to another.
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.temperatureUnit = TemperatureUnit.celsius,
    this.downloadDefinitions = true,
    this.keepScreenOn = true,
  });

  final ThemeMode themeMode;

  /// The scale definitions are parsed for. See [TemperatureUnit].
  final TemperatureUnit temperatureUnit;

  /// Whether a definition missing from this device is fetched from the
  /// firmware project's website on connecting.
  final bool downloadDefinitions;

  /// Whether the screen is held on while an ECU is connected.
  final bool keepScreenOn;

  AppSettings copyWith({
    ThemeMode? themeMode,
    TemperatureUnit? temperatureUnit,
    bool? downloadDefinitions,
    bool? keepScreenOn,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    temperatureUnit: temperatureUnit ?? this.temperatureUnit,
    downloadDefinitions: downloadDefinitions ?? this.downloadDefinitions,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  Map<String, Object?> toJson() => {
    'theme': themeMode.name,
    'temperature': temperatureUnit.name,
    'downloadDefinitions': downloadDefinitions,
    'keepScreenOn': keepScreenOn,
  };

  /// Reads what [toJson] wrote.
  ///
  /// Anything missing or not understood - from a later version, say, or
  /// edited by hand - keeps its default, one setting at a time, rather than
  /// costing the others.
  static AppSettings fromJson(Object? json) {
    const defaults = AppSettings();
    if (json is! Map) return defaults;
    bool? flag(Object? value) => value is bool ? value : null;
    return AppSettings(
      themeMode:
          ThemeMode.values.asNameMap()[json['theme']] ?? defaults.themeMode,
      temperatureUnit:
          TemperatureUnit.values.asNameMap()[json['temperature']] ??
          defaults.temperatureUnit,
      downloadDefinitions:
          flag(json['downloadDefinitions']) ?? defaults.downloadDefinitions,
      keepScreenOn: flag(json['keepScreenOn']) ?? defaults.keepScreenOn,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.temperatureUnit == temperatureUnit &&
      other.downloadDefinitions == downloadDefinitions &&
      other.keepScreenOn == keepScreenOn;

  @override
  int get hashCode => Object.hash(
    themeMode,
    temperatureUnit,
    downloadDefinitions,
    keepScreenOn,
  );
}

/// The settings the app started with.
///
/// `main` overrides this with what [loadAppSettings] read. Anywhere else - the
/// tests - it is the defaults.
final initialAppSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

/// The app settings in force.
final appSettingsProvider =
    NotifierProvider<AppSettingsController, AppSettings>(
      AppSettingsController.new,
    );

class AppSettingsController extends Notifier<AppSettings> {
  /// Where the settings are kept, under the app's storage folder.
  static const path = 'settings.json';

  @override
  AppSettings build() => ref.read(initialAppSettingsProvider);

  /// Applies [change], and saves the result.
  void update(AppSettings Function(AppSettings current) change) {
    final next = change(state);
    if (next == state) return;
    state = next;
    // Not awaited: the setting has already taken effect, and the store
    // reports its own failures.
    unawaited(ref.read(jsonStoreProvider).write(path, next.toJson()));
  }
}

/// Reads the saved settings, for `main` to start with.
///
/// Never throws: settings that cannot be read are the defaults, not a failed
/// start.
Future<AppSettings> loadAppSettings() async => AppSettings.fromJson(
  await JsonStore(appStorageDirectory).read(AppSettingsController.path),
);

/// Temperature scale the definition is parsed for.
///
/// This selects a branch in the ECU definition, not just a label: the
/// Celsius and Fahrenheit builds compute `coolant` and `iat` with different
/// expressions, so the gauges' ranges and thresholds are derived from the same
/// choice. See [TemperatureUnit].
final temperatureUnitProvider = Provider<TemperatureUnit>(
  (ref) => ref.watch(appSettingsProvider.select((s) => s.temperatureUnit)),
);
