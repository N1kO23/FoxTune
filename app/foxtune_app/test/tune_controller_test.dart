import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _LoadedTune extends TuneController {
  _LoadedTune(this._tune);
  final TuneState _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

void main() {
  late Directory storage;

  setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_tune'));
  tearDown(() => storage.deleteSync(recursive: true));

  test('an edit made in place reaches everything watching the tune', () async {
    // A tune is edited in place, so the edit is announced by publishing the
    // same object again - which an equality check alone would swallow.
    final doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
    final tune = TuneState.empty(doc);
    final container = ProviderContainer(
      overrides: [
        tuneProvider.overrideWith(() => _LoadedTune(tune)),
        jsonStoreProvider.overrideWithValue(JsonStore(() async => storage)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(tuneProvider.future);

    var notified = 0;
    container.listen(tuneProvider, (_, _) => notified++);

    SettingView.of(tune, 'reqFuel')!.setValue(9.5);
    container.read(tuneProvider.notifier).notifyEdited();

    expect(notified, 1);
  });
}
