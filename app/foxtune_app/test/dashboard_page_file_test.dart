import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_appearance.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';
import 'package:foxtune_app/src/dashboard/layout/grid.dart';
import 'package:foxtune_app/src/dashboard/layout/page_file.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

const _dwellLimits = GaugeLimits(min: 0, max: 10, decimals: 1, warnAbove: 8);
const _rpmLimits = GaugeLimits(
  min: 0,
  max: 8000,
  decimals: 0,
  dangerAbove: 7000,
);

/// A Speeduino page. Of what it shows, rusEFI's definition has the dwell and
/// TPS gauges and nothing else.
const _page = DashboardPage(
  id: 'p1',
  name: 'Driving',
  density: 36,
  width: PageWidth.tablet,
  items: [
    GaugePlacement(
      id: 'rpm',
      style: GaugeStyle.dial,
      x: 0,
      y: 0,
      width: 12,
      height: 12,
      gauges: ['tachometer'],
    ),
    GaugePlacement(
      id: 'dwell',
      style: GaugeStyle.digital,
      x: 12,
      y: 0,
      width: 9,
      height: 6,
      gauges: ['dwellGauge'],
      appearance: GaugeAppearance(
        readout: ReadoutLook(framed: false),
        colours: GaugeColours(normal: Color(0xFF00AAFF)),
      ),
    ),
    GaugePlacement(
      id: 'graph',
      style: GaugeStyle.graph,
      x: 0,
      y: 12,
      width: 18,
      height: 9,
      gauges: ['tpsADCGauge', 'channel:rpmDOT'],
      windowSeconds: 60,
    ),
    GaugePlacement(
      id: 'lamp',
      style: GaugeStyle.lamp,
      x: 21,
      y: 0,
      width: 9,
      height: 3,
      indicator: 'running',
    ),
  ],
);

void main() {
  late IniDocument speeduino;
  late IniDocument rusefi;

  setUpAll(() {
    speeduino = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
    rusefi = IniParser().parse(
      File('../../packages/foxtune_ini/test/fixtures/rusefi_uaefi.ini')
          .readAsStringSync(),
    );
  });

  DashboardPageFile exported() => DashboardPageFile.of(
    _page,
    const DashboardLayout(
      pages: [_page],
      limits: {
        'tachometer': _rpmLimits,
        'dwellGauge': _dwellLimits,
        // On another page only.
        'cltGauge': GaugeLimits(min: -40, max: 120, decimals: 0),
      },
    ),
    speeduino,
  );

  DashboardPageFile roundTrip() =>
      DashboardPageFile.decode(exported().encode());

  group('exporting', () {
    test('takes the limits of the gauges on the page, and no others', () {
      expect(
        exported().limits.keys,
        unorderedEquals(['tachometer', 'dwellGauge']),
      );
    });

    test('names the ECU it was made on', () {
      final json = jsonDecode(exported().encode()) as Map;
      expect(json['ecu'], speeduino.identity.signature);
      expect(json['version'], DashboardLayout.formatVersion);
    });
  });

  group('importing on the same ECU', () {
    test('brings back the whole page, as it was', () {
      final file = roundTrip();
      expect(file.isFor(speeduino), isTrue);

      final fitted = file.fitTo(speeduino);
      expect(fitted.missing, isEmpty);
      expect(fitted.limits, hasLength(2));
      expect(fitted.limits['tachometer']!.dangerAbove, 7000);

      final page = fitted.page;
      expect(page.name, 'Driving');
      expect(page.density, 36);
      expect(page.width, PageWidth.tablet);
      expect(page.items, hasLength(4));

      final dwell = page.items[1];
      expect(dwell.gauges, ['dwellGauge']);
      expect((dwell.x, dwell.y, dwell.width, dwell.height), (12, 0, 9, 6));
      expect(dwell.appearance.readout.framed, isFalse);
      expect(dwell.appearance.colours.normal, const Color(0xFF00AAFF));

      final graph = page.items[2];
      expect(graph.gauges, ['tpsADCGauge', 'channel:rpmDOT']);
      expect(graph.windowSeconds, 60);
      expect(page.items[3].indicator, 'running');
    });

    test('gives the page and its gauges identities of their own', () {
      final page = roundTrip().fitTo(speeduino).page;
      expect(page.id, isNot('p1'));
      expect(
        page.items.map((i) => i.id),
        isNot(anyElement(isIn(['rpm', 'dwell', 'graph', 'lamp']))),
      );
      // So the same file imported twice is two pages, not one twice.
      expect(roundTrip().fitTo(speeduino).page.id, isNot(page.id));
    });
  });

  group('importing on another ECU', () {
    test('leaves out what its definition does not have', () {
      final file = roundTrip();
      expect(file.isFor(rusefi), isFalse);

      final fitted = file.fitTo(rusefi);
      expect(fitted.missing, ['tachometer', 'rpmDOT', 'running']);
      expect(fitted.page.items.map((i) => i.style), [
        GaugeStyle.digital,
        GaugeStyle.graph,
      ]);
    });

    test('keeps the lanes of a graph it has, and drops the rest', () {
      final graph = roundTrip().fitTo(rusefi).page.items.last;
      expect(graph.gauges, ['tpsADCGauge']);
    });

    test('brings limits only for gauges it keeps', () {
      expect(roundTrip().fitTo(rusefi).limits.keys, ['dwellGauge']);
    });

    test('with nothing it has, leaves an empty page', () {
      const file = DashboardPageFile(
        page: DashboardPage(
          id: 'p',
          name: 'Nothing',
          items: [
            GaugePlacement(
              id: 'a',
              style: GaugeStyle.dial,
              x: 0,
              y: 0,
              width: 8,
              height: 8,
              gauges: ['tachometer'],
            ),
          ],
        ),
      );
      final fitted = file.fitTo(rusefi);
      expect(fitted.page.items, isEmpty);
      expect(fitted.missing, ['tachometer']);
    });
  });

  group('reading a file', () {
    test('refuses one that is not a dashboard page', () {
      for (final text in [
        'not json',
        '[]',
        jsonEncode({'version': 4, 'pages': []}),
        jsonEncode({'kind': 'foxtune-dashboard-page'}),
      ]) {
        expect(
          () => DashboardPageFile.decode(text),
          throwsA(isA<PageFileException>()),
          reason: text,
        );
      }
    });

    test('drops a limit that makes no sense, not the page', () {
      final json = jsonDecode(exported().encode()) as Map<String, Object?>;
      (json['limits']! as Map)['dwellGauge'] = {
        'min': 10,
        'max': 0,
        'decimals': 1,
      };
      final file = DashboardPageFile.decode(jsonEncode(json));
      expect(file.limits.keys, ['tachometer']);
      expect(file.page.items, hasLength(4));
    });

    test('puts gauges edited on top of each other back on the grid', () {
      final json = jsonDecode(exported().encode()) as Map<String, Object?>;
      final items = (json['page']! as Map)['items'] as List;
      // The dwell readout moved onto the dial, and the lamp off the right of
      // a page 72 across.
      (items[1] as Map)
        ..['x'] = 4
        ..['y'] = 2;
      (items[3] as Map)['x'] = 70;
      final page = DashboardPageFile.decode(jsonEncode(json))
          .fitTo(speeduino)
          .page;

      for (final item in page.items) {
        final rect = GridRect.of(item);
        expect(rect.right, lessThanOrEqualTo(page.columns));
        expect(
          isFree(page, rect, ignoring: item.id),
          isTrue,
          reason: item.gauges.join(),
        );
      }
    });
  });
}
