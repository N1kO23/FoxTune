import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/dashboard/gauge_appearance.dart';
import 'package:foxtune_app/src/dashboard/gauge_status.dart';
import 'package:foxtune_app/src/dashboard/layout/dashboard_layout.dart';

GaugeAppearance _roundTrip(GaugeAppearance look) =>
    GaugeAppearance.fromJson(jsonDecode(jsonEncode(look.toJson())));

void main() {
  const everything = GaugeAppearance(
    dial: DialLook(
      face: DialFace.needle,
      sweep: 240,
      thickness: Thickness.bold,
      scale: ScaleMarks.numbers,
      alarms: AlarmMarks.bands,
    ),
    bar: BarLook(
      orientation: BarOrientation.vertical,
      thickness: Thickness.thin,
      segmented: true,
      alarms: AlarmMarks.ticks,
    ),
    readout: ReadoutLook(
      framed: false,
      magnitudeBar: false,
      valueSize: ValueSize.large,
    ),
    graph: GraphLook(
      thickness: Thickness.bold,
      fill: true,
      alarms: AlarmMarks.bands,
    ),
    lamp: LampLook(shape: LampShape.square, onColour: Color(0xFF1E88E5)),
    colours: GaugeColours(
      normal: Color(0xFFFB8C00),
      warning: Color(0xFFFDD835),
      danger: Color(0xFF8E24AA),
      track: Color(0x33808080),
      background: Color(0xFF000000),
      text: Color(0xFFFFFFFF),
    ),
  );

  group('saving', () {
    test('every setting survives a round trip through JSON', () {
      expect(_roundTrip(everything), everything);
    });

    test('a look that changes nothing writes nothing', () {
      expect(const GaugeAppearance().toJson(), isEmpty);
      expect(const GaugeAppearance().isEmpty, isTrue);
      expect(const GaugeAppearance(dial: DialLook(sweep: 180)).toJson(), {
        'dial': {'sweep': 180},
      });
    });

    test('a setting it cannot read follows the default, alone', () {
      final read = GaugeAppearance.fromJson({
        'dial': {'face': 'hologram', 'sweep': 90, 'scale': 'numbers'},
        'bar': {'segmented': 'yes', 'orientation': 'vertical'},
        'colours': {'normal': 'orange', 'danger': '#8E24AA'},
        'lamp': 'square',
      });
      expect(
        read,
        const GaugeAppearance(
          dial: DialLook(scale: ScaleMarks.numbers),
          bar: BarLook(orientation: BarOrientation.vertical),
          colours: GaugeColours(danger: Color(0xFF8E24AA)),
        ),
      );
      expect(GaugeAppearance.fromJson('nonsense'), const GaugeAppearance());
    });

    test('app settings keep the default look for gauges', () {
      const settings = AppSettings(gaugeAppearance: everything);
      expect(
        AppSettings.fromJson(jsonDecode(jsonEncode(settings.toJson()))),
        settings,
      );
      expect(
        AppSettings.fromJson({'gaugeAppearance': 42}).gaugeAppearance,
        const GaugeAppearance(),
      );
    });

    test("a gauge's own look is kept with it on the page", () {
      const placement = GaugePlacement(
        id: 'g',
        style: GaugeStyle.dial,
        x: 0,
        y: 0,
        width: 8,
        height: 8,
        gauges: ['tachometer'],
        appearance: GaugeAppearance(dial: DialLook(face: DialFace.needle)),
      );
      final layout = DashboardLayout(
        pages: [
          const DashboardPage(id: 'p', name: 'Main', items: [placement]),
        ],
      );
      final restored = DashboardLayout.fromJson(
        jsonDecode(jsonEncode(layout.toJson())),
      )!;
      expect(
        restored.pages.single.items.single.appearance,
        placement.appearance,
      );
    });

    test('a gauge that follows the default writes no look of its own', () {
      const placement = GaugePlacement(
        id: 'g',
        style: GaugeStyle.bar,
        x: 0,
        y: 0,
        width: 8,
        height: 2,
      );
      expect(placement.toJson().containsKey('look'), isFalse);
    });

    test('a page saved before gauges had looks follows the default', () {
      final item = DashboardLayout.fromJson({
        'version': 3,
        'pages': [
          {
            'id': 'p',
            'name': 'Main',
            'density': 24,
            'items': [
              {'id': 'd', 'style': 'dial', 'x': 0, 'y': 0, 'w': 8, 'h': 8},
            ],
          },
        ],
      })!.pages.single.items.single;
      expect(item.appearance.isEmpty, isTrue);
    });
  });

  group('layers', () {
    test('the built-in look is how gauges have always been drawn', () {
      const look = GaugeAppearance.builtIn;
      expect(look.dial.resolved, (
        face: DialFace.arc,
        sweep: 270,
        thickness: Thickness.regular,
        scale: ScaleMarks.none,
        alarms: AlarmMarks.ticks,
      ));
      expect(look.bar.resolved, (
        orientation: BarOrientation.auto,
        thickness: Thickness.regular,
        segmented: false,
        alarms: AlarmMarks.none,
      ));
      expect(look.readout.resolved, (
        framed: true,
        magnitudeBar: true,
        valueSize: ValueSize.regular,
      ));
      expect(look.graph.resolved, (
        thickness: Thickness.regular,
        fill: false,
        alarms: AlarmMarks.none,
      ));
      expect(look.lamp.resolved, (shape: LampShape.pill, onColour: null));
      expect(look.colours, const GaugeColours());
    });

    test("a gauge's own setting wins; the rest follow the default", () {
      const global = GaugeAppearance(
        dial: DialLook(face: DialFace.needle, sweep: 240),
        colours: GaugeColours(normal: Color(0xFFFB8C00)),
      );
      const own = GaugeAppearance(dial: DialLook(sweep: 180));

      final shown = own.over(global).over(GaugeAppearance.builtIn);
      expect(shown.dial.sweep, 180);
      expect(shown.dial.face, DialFace.needle);
      expect(shown.dial.thickness, Thickness.regular);
      expect(shown.colours.normal, const Color(0xFFFB8C00));
    });

    test('a field given as null in copyWith is cleared', () {
      const look = DialLook(face: DialFace.needle, sweep: 240);
      expect(look.copyWith(face: null), const DialLook(sweep: 240));
      expect(look.copyWith(sweep: 300).sweep, 300);
      expect(look.copyWith(), look);
    });

    test('counts only the changes a kind of gauge uses', () {
      const look = GaugeAppearance(
        dial: DialLook(face: DialFace.needle, sweep: 240),
        bar: BarLook(segmented: true),
        colours: GaugeColours(normal: Color(0xFFFB8C00)),
      );
      expect(look.changesFor(GaugeStyle.dial), 3);
      expect(look.changesFor(GaugeStyle.bar), 2);
      expect(look.changesFor(GaugeStyle.digital), 1);
      // A lamp has no normal-reading colour to change.
      expect(look.changesFor(GaugeStyle.lamp), 0);
    });

    test('handing a look to the default leaves the other kinds behind', () {
      const look = GaugeAppearance(
        dial: DialLook(face: DialFace.needle),
        bar: BarLook(segmented: true),
        colours: GaugeColours(normal: Color(0xFFFB8C00)),
      );
      expect(
        look.only(GaugeStyle.dial),
        const GaugeAppearance(
          dial: DialLook(face: DialFace.needle),
          colours: GaugeColours(normal: Color(0xFFFB8C00)),
        ),
      );
      expect(
        look.without(GaugeStyle.dial),
        const GaugeAppearance(bar: BarLook(segmented: true)),
      );
    });
  });

  group('colours', () {
    const scheme = ColorScheme.light();

    test('alarm colours fall back to the fixed palette', () {
      const colours = GaugeColours();
      expect(
        colours.forStatus(GaugeStatus.warning, normal: Colors.black),
        StatusPalette.warning,
      );
      expect(
        colours.forStatus(GaugeStatus.danger, normal: Colors.black),
        StatusPalette.critical,
      );
      expect(
        colours.forStatus(GaugeStatus.normal, normal: Colors.black),
        Colors.black,
      );
    });

    test('chosen colours are used for every state', () {
      const colours = GaugeColours(
        normal: Color(0xFF1E88E5),
        warning: Color(0xFFFB8C00),
        danger: Color(0xFF8E24AA),
      );
      expect(
        colours.forStatus(GaugeStatus.normal, normal: Colors.black),
        const Color(0xFF1E88E5),
      );
      expect(
        colours.forStatus(GaugeStatus.warning, normal: Colors.black),
        const Color(0xFFFB8C00),
      );
      expect(
        colours.forStatus(GaugeStatus.danger, normal: Colors.black),
        const Color(0xFF8E24AA),
      );
    });

    test('text stays readable on a background the theme did not choose', () {
      // The light theme's dark text, on black.
      const onBlack = GaugeColours(background: Color(0xFF000000));
      expect(onBlack.textOn(scheme), const Color(0xFFFFFFFF));
      // A text colour that was chosen is used as it is.
      const chosen = GaugeColours(
        background: Color(0xFF000000),
        text: Color(0xFF202020),
      );
      expect(chosen.textOn(scheme), const Color(0xFF202020));
      // And with no background of its own, the theme's.
      expect(const GaugeColours().textOn(scheme), scheme.onSurface);
    });
  });
}
