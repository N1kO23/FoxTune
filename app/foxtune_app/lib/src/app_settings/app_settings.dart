import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

import '../dashboard/gauge_appearance.dart';
import '../dashboard/gauge_status.dart';
import '../storage/json_store.dart';
import 'map_colours.dart';
import 'wallpaper.dart';

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
    this.downloadDefinitionsFor = downloadable,
    this.keepScreenOn = true,
    this.baudRate = kSpeeduinoBaudRate,
    this.delayAfterOpen = kDelayAfterPortOpen,
    this.liveDataRate = 30,
    this.wallpaper = const Wallpaper(),
    this.mapGradient = foxTuneGradient,
    this.savedGradients = const [],
    this.gaugeAppearance = const GaugeAppearance(),
  });

  /// The firmwares whose projects publish their definitions to download.
  static const downloadable = {EcuFamily.speeduino, EcuFamily.rusefi};

  /// The serial speeds offered: from a Bluetooth module's usual 9600 up.
  /// Speeduino talks at 115200; rusEFI's serial speed is itself a setting.
  static const baudRates = [
    9600,
    19200,
    38400,
    57600,
    115200,
    230400,
    460800,
    921600,
  ];

  /// The waits after opening a serial port that are offered.
  static const delaysAfterOpen = [
    Duration.zero,
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  /// The live data rates offered, in reads a second.
  static const liveDataRates = [10, 15, 20, 30, 50];

  final ThemeMode themeMode;

  /// The scale definitions are parsed for. See [TemperatureUnit].
  final TemperatureUnit temperatureUnit;

  /// The firmwares whose definitions are downloaded, when one missing from
  /// this device is needed on connecting. See [downloadable].
  final Set<EcuFamily> downloadDefinitionsFor;

  /// Whether the screen is held on while an ECU is connected.
  final bool keepScreenOn;

  /// The speed a serial port is opened at. Means nothing to a network bridge,
  /// which sets its own.
  final int baudRate;

  /// How long a serial port is left to settle after opening, for a board that
  /// restarts as it opens. See [kDelayAfterPortOpen].
  final Duration delayAfterOpen;

  /// How many times a second live data is read, at most. A slow link manages
  /// what it can.
  final int liveDataRate;

  /// What is drawn behind the main screen.
  final Wallpaper wallpaper;

  /// How the table maps, and the 3D surfaces drawn from them, are coloured.
  final MapGradient mapGradient;

  /// Gradients the user has saved, beside the [builtInGradients].
  final List<MapGradient> savedGradients;

  /// How the dashboard's gauges look, unless one has been given its own.
  /// Anything left unset here is drawn as [GaugeAppearance.builtIn].
  final GaugeAppearance gaugeAppearance;

  /// The time between live data reads [liveDataRate] asks for.
  Duration get liveDataInterval =>
      Duration(microseconds: Duration.microsecondsPerSecond ~/ liveDataRate);

  AppSettings copyWith({
    ThemeMode? themeMode,
    TemperatureUnit? temperatureUnit,
    Set<EcuFamily>? downloadDefinitionsFor,
    bool? keepScreenOn,
    int? baudRate,
    Duration? delayAfterOpen,
    int? liveDataRate,
    Wallpaper? wallpaper,
    MapGradient? mapGradient,
    List<MapGradient>? savedGradients,
    GaugeAppearance? gaugeAppearance,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    temperatureUnit: temperatureUnit ?? this.temperatureUnit,
    downloadDefinitionsFor:
        downloadDefinitionsFor ?? this.downloadDefinitionsFor,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
    baudRate: baudRate ?? this.baudRate,
    delayAfterOpen: delayAfterOpen ?? this.delayAfterOpen,
    liveDataRate: liveDataRate ?? this.liveDataRate,
    wallpaper: wallpaper ?? this.wallpaper,
    mapGradient: mapGradient ?? this.mapGradient,
    savedGradients: savedGradients ?? this.savedGradients,
    gaugeAppearance: gaugeAppearance ?? this.gaugeAppearance,
  );

  /// These settings, with definitions for [family] downloaded or not.
  AppSettings withDownloadsFor(EcuFamily family, {required bool on}) =>
      copyWith(
        downloadDefinitionsFor: on
            ? {...downloadDefinitionsFor, family}
            : downloadDefinitionsFor.difference({family}),
      );

  Map<String, Object?> toJson() => {
    'theme': themeMode.name,
    'temperature': temperatureUnit.name,
    'downloadDefinitions': {
      for (final family in downloadable)
        family.name: downloadDefinitionsFor.contains(family),
    },
    'keepScreenOn': keepScreenOn,
    'baudRate': baudRate,
    'delayAfterOpenMs': delayAfterOpen.inMilliseconds,
    'liveDataRate': liveDataRate,
    'wallpaper': wallpaper.toJson(),
    'mapGradient': mapGradient.toJson(),
    'savedGradients': [for (final saved in savedGradients) saved.toJson()],
    'gaugeAppearance': gaugeAppearance.toJson(),
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
    int? within(Object? value, int low, int high) =>
        value is int && value >= low && value <= high ? value : null;
    final delayMs = within(json['delayAfterOpenMs'], 0, 10000);
    return AppSettings(
      themeMode:
          ThemeMode.values.asNameMap()[json['theme']] ?? defaults.themeMode,
      temperatureUnit:
          TemperatureUnit.values.asNameMap()[json['temperature']] ??
          defaults.temperatureUnit,
      downloadDefinitionsFor: switch (json['downloadDefinitions']) {
        // Saved before each firmware had its own: one for all of them.
        final bool all => all ? downloadable : const {},
        final Map<Object?, Object?> each => {
          for (final family in downloadable)
            if (flag(each[family.name]) ??
                defaults.downloadDefinitionsFor.contains(family))
              family,
        },
        _ => defaults.downloadDefinitionsFor,
      },
      keepScreenOn: flag(json['keepScreenOn']) ?? defaults.keepScreenOn,
      baudRate: within(json['baudRate'], 300, 4000000) ?? defaults.baudRate,
      delayAfterOpen: delayMs == null
          ? defaults.delayAfterOpen
          : Duration(milliseconds: delayMs),
      liveDataRate:
          within(json['liveDataRate'], 1, 100) ?? defaults.liveDataRate,
      wallpaper: json.containsKey('wallpaper')
          ? Wallpaper.fromJson(json['wallpaper'])
          : defaults.wallpaper,
      mapGradient:
          MapGradient.fromJson(json['mapGradient']) ?? defaults.mapGradient,
      savedGradients: switch (json['savedGradients']) {
        // One that does not read is dropped, not the rest with it.
        final List<Object?> saved => [
          for (final gradient in saved) ?MapGradient.fromJson(gradient),
        ],
        _ => defaults.savedGradients,
      },
      gaugeAppearance: GaugeAppearance.fromJson(json['gaugeAppearance']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.temperatureUnit == temperatureUnit &&
      setEquals(other.downloadDefinitionsFor, downloadDefinitionsFor) &&
      other.keepScreenOn == keepScreenOn &&
      other.baudRate == baudRate &&
      other.delayAfterOpen == delayAfterOpen &&
      other.liveDataRate == liveDataRate &&
      other.wallpaper == wallpaper &&
      other.mapGradient == mapGradient &&
      listEquals(other.savedGradients, savedGradients) &&
      other.gaugeAppearance == gaugeAppearance;

  @override
  int get hashCode => Object.hash(
    themeMode,
    temperatureUnit,
    Object.hashAllUnordered(downloadDefinitionsFor),
    keepScreenOn,
    baudRate,
    delayAfterOpen,
    liveDataRate,
    wallpaper,
    mapGradient,
    Object.hashAll(savedGradients),
    gaugeAppearance,
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
