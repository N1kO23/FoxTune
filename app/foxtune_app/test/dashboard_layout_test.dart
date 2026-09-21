import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
        pages: [
          DashboardPage(
            id: 'p1',
            name: 'Driving',
            items: [
              GaugePlacement(
                id: 'a',
                style: GaugeStyle.graph,
                x: 0,
                y: 0,
                width: 6,
                height: 3,
                gauges: ['tachometer', 'afrGauge'],
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
      final graph = page.items.first;
      expect(graph.style, GaugeStyle.graph);
      expect(graph.gauges, ['tachometer', 'afrGauge']);
      expect(graph.windowSeconds, 60);
      expect(page.items.last.indicator, 'running');
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
    const page = DashboardPage(id: 'p', name: 'P', items: []);

    test('keeps a gauge on the grid and no smaller than its style', () {
      expect(
        clampToGrid(const GridRect(10, -2, 4, 1), GaugeStyle.dial),
        const GridRect(8, 0, 4, 3),
      );
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
      final items = defaultPage(doc).items;
      for (final item in items) {
        expect(item.x + item.width, lessThanOrEqualTo(gridColumns));
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
