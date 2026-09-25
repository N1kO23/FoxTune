import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';
import 'package:foxtune_app/src/dashboard/layout/default_layout.dart';
import 'package:foxtune_app/src/dashboard/layout/grid.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

GaugePlacement _at(
  String id,
  int x,
  int y,
  int w,
  int h, {
  GaugeStyle style = GaugeStyle.digital,
}) => GaugePlacement(id: id, style: style, x: x, y: y, width: w, height: h);

void main() {
  late IniDocument doc;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  group('saving', () {
    test('a layout survives a round trip through JSON', () {
      const layout = DashboardLayout(
        limits: {
          'channel:rpmDOT': GaugeLimits(
            min: -3000,
            max: 3000,
            decimals: 0,
            dangerAbove: 2500,
          ),
        },
        pages: [
          DashboardPage(
            id: 'p1',
            name: 'Driving',
            density: 36,
            width: PageWidth.laptop,
            items: [
              GaugePlacement(
                id: 'a',
                style: GaugeStyle.graph,
                x: 0,
                y: 0,
                width: 6,
                height: 3,
                gauges: ['tachometer', 'channel:rpmDOT'],
                windowSeconds: 60,
              ),
              GaugePlacement(
                id: 'b',
                style: GaugeStyle.lamp,
                x: 6,
                y: 0,
                width: 3,
                height: 1,
                indicator: 'running',
              ),
            ],
          ),
        ],
      );

      final restored = DashboardLayout.fromJson(
        jsonDecode(jsonEncode(layout.toJson())),
      )!;

      final page = restored.pages.single;
      expect(page.name, 'Driving');
      expect(page.density, 36);
      expect(page.width, PageWidth.laptop);
      expect(page.columns, 108);
      final graph = page.items.first;
      expect(graph.style, GaugeStyle.graph);
      expect(graph.gauges, ['tachometer', 'channel:rpmDOT']);
      expect(graph.windowSeconds, 60);
      expect(page.items.last.indicator, 'running');

      final limits = restored.limits['channel:rpmDOT']!;
      expect((limits.min, limits.max), (-3000, 3000));
      expect(limits.dangerAbove, 2500);
      expect(limits.warnAbove, isNull);
    });

    test('a page saved before grids could change size keeps its look', () {
      // Version 1 pages were all twelve across; doubled onto the finer
      // default grid, every edge lands where it was.
      final page = DashboardLayout.fromJson({
        'version': 1,
        'pages': [
          {
            'id': 'p',
            'name': 'Main',
            'items': [
              {'id': 'd', 'style': 'dial', 'x': 4, 'y': 1, 'w': 4, 'h': 4},
            ],
          },
        ],
      })!.pages.single;

      expect(page.density, 24);
      expect(page.width, PageWidth.phone);
      final dial = page.items.single;
      expect((dial.x, dial.y, dial.width, dial.height), (8, 2, 8, 8));
    });

    test('a page saved when every page was a phone wide keeps its grid', () {
      // Version 2 called the density "columns", when the two were the same.
      final page = DashboardLayout.fromJson({
        'version': 2,
        'pages': [
          {'id': 'p', 'name': 'Main', 'columns': 48, 'items': []},
        ],
      })!.pages.single;
      expect(page.density, 48);
      expect(page.width, PageWidth.phone);
    });

    test('limits that make no sense are not loaded', () {
      final layout = DashboardLayout.fromJson({
        'pages': [
          {'id': 'p', 'name': 'Main', 'columns': 24, 'items': []},
        ],
        'limits': {
          'afrGauge': {'min': 20, 'max': 10, 'decimals': 1},
          'cltGauge': {'min': -40, 'max': 120, 'decimals': 0},
        },
      })!;
      expect(layout.limits.keys, ['cltGauge']);
    });

    test('a damaged file is not mistaken for a layout', () {
      expect(DashboardLayout.fromJson('nonsense'), isNull);
      expect(DashboardLayout.fromJson({'pages': []}), isNull);
    });

    test('a damaged gauge is dropped, not the page around it', () {
      final layout = DashboardLayout.fromJson({
        'pages': [
          {
            'id': 'p',
            'name': 'Main',
            'items': [
              {'id': 'ok', 'style': 'dial', 'x': 0, 'y': 0, 'w': 4, 'h': 4},
              {'id': 'broken', 'x': 'left'},
            ],
          },
        ],
      })!;
      expect(layout.pages.single.items.map((i) => i.id), ['ok']);
    });

    test('a firmware update keeps the same layout file', () {
      expect(ecuFamily('speeduino 202504-dev'), 'speeduino');
      expect(ecuFamily('speeduino 202501'), 'speeduino');
      expect(ecuFamily('rusEFI master.2026'), 'rusefi');
      expect(ecuFamily(null), 'unknown');
    });
  });

  group('placing', () {
    const page = DashboardPage(id: 'p', name: 'P', density: 12, items: []);

    test('keeps a gauge on the grid and no smaller than its style', () {
      expect(
        clampToGrid(const GridRect(10, -2, 4, 1), GaugeStyle.dial, page),
        const GridRect(8, 0, 4, 3),
      );
      // The same dial on a grid twice as fine: the same size on the page.
      expect(
        clampToGrid(
          const GridRect(22, -2, 4, 1),
          GaugeStyle.dial,
          page.copyWith(density: 24),
        ),
        const GridRect(18, 0, 6, 6),
      );
      // And on a page three phones wide, with that much more room.
      expect(
        clampToGrid(
          const GridRect(40, 0, 4, 4),
          GaugeStyle.dial,
          page.copyWith(width: PageWidth.laptop),
        ),
        const GridRect(32, 0, 4, 4),
      );
    });

    test('a style is the same size on the page whatever the grid', () {
      for (final style in GaugeStyle.values) {
        final coarse = style.sizeIn(12);
        final fine = style.sizeIn(24);
        expect(fine.width, coarse.width * 2, reason: style.name);
        expect(fine.height, coarse.height * 2, reason: style.name);
      }
      // What a twelve-across page always used.
      expect(GaugeStyle.dial.sizeIn(12), (width: 4, height: 4));
      expect(GaugeStyle.lamp.minimumIn(12), (width: 2, height: 1));
      // A finer grid lets a lamp be thinner than a coarse one could.
      expect(GaugeStyle.lamp.minimumIn(24), (width: 3, height: 1));
    });

    test('refuses to put one gauge on top of another', () {
      final existing = _at('a', 0, 0, 4, 2);
      final moving = _at('b', 6, 0, 3, 2);
      final withBoth = page.copyWith(items: [existing, moving]);

      expect(tryPlace(withBoth, moving, const GridRect(2, 1, 3, 2)), isNull);
      final moved = tryPlace(withBoth, moving, const GridRect(4, 1, 3, 2))!;
      expect((moved.x, moved.y), (4, 1));
    });

    test('a gauge may be moved over where it already is', () {
      final item = _at('a', 0, 0, 4, 2);
      final moved = tryPlace(
        page.copyWith(items: [item]),
        item,
        const GridRect(1, 0, 4, 2),
      );
      expect(moved?.x, 1);
    });

    test('finds the first clear spot, left to right then down', () {
      final full = page.copyWith(
        items: [_at('a', 0, 0, 6, 2), _at('b', 6, 0, 6, 1)],
      );

      expect(firstFreeSpot(full, 3, 1), const GridRect(6, 1, 3, 1));
      expect(firstFreeSpot(full, 12, 1), const GridRect(0, 2, 12, 1));
    });
  });

  group('changing the grid', () {
    const coarse = DashboardPage(
      id: 'p',
      name: 'P',
      density: 12,
      items: [
        GaugePlacement(
          id: 'a',
          style: GaugeStyle.digital,
          x: 0,
          y: 0,
          width: 3,
          height: 2,
        ),
        GaugePlacement(
          id: 'b',
          style: GaugeStyle.digital,
          x: 3,
          y: 0,
          width: 3,
          height: 2,
        ),
      ],
    );

    test('a finer grid keeps every edge', () {
      final fine = regridPage(coarse, 24);
      expect(fine.columns, 24);
      expect(fine.items.map(GridRect.of), const [
        GridRect(0, 0, 6, 4),
        GridRect(6, 0, 6, 4),
      ]);
    });

    test('a coarser grid keeps neighbours touching, never overlapping', () {
      // 36 across to 24: edges at 0, 5 and 10 scale to 0, 3.33 and 6.67.
      // Rounded edge by edge, the two still meet at 3.
      const page = DashboardPage(
        id: 'p',
        name: 'P',
        density: 36,
        items: [
          GaugePlacement(
            id: 'a',
            style: GaugeStyle.lamp,
            x: 0,
            y: 0,
            width: 5,
            height: 3,
          ),
          GaugePlacement(
            id: 'b',
            style: GaugeStyle.lamp,
            x: 5,
            y: 0,
            width: 5,
            height: 3,
          ),
        ],
      );
      final rescaled = regridPage(page, 24);
      final a = GridRect.of(rescaled.items[0]);
      final b = GridRect.of(rescaled.items[1]);
      expect(a.right, b.x);
      expect(a.overlaps(b), isFalse);
    });

    test('gauges that land on the same cells on a coarser grid do not '
        'overlap', () {
      // Two thin lamps stacked on rows 1 and 2 of a 24 grid both fall on row 1
      // of a 12 grid, where a row is twice as tall. The second gives way.
      const page = DashboardPage(
        id: 'p',
        name: 'P',
        density: 24,
        items: [
          GaugePlacement(
            id: 'upper',
            style: GaugeStyle.lamp,
            x: 0,
            y: 1,
            width: 6,
            height: 1,
          ),
          GaugePlacement(
            id: 'lower',
            style: GaugeStyle.lamp,
            x: 0,
            y: 2,
            width: 6,
            height: 1,
          ),
        ],
      );
      final rescaled = regridPage(page, 12);
      final upper = GridRect.of(rescaled.items[0]);
      final lower = GridRect.of(rescaled.items[1]);

      expect(upper, const GridRect(0, 1, 3, 1));
      expect(upper.overlaps(lower), isFalse);
      expect(lower.width, 3);
      // Still in the order they were saved in.
      expect(rescaled.items.map((i) => i.id), ['upper', 'lower']);
    });
  });

  group('changing the width', () {
    const phone = DashboardPage(
      id: 'p',
      name: 'P',
      density: 12,
      items: [
        GaugePlacement(
          id: 'left',
          style: GaugeStyle.digital,
          x: 0,
          y: 0,
          width: 3,
          height: 2,
        ),
        GaugePlacement(
          id: 'right',
          style: GaugeStyle.digital,
          x: 9,
          y: 0,
          width: 3,
          height: 2,
        ),
      ],
    );

    test('a wider page keeps every gauge as it was, with room beside', () {
      final wide = widenPage(phone, PageWidth.tablet);
      expect(wide.columns, 24);
      expect(wide.designCell, phone.designCell);
      expect(wide.items.map(GridRect.of), phone.items.map(GridRect.of));
    });

    test('a narrower page pulls back what no longer fits', () {
      final wide = phone.copyWith(
        width: PageWidth.tablet,
        items: [
          ...phone.items,
          const GaugePlacement(
            id: 'far',
            style: GaugeStyle.digital,
            x: 18,
            y: 0,
            width: 3,
            height: 2,
          ),
        ],
      );
      final narrow = widenPage(wide, PageWidth.phone);
      final rects = {
        for (final item in narrow.items) item.id: GridRect.of(item),
      };

      // What fitted stays put.
      expect(rects['left'], const GridRect(0, 0, 3, 2));
      expect(rects['right'], const GridRect(9, 0, 3, 2));
      // The gauge off the edge comes back to it, where "right" is, so it
      // finds the first clear space instead.
      expect(rects['far'], const GridRect(3, 0, 3, 2));
      for (final rect in rects.values) {
        expect(rect.right, lessThanOrEqualTo(12));
      }
    });

    test('the default page fills a wide page from the left', () {
      final page = defaultPage(doc, width: PageWidth.laptop);
      expect(page.columns, 72);
      // Three phones' worth of room: all eight dials fit in the top row.
      final dials = page.items.where((i) => i.style == GaugeStyle.dial);
      expect(dials.every((d) => d.y == 0), isTrue);
    });
  });

  group('gauge limits', () {
    test('remember the temperature scale they were set in', () {
      const limits = GaugeLimits(
        min: -40,
        max: 248,
        decimals: 0,
        dangerAbove: 221,
        temperatureUnit: TemperatureUnit.fahrenheit,
      );
      expect(
        GaugeLimits.fromJson(limits.toJson())!.temperatureUnit,
        TemperatureUnit.fahrenheit,
      );
      // Anything else has none, and older layouts said nothing about it.
      const plain = GaugeLimits(min: 0, max: 100, decimals: 0);
      expect(plain.toJson(), isNot(contains('temperature')));
      expect(GaugeLimits.fromJson(plain.toJson())!.temperatureUnit, isNull);
    });

    test('accepts ordered bands, with any of them off', () {
      const limits = GaugeLimits(
        min: 0,
        max: 100,
        decimals: 0,
        warnBelow: 10,
        warnAbove: 90,
      );
      expect(limits.problem, isNull);
    });

    test('refuses a range upside down, or bands no reading could pass', () {
      expect(
        const GaugeLimits(min: 10, max: 0, decimals: 0).problem,
        isNotNull,
      );
      expect(
        const GaugeLimits(
          min: 0,
          max: 200,
          decimals: 0,
          dangerBelow: 130,
          warnBelow: 140,
          warnAbove: 140,
          dangerAbove: 150,
        ).problem,
        contains('normal reading'),
      );
      expect(
        const GaugeLimits(
          min: 0,
          max: 100,
          decimals: 0,
          warnAbove: 80,
          dangerAbove: 70,
        ).problem,
        isNotNull,
      );
    });
  });

  group('the default page', () {
    test('starts from the definition\'s own front page', () {
      final page = defaultPage(doc);

      final dials = page.items.where((i) => i.style == GaugeStyle.dial);
      expect(dials.map((i) => i.gauges.single), doc.frontPage.gauges);

      final lamps = page.items.where((i) => i.style == GaugeStyle.lamp);
      expect(lamps.first.indicator, doc.frontPage.indicators.first.expression);
      expect(lamps, hasLength(12));
    });

    test('adds the AFR the front page leaves out', () {
      final page = defaultPage(doc);
      final readouts = page.items
          .where((i) => i.style == GaugeStyle.digital)
          .map((i) => doc.gaugeNamed(i.gauges.single)!.channel);

      expect(readouts, contains('afr'));
      expect(readouts, contains('batteryVoltage'));
    });

    test('nothing overlaps, and everything is on the grid', () {
      final page = defaultPage(doc);
      final items = page.items;
      for (final item in items) {
        expect(item.x + item.width, lessThanOrEqualTo(page.columns));
        for (final other in items) {
          if (identical(item, other)) continue;
          expect(
            GridRect.of(item).overlaps(GridRect.of(other)),
            isFalse,
            reason: '${item.gauges} vs ${other.gauges}',
          );
        }
      }
    });
  });
}
