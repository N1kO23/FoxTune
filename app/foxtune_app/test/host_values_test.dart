import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/host_values.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

void main() {
  late IniDocument doc;
  late Directory storage;
  late HostValues host;

  setUpAll(() {
    doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
  });

  setUp(() {
    storage = Directory.systemTemp.createTempSync('foxtune_host');
    host = HostValues(JsonStore(() async => storage));
  });
  tearDown(() => storage.deleteSync(recursive: true));

  File saved() => File('${storage.path}/host/speeduino.json');

  test('a Gauge Limit set in one session is there in the next', () async {
    final first = TuneState.empty(doc);
    final before = await host.restoreInto(first);
    SettingView.of(first, 'rpmwarn')!.setValue(6500);
    host.saveIfChanged(first, before);

    // A fresh read of the ECU: the pages come back, host values do not.
    final next = TuneState.empty(doc);
    await host.restoreInto(next);

    expect(SettingView.of(next, 'rpmwarn')!.value, 6500);
  });

  test('nothing is written when nothing changed', () async {
    final tune = TuneState.empty(doc);
    final before = await host.restoreInto(tune);

    host.saveIfChanged(tune, before);

    expect(saved().existsSync(), isFalse);
  });

  test('a firmware update keeps them', () async {
    // Saved against one Speeduino release, read back by the next.
    final tune = TuneState.empty(doc);
    SettingView.of(tune, 'rpmdang')!.setValue(7200);
    host.saveIfChanged(tune, const {});

    final updated = IniParser(defined: {'CELSIUS'}).parse(
      File('assets/speeduino.ini')
          .readAsStringSync()
          .replaceFirst('speeduino 202504-dev', 'speeduino 202601'),
    );
    final next = TuneState.empty(updated);
    await host.restoreInto(next);

    expect(SettingView.of(next, 'rpmdang')!.value, 7200);
  });

  test('an unreadable file is ignored rather than fatal', () async {
    saved()
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{ not json');

    final tune = TuneState.empty(doc);
    expect(await host.restoreInto(tune), isEmpty);
  });
}
