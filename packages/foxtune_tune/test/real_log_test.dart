@TestOn('vm')
library;

import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

/// Records a log from a simulated running engine using the real definition.
void main() {
  late IniDocument doc;
  late Directory dir;

  setUpAll(() {
    final candidates = [
      File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
      File('../foxtune_ini/test/fixtures/speeduino.ini'),
    ];
    final fixture = candidates.firstWhere((f) => f.existsSync());
    doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
  });

  setUp(() async => dir = await Directory.systemTemp.createTemp('foxtune_msl'));
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('records a well-formed log from a running engine', () async {
    final ecu = FakeSpeeduino(
      pageSizes: doc.constants.pageSizes,
      realtimeBlockSize: doc.outputChannels.blockSize!,
      channels: doc.outputChannels,
    );
    final port = await ecu.start();
    ecu.simulateEngine(tick: const Duration(milliseconds: 10));

    final link = await SocketEcuLink.connect('127.0.0.1', port);
    final client = EcuClient(link, timeout: const Duration(seconds: 2));
    final decoder = RealtimeDecoder(
      doc.outputChannels,
      constantResolver: (name) => name == 'twoStroke' ? 0 : null,
    );

    final probe = decoder.decode(
        await client.readRealtime(count: doc.outputChannels.blockSize!));
    final recorder = LogRecorder(definition: doc);
    final file = File('${dir.path}/session.msl');
    await recorder.start(file, probe: probe);

    for (var i = 0; i < 30; i++) {
      recorder.add(decoder.decode(
          await client.readRealtime(count: doc.outputChannels.blockSize!)));
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
    await recorder.stop();

    await client.close();
    await link.close();
    await ecu.stop();

    final lines = file.readAsLinesSync();
    expect(lines.length, 4 + 30);
    expect(lines[0], '"${doc.identity.signature}"');
    expect(lines[1], startsWith('"Capture Date:'));

    final labels = lines[2].split('\t');
    expect(labels.first, 'Time');
    // The definition's own column names, which MegaLogViewer keys off.
    expect(labels, containsAll(['RPM', 'MAP', 'TPS', 'CLT', 'AFR']));
    expect(lines[3].split('\t'), hasLength(labels.length));

    for (final line in lines.skip(4)) {
      expect(line.split('\t'), hasLength(labels.length),
          reason: 'ragged row: $line');
    }

    // The engine is running, so the data must actually vary.
    final rpmIndex = labels.indexOf('RPM');
    final rpms = [
      for (final line in lines.skip(4))
        double.tryParse(line.split('\t')[rpmIndex]) ?? -1,
    ];
    expect(rpms.every((r) => r >= 0), isTrue, reason: 'RPM column has gaps');
    expect(rpms.toSet().length, greaterThan(1),
        reason: 'a running engine should not log a constant RPM');

    // Time must advance monotonically.
    final timeIndex = labels.indexOf('Time');
    var previous = -1.0;
    for (final line in lines.skip(4)) {
      final t = double.parse(line.split('\t')[timeIndex]);
      expect(t, greaterThanOrEqualTo(previous));
      previous = t;
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('reports which channels were left out of the log', () {
    final writer = MslLogWriter.forDefinition(doc);
    // Without a probe nothing is dropped for being blank, so anything here
    // was excluded by its own condition.
    expect(writer.columns, isNotEmpty);
    expect(writer.columns.length + writer.dropped.length, doc.datalog.length);
  });
}
