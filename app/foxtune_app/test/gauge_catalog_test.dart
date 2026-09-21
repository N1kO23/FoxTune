import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_catalog.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
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

  group('a limit is a boundary, not part of the alarm', () {
    test('a reading exactly on a limit is not past it', () {
      const spec = GaugeSpec(
        channel: 'x',
        label: 'X',
        units: '',
        min: 0,
        max: 100,
        dangerBelow: 5,
        warnBelow: 10,
        warnAbove: 90,
        dangerAbove: 95,
      );
      expect(spec.statusFor(10), GaugeStatus.normal);
      expect(spec.statusFor(9.9), GaugeStatus.warning);
      expect(spec.statusFor(5), GaugeStatus.warning);
      expect(spec.statusFor(4.9), GaugeStatus.danger);
      expect(spec.statusFor(90), GaugeStatus.normal);
      expect(spec.statusFor(95), GaugeStatus.warning);
      expect(spec.statusFor(95.1), GaugeStatus.danger);
    });

    test('limits the definition puts on the ends of the scale', () {
      final catalog = catalogFor(null);
      GaugeSpec gauge(String name) => catalog.specFor(doc.gaugeNamed(name)!);

      // Advance warns and dangers below 0 degrees: zero itself is fine.
      expect(gauge('advanceGauge').statusFor(0), GaugeStatus.normal);
      expect(gauge('advanceGauge').statusFor(-1), GaugeStatus.danger);
      // Throttle's danger point is 100%: wide open is past the 90% warning,
      // but not in danger.
      expect(gauge('throttleGauge').statusFor(100), GaugeStatus.warning);
    });

    test('things at rest are not too low', () {
      final catalog = catalogFor(null);
      GaugeSpec gauge(String name) => catalog.specFor(doc.gaugeNamed(name)!);

      // Shut, where the definition warns below 1%.
      expect(gauge('throttleGauge').statusFor(0), GaugeStatus.normal);
      // Fuel cut, where it calls anything under 1 ms danger.
      expect(gauge('pulseWidthGauge').statusFor(0), GaugeStatus.normal);
      // Engine stopped.
      expect(gauge('tachometer').statusFor(0), GaugeStatus.normal);

      // Readings sagging towards zero still alarm.
      expect(gauge('throttleGauge').statusFor(0.5), GaugeStatus.warning);
      expect(gauge('pulseWidthGauge').statusFor(0.4), GaugeStatus.danger);
      expect(gauge('tachometer').statusFor(200), GaugeStatus.danger);
      // And the bottom of a scale that does not start at zero is no rest: a
      // coolant sensor reading -40 has usually lost its wire.
      expect(gauge('cltGauge').statusFor(-40), GaugeStatus.danger);
    });
  });

  group('alarm bands that contradict each other', () {
    test('are ignored, so a warm engine is not in danger', () {
      // The definition's warmup gauge: danger below 130%, warning below 140%,
      // warning above 140%. Nothing is normal, and 100% - fully warm - is
      // danger.
      final catalog = catalogFor(TuneState.empty(doc));
      final spec = catalog.specFor(doc.gaugeNamed('warmupEnrichGauge')!);

      expect(spec.statusFor(100), GaugeStatus.normal);
      expect(spec.dangerBelow, isNull);
      expect(spec.dangerAbove, isNull);
      expect(catalog.ignoresDefinedBands('warmupEnrichGauge'), isTrue);
    });

    test('are the eight copies of one line, and free memory', () {
      // Factory values rather than an empty tune: in an empty tune `stoich`
      // is zero, and every AFR band - a multiple of it - collapses to zero.
      final catalog = catalogFor(null);
      final ignored = [
        for (final gauge in doc.gauges)
          if (catalog.ignoresDefinedBands(gauge.name)) gauge.name,
      ];
      expect(
        ignored,
        unorderedEquals([
          'warmupEnrichGauge',
          'aseEnrichGauge',
          'iatCorrectGauge',
          'baroCorrectGauge',
          'flexEnrich',
          'fuelTempCorGauge',
          'mapMultiplyGauge',
          'nSquirtsGauge',
          'memoryGauge',
        ]),
      );
    });

    test('leave sensible bands alone', () {
      final catalog = catalogFor(TuneState.empty(doc));
      final ego = catalog.specFor(doc.gaugeNamed('egoCorrGauge')!);
      expect(ego.warnAbove, 101);
      expect(ego.statusFor(100), GaugeStatus.normal);
      expect(catalog.ignoresDefinedBands('tachometer'), isFalse);
    });
  });

  group('a channel with no gauge', () {
    test('is drawn from its output channel entry', () {
      final catalog = catalogFor(TuneState.empty(doc));
      final spec = catalog.specOf(GaugeRef.channel('rpmDOT'))!;

      expect(spec.label, 'rpmDOT');
      expect(spec.units, 'rpm/s');
      // A signed 16-bit channel can report this much, and nothing says what
      // is normal.
      expect((spec.min, spec.max), (-32768, 32767));
      expect(spec.hasRange, isTrue);
      expect(spec.statusFor(30000), GaugeStatus.normal);
    });

    test('a computed channel admits it has no range', () {
      final spec = catalogFor(TuneState.empty(doc))
          .specOf(GaugeRef.channel('cycleTime'))!;
      expect(spec.hasRange, isFalse);
    });

    test('reads live from its channel', () {
      final channels = doc.outputChannels;
      final block = Uint8List(channels.blockSize!);
      ByteData.sublistView(
        block,
      ).setInt16(channels.channelNamed('rpmDOT')!.offset!, -420, Endian.little);
      final catalog = GaugeCatalog(
        definition: doc,
        realtime: RealtimeDecoder(channels).decode(block),
      );
      expect(catalog.readingOf(GaugeRef.channel('rpmDOT')), -420);
    });

    test('every one the picker offers can be drawn', () {
      final catalog = catalogFor(TuneState.empty(doc));
      final offered = GaugeCatalog.channelsWithoutGauges(doc);
      expect(offered, isNotEmpty);
      for (final channel in offered) {
        if (channel.isFlag) {
          expect(
            catalog.indicatorFor(channel.name),
            isNotNull,
            reason: channel.name,
          );
        } else {
          expect(
            catalog.specOf(GaugeRef.channel(channel.name)),
            isNotNull,
            reason: channel.name,
          );
        }
      }
    });

    test('a status bit the front page already has is not offered twice', () {
      final offered = {
        for (final c in GaugeCatalog.channelsWithoutGauges(doc)) c.name,
      };
      expect(offered, isNot(contains('running')));
      expect(offered, contains('knockActive'));
    });

    test('a status bit shows as a lamp labelled with its name', () {
      final catalog = catalogFor(TuneState.empty(doc));
      final lamp = catalog.indicatorFor('knockActive')!;
      expect(lamp.onLabel, 'knockActive');
      // The front page's own labels win where there are some.
      expect(catalog.indicatorFor('running')!.onLabel, 'Running');
    });
  });

  group('limits the tuner set', () {
    test('replace the definition\'s, bands and all', () {
      final catalog = GaugeCatalog(
        definition: doc,
        resolver: TuneValueResolver(TuneState.empty(doc)),
        limits: const {
          'warmupEnrichGauge': GaugeLimits(
            min: 100,
            max: 200,
            decimals: 0,
            warnAbove: 170,
          ),
        },
      );
      final spec = catalog.specOf('warmupEnrichGauge')!;
      expect(spec.warnAbove, 170);
      expect(spec.statusFor(180), GaugeStatus.warning);
      expect(spec.statusFor(100), GaugeStatus.normal);
      // What the definition says is still there to go back to.
      expect(catalog.definedSpecOf('warmupEnrichGauge')!.warnAbove, isNull);
    });

    test('give a channel a range it did not have', () {
      final catalog = GaugeCatalog(
        definition: doc,
        limits: {
          GaugeRef.channel('cycleTime'): const GaugeLimits(
            min: 0,
            max: 200,
            decimals: 1,
          ),
        },
      );
      final spec = catalog.specOf(GaugeRef.channel('cycleTime'))!;
      expect(spec.hasRange, isTrue);
      expect(spec.max, 200);
    });

    test('are flagged for gauges that follow the tune', () {
      final catalog = catalogFor(null);
      expect(catalog.followsTune('tachometer'), isTrue);
      expect(catalog.followsTune('cltGauge'), isFalse);
    });
  });

  test('indicator colours keep the definition meaning on the palette', () {
    expect(GaugeCatalog.colorFor('red'), StatusPalette.critical);
    expect(GaugeCatalog.colorFor('green'), StatusPalette.good);
    expect(GaugeCatalog.colorFor('yellow'), StatusPalette.warning);
    expect(GaugeCatalog.colorFor('white'), isNull);
  });
}
