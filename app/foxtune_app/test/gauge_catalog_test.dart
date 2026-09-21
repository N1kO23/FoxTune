import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_catalog.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

void main() {
  late IniDocument doc;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  GaugeCatalog catalogFor(TuneState? tune) => GaugeCatalog(
    definition: doc,
    resolver: tune == null ? null : TuneValueResolver(tune),
  );

  group('the tachometer follows Gauge Limits', () {
    test('uses what the tuner set', () {
      final tune = TuneState.empty(doc);
      SettingView.of(tune, 'rpmhigh')!.setValue(9000);
      SettingView.of(tune, 'rpmwarn')!.setValue(6500);
      SettingView.of(tune, 'rpmdang')!.setValue(7200);

      final spec = catalogFor(tune).specFor(doc.gaugeNamed('tachometer')!);

      expect(spec.max, 9000);
      expect(spec.warnAbove, 6500);
      expect(spec.dangerAbove, 7200);
      expect(spec.statusFor(6400), GaugeStatus.normal);
      expect(spec.statusFor(6600), GaugeStatus.warning);
      expect(spec.statusFor(7300), GaugeStatus.danger);
    });

    test('falls back to the factory values before a tune is loaded', () {
      final spec = catalogFor(null).specFor(doc.gaugeNamed('tachometer')!);

      expect(spec.max, doc.defaultValues['rpmhigh']!.first);
      expect(spec.warnAbove, doc.defaultValues['rpmwarn']!.first);
      expect(spec.dangerAbove, doc.defaultValues['rpmdang']!.first);
    });
  });

  test('every gauge in the definition resolves to a usable scale', () {
    final catalog = catalogFor(TuneState.empty(doc));
    for (final gauge in doc.gauges) {
      final spec = catalog.specFor(gauge);
      expect(spec.max, greaterThan(spec.min), reason: gauge.name);
      expect(spec.label, isNotEmpty, reason: gauge.name);
    }
  });

  test('a computed title falls back to the gauge name', () {
    // Aux input titles are text aliases, which FoxTune does not model.
    final spec = catalogFor(TuneState.empty(doc))
        .specFor(doc.gaugeNamed('AuxInGauge0')!);
    expect(spec.label, 'AuxInGauge0');
  });

  test('indicator colours keep the definition meaning on the palette', () {
    expect(GaugeCatalog.colorFor('red'), StatusPalette.critical);
    expect(GaugeCatalog.colorFor('green'), StatusPalette.good);
    expect(GaugeCatalog.colorFor('yellow'), StatusPalette.warning);
    expect(GaugeCatalog.colorFor('white'), isNull);
  });
}
