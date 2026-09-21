@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// The generated settings screens, against the real shipped definition.
///
/// Every assertion here is something a tuner would notice immediately if it
/// were wrong: a field bound to nothing, a condition that never resolves so
/// the field it guards never appears, a curve that cannot be opened.
void main() {
  late IniDocument doc;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  test('every dialog field binds to an editable setting', () {
    // The aux-channel aliases are `string` PC variables - a shape the field
    // model does not cover, and one the ECU does not store. Everything else
    // must resolve, or it is a control shown with nothing behind it.
    final tune = TuneState.empty(doc);
    final resolver = TuneValueResolver(tune);
    final unbound = <String>{};

    for (final dialog in doc.dialogs) {
      for (final item in dialog.items) {
        final name = switch (item) {
          IniDialogField(:final constant) => constant,
          IniDialogSlider(:final constant) => constant,
          _ => null,
        };
        if (name == null) continue;
        if (SettingView.of(tune, name, resolver: resolver) == null) {
          unbound.add(name);
        }
      }
    }

    expect(unbound.where((n) => !n.endsWith('Alias')), isEmpty);
  });

  test('every dialog condition evaluates against a tune alone', () {
    // A condition that resolves to null is a field FoxTune cannot decide
    // about - it would be shown or hidden by a fallback rather than by what
    // the tune actually says.
    //
    // The exception is a condition over a *realtime* channel, such as the
    // hardware-test dialog's `testactive`. Those genuinely need the live feed
    // and cannot be answered from stored settings, so the renderer resolves
    // them against the realtime snapshot as well.
    final tune = TuneState.empty(doc);
    final resolver = TuneValueResolver(tune);
    final channels = doc.outputChannels.allNames;
    final unresolved = <String>{};
    var checked = 0;

    void check(String? source) {
      if (source == null) return;
      checked++;
      final compiled = CompiledExpression.tryCompile(source);
      if (compiled == null) {
        unresolved.add(source);
        return;
      }
      if (compiled.references.any(channels.contains)) return;
      if (compiled.evaluate(resolver.resolve) == null) unresolved.add(source);
    }

    for (final dialog in doc.dialogs) {
      for (final item in dialog.items) {
        check(item.enableCondition);
        check(item.visibleCondition);
      }
    }
    for (final menu in doc.menus) {
      for (final item in menu.items) {
        check(item.condition);
        for (final child in item.children) {
          check(child.condition);
        }
      }
    }

    expect(checked, greaterThan(800));
    expect(unresolved, isEmpty, reason: 'unresolved: $unresolved');
  });

  test('every curve a menu or panel opens resolves to an editable view', () {
    // Two further curves exist that nothing navigates to - the WUE analyzer's
    // working curves, whose bins are host-side `[PcVariables]`. Requiring
    // those to be editable would be requiring something no screen offers.
    final tune = TuneState.empty(doc);
    final resolver = TuneValueResolver(tune);

    final reachable = <String>{};
    for (final menu in doc.menus) {
      for (final item in menu.leaves) {
        reachable.add(item.target);
      }
    }
    for (final dialog in doc.dialogs) {
      for (final item in dialog.items) {
        if (item is IniDialogPanel) reachable.add(item.target);
      }
    }

    final unresolved = <String>[];
    for (final curve in doc.curves) {
      if (!reachable.contains(curve.id)) continue;
      if (CurveView.of(tune, curve, resolver: resolver) == null) {
        unresolved.add(curve.id);
      }
    }

    expect(unresolved, isEmpty, reason: 'unresolved: $unresolved');
    expect(reachable.where(doc.curves.map((c) => c.id).contains),
        hasLength(greaterThan(20)));
  });

  test('gauge limits are editable as host-side values', () {
    // The whole Gauge Limits dialog is `[PcVariables]`: nothing there is
    // stored on the ECU, so a page-only view would render it empty.
    final tune = TuneState.empty(doc);
    final warn = SettingView.of(tune, 'rpmwarn')!;

    expect(warn.isHostSide, isTrue);
    warn.setValue(6500);
    expect(warn.value, 6500);
    // Nothing host-side is ever burned, so nothing may be marked for sending.
    expect(tune.isDirty, isFalse);
  });

  test('host-side values carry over to the next session', () {
    // Gauge Limits are PC variables: nothing on the ECU holds them, so a new
    // session starts from factory values unless they are saved and put back.
    final first = TuneState.empty(doc);
    SettingView.of(first, 'rpmwarn')!.setValue(6500);
    SettingView.of(first, 'rpmdang')!.setValue(7200);

    final saved = first.hostOverrides();
    expect(saved.keys, containsAll(['rpmwarn', 'rpmdang']));

    final next = TuneState.empty(doc)..restoreHost(saved);
    expect(SettingView.of(next, 'rpmwarn')!.value, 6500);
    expect(SettingView.of(next, 'rpmdang')!.value, 7200);
  });

  test('only values changed from the factory setting are saved', () {
    final tune = TuneState.empty(doc);
    // Reading seeds the value from its default without changing it.
    SettingView.of(tune, 'rpmhigh')!.value;
    expect(tune.hostOverrides(), isEmpty);

    SettingView.of(tune, 'rpmhigh')!.setValue(9000);
    expect(tune.hostOverrides().keys, ['rpmhigh']);
  });

  test('a saved value for a variable that no longer exists is ignored', () {
    final tune = TuneState.empty(doc)
      ..restoreHost({
        'gone': [1, 2, 3],
        'rpmwarn': [6100, 9999],
      });

    expect(SettingView.of(tune, 'rpmwarn')!.value, 6100);
  });

  test('warmup enrichment reads as an editable curve', () {
    final tune = TuneState.empty(doc);
    final wue = CurveView.of(tune, doc.curveNamed('warmup_curve')!)!;

    expect(wue.length, greaterThan(4));
    expect(wue.xChannel, isNotNull);

    wue.setXAt(0, -40);
    wue.setYAt(0, 150);
    expect(wue.xAt(0), -40);
    expect(wue.yAt(0), 150);
    expect(tune.dirtyPages, isNotEmpty);
  });

  test('a trigger setting round-trips through a .msq export', () {
    // A setting written through a SettingView has to land in the bytes the
    // tune file reads back, or a saved tune and a burned tune disagree.
    final tune = TuneState.empty(doc);
    final pattern = SettingView.of(tune, 'TrigPattern')!;
    final teeth = SettingView.of(tune, 'numTeeth')!;

    pattern.setOptionIndex(2);
    teeth.setValue(36);

    final restored = TuneState.empty(doc);
    MsqCodec.decode(MsqCodec.encode(tune), restored);

    expect(SettingView.of(restored, 'TrigPattern')!.optionIndex, 2);
    expect(SettingView.of(restored, 'numTeeth')!.value, 36);
  });
}
