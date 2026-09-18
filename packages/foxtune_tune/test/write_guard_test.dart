@TestOn('vm')
library;

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

const _source = '''
[MegaTune]
signature = "speeduino 202504-dev"
[Constants]
endianness = little
nPages     = 2
pageSize   = 128, 288
page = 1
  a = array, U08, 0, [128], "%", 1.0, 0.0, 0.0, 255.0, 0
page = 2
  b = array, U08, 0, [288], "%", 1.0, 0.0, 0.0, 255.0, 0
''';

IniDocument get definition => IniParser().parse(_source);

void main() {
  group('WritePermission', () {
    test('grants only when the signature matches and write mode is on', () {
      final permission = WritePermission.evaluate(
        definition: definition,
        reportedSignature: 'speeduino 202504-dev',
        writeModeEnabled: true,
      );
      expect(permission.allowed, isTrue);
      expect(permission.reason, isNull);
    });

    test('refuses when write mode is off', () {
      // Read-only is the default so that connecting to an engine cannot, by
      // itself, change it.
      final permission = WritePermission.evaluate(
        definition: definition,
        reportedSignature: 'speeduino 202504-dev',
        writeModeEnabled: false,
      );
      expect(permission.allowed, isFalse);
      expect(permission.reason, contains('Write mode is off'));
    });

    test('refuses on a signature mismatch', () {
      // The definition may not describe this ECU, so every offset is suspect.
      final permission = WritePermission.evaluate(
        definition: definition,
        reportedSignature: 'speeduino 202207',
        writeModeEnabled: true,
      );
      expect(permission.allowed, isFalse);
      expect(permission.reason, contains('cannot be trusted'));
    });

    test('refuses when the ECU reported nothing', () {
      expect(
        WritePermission.evaluate(
          definition: definition,
          reportedSignature: null,
          writeModeEnabled: true,
        ).allowed,
        isFalse,
      );
    });

    test('refuses when no definition is loaded', () {
      expect(
        WritePermission.evaluate(
          definition: null,
          reportedSignature: 'speeduino 202504-dev',
          writeModeEnabled: true,
        ).allowed,
        isFalse,
      );
    });

    test('refuses when the definition declares no signature', () {
      // An unknown expectation is not a match; it must never act as a wildcard.
      final anonymous =
          IniParser().parse('[Constants]\nnPages = 1\npageSize = 8');
      expect(
        WritePermission.evaluate(
          definition: anonymous,
          reportedSignature: 'anything',
          writeModeEnabled: true,
        ).allowed,
        isFalse,
      );
    });
  });

  group('TuneWriter', () {
    late FakeSpeeduino ecu;
    late SocketEcuLink link;
    late EcuClient client;
    late TuneState tune;

    setUp(() async {
      ecu = FakeSpeeduino(pageSizes: const [128, 288]);
      final port = await ecu.start();
      link = await SocketEcuLink.connect('127.0.0.1', port);
      client = EcuClient(link, timeout: const Duration(seconds: 2));
      tune = TuneState.empty(definition);
    });

    tearDown(() async {
      await client.close();
      await link.close();
      await ecu.stop();
    });

    TuneWriter writerWith(
      WritePermission permission, {
      Future<void> Function(TuneState)? onSnapshot,
    }) =>
        TuneWriter(
          client: client,
          tune: tune,
          permission: permission,
          blockingFactor: 251,
          onSnapshot: onSnapshot,
        );

    void dirtyPage1(int value) {
      final f = tune.locate('a')!;
      tune.writeRaw(f.page, f.field, value, 0);
    }

    test('refuses to write without permission, and touches nothing', () async {
      dirtyPage1(42);
      final writer =
          writerWith(const WritePermission.refused('Write mode is off.'));

      await expectLater(
          writer.commitPage(1), throwsA(isA<WriteRefusedException>()));

      expect(ecu.ramDirty, isEmpty, reason: 'nothing may reach the ECU');
      expect(ecu.burnedPages, isEmpty);
      expect(tune.isDirty, isTrue, reason: 'the edit is still pending');
    });

    test('writes, verifies and burns in that order', () async {
      dirtyPage1(42);
      final result =
          await writerWith(const WritePermission.granted()).commitPage(1);

      expect(result.verified, isTrue);
      expect(result.burned, isTrue);
      expect(result.bytesWritten, 128);
      expect(ecu.pages[0][0], 42);
      expect(ecu.burnedPages, contains(1));
      expect(tune.isDirty, isFalse);
    });

    test('takes a restore point before the first write', () async {
      dirtyPage1(7);
      TuneState? snapshot;
      final writer = writerWith(
        const WritePermission.granted(),
        onSnapshot: (s) async => snapshot = s,
      );

      await writer.commitPage(1);

      expect(snapshot, isNotNull);
      expect(writer.snapshotTaken, isTrue);
      // The snapshot must be independent of later edits.
      dirtyPage1(9);
      expect(snapshot!.page(1)[0], 7);
    });

    test('takes the restore point only once per session', () async {
      var count = 0;
      final writer = writerWith(
        const WritePermission.granted(),
        onSnapshot: (_) async => count++,
      );

      dirtyPage1(1);
      await writer.commitPage(1);
      dirtyPage1(2);
      await writer.commitPage(1);

      expect(count, 1);
    });

    test('does not burn when verification fails', () async {
      dirtyPage1(42);
      // Corrupt the ECU's copy after the write so the CRC cannot match.
      final writer = TuneWriter(
        client: client,
        tune: tune,
        permission: const WritePermission.granted(),
        blockingFactor: 251,
      );
      // Make the simulator's stored page differ from what we sent.
      ecu.mutateAfterWrite = true;

      await expectLater(
        writer.commitPage(1),
        throwsA(isA<EcuProtocolException>()),
      );
      expect(ecu.burnedPages, isEmpty,
          reason: 'a page that did not land intact must never be made '
              'permanent');
    });

    test('commits every dirty page, lowest first', () async {
      final a = tune.locate('a')!;
      final b = tune.locate('b')!;
      tune.writeRaw(a.page, a.field, 1, 0);
      tune.writeRaw(b.page, b.field, 2, 0);

      final results =
          await writerWith(const WritePermission.granted()).commitDirtyPages();

      expect([for (final r in results) r.page], [1, 2]);
      expect(ecu.burnedPages, {1, 2});
      expect(tune.isDirty, isFalse);
    });

    test('chunks a page larger than the blocking factor', () async {
      final b = tune.locate('b')!;
      for (var i = 0; i < 288; i++) {
        tune.writeRaw(b.page, b.field, i & 0xFF, i);
      }

      await writerWith(const WritePermission.granted()).commitPage(2);

      expect(ecu.pages[1], tune.page(2));
      final writes =
          ecu.requests.where((r) => r[0] == SpeeduinoCommand.pageWrite).length;
      expect(writes, 2);
    });

    test('readAll pulls every page into the tune', () async {
      final loaded = await TuneWriter.readAll(
        client,
        into: tune,
        blockingFactor: 251,
      );

      expect(loaded.page(1), ecu.pages[0]);
      expect(loaded.page(2), ecu.pages[1]);
      expect(loaded.isDirty, isFalse,
          reason: 'data just read from the ECU is in sync with it');
    });
  });
}
