@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Settings, end to end against the simulator over a real socket.
///
/// The unit tests prove a `SettingView` puts the right number in the right
/// bytes. This proves the rest of the journey: that those bytes survive the
/// write, the CRC verification, the burn, and a fresh read back - which is
/// what a tuner is actually relying on when they change a trigger pattern.
void main() {
  late IniDocument doc;
  late FakeSpeeduino ecu;
  late SocketEcuLink link;
  late EcuClient client;
  late TuneState tune;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  setUp(() async {
    ecu = FakeSpeeduino(
      signature: doc.identity.signature!,
      pageSizes: doc.constants.pageSizes,
    );
    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2));

    tune = TuneState.empty(doc);
    await TuneWriter.readAll(client, into: tune, blockingFactor: 251);
    tune.markClean();
  });

  tearDown(() async {
    await client.close();
    await link.close();
    await ecu.stop();
  });

  Future<List<CommitResult>> burn() {
    final writer = TuneWriter(
      client: client,
      tune: tune,
      permission: const WritePermission.granted(),
      blockingFactor: 251,
    );
    return writer.commitDirtyPages();
  }

  Future<TuneState> reRead() async {
    final fresh = TuneState.empty(doc);
    await TuneWriter.readAll(client, into: fresh, blockingFactor: 251);
    return fresh;
  }

  test('an enumerated setting survives write, burn and re-read', () async {
    final pattern = SettingView.of(tune, 'TrigPattern')!;
    // Pick something other than whatever the simulator started with, so the
    // test cannot pass by the value never having changed.
    final target = pattern.optionIndex == 2 ? 5 : 2;
    final expectedLabel = pattern.options[target];
    pattern.setOptionIndex(target);

    final results = await burn();
    expect(results, isNotEmpty);
    expect(results.every((r) => r.burned), isTrue);

    final after = SettingView.of(await reRead(), 'TrigPattern')!;
    expect(after.optionIndex, target);
    expect(after.optionLabel, expectedLabel);
  });

  test('a bitfield burn leaves its byte-mates alone', () async {
    // `injLayout` and `inj4CylPairing` share a byte. A write that did not
    // merge would reset the other one, which is the sort of change a tuner
    // would only find later, by the engine running wrong.
    final layout = SettingView.of(tune, 'injLayout')!;
    final pairing = SettingView.of(tune, 'inj4CylPairing')!;
    pairing.setOptionIndex(1);
    layout.setOptionIndex(3);

    await burn();

    final fresh = await reRead();
    expect(SettingView.of(fresh, 'injLayout')!.optionIndex, 3);
    expect(SettingView.of(fresh, 'inj4CylPairing')!.optionIndex, 1);
  });

  test('a scalar setting round-trips through its declared scale', () async {
    final angle = SettingView.of(tune, 'TrigAng')!;
    angle.setValue(115);

    await burn();

    expect(SettingView.of(await reRead(), 'TrigAng')!.value, 115);
  });

  test('a curve point survives the same journey', () async {
    final wue = CurveView.of(tune, doc.curveNamed('warmup_curve')!)!;
    wue.setYAt(0, 155);
    wue.setXAt(0, -40);

    await burn();

    final fresh =
        CurveView.of(await reRead(), doc.curveNamed('warmup_curve')!)!;
    expect(fresh.yAt(0), 155);
    expect(fresh.xAt(0), -40);
  });

  test('nothing is sent while the session is read-only', () async {
    SettingView.of(tune, 'TrigAng')!.setValue(50);

    final writer = TuneWriter(
      client: client,
      tune: tune,
      permission: const WritePermission.refused('Read-only for the test.'),
      blockingFactor: 251,
    );

    await expectLater(
      writer.commitDirtyPages(),
      throwsA(isA<WriteRefusedException>()),
    );
    expect(
      ecu.requests.any((r) => r[0] == SpeeduinoCommand.pageWrite),
      isFalse,
    );
  });
}
