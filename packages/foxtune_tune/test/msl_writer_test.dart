@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

const _source = '''
[MegaTune]
signature = "speeduino 202504-dev"
[Constants]
nPages   = 1
pageSize = 8
page = 1
  fitted = scalar, U08, 0, "", 1.0, 0.0, 0.0, 1.0, 0
[OutputChannels]
  ochGetCommand = "r"
  ochBlockSize  = 8
  secl  = scalar, U08, 0, "sec",  1.000, 0.000
  rpm   = scalar, U16, 1, "rpm",  1.000, 0.000
  tps   = scalar, U08, 3, "%",    0.500, 0.000
  clt   = scalar, U08, 4, "C",    1.000, -40.000
  ghost = scalar, U08, 9, "x",    1.000, 0.000
  computedOnly = { rpm * 2 }
[Datalog]
  entry = time,  "Time", float, "%.3f"
  entry = secl,  "SecL", int,   "%d"
  entry = rpm,   "RPM",  int,   "%d"
  entry = tps,   "TPS",  float, "%.1f"
  entry = clt,   "CLT",  int,   "%d"
  entry = computedOnly, "Doubled", int, "%d"
  entry = ghost, "Ghost", int,   "%d"
  entry = optional, { stringValue(alias) }, int, "%d", { neverTrue }
''';

IniDocument get definition => IniParser().parse(_source);

RealtimeSnapshot sampleWith({int rpm = 3000, int tps = 84, int clt = 130}) {
  final block = Uint8List(8);
  final view = ByteData.sublistView(block);
  view.setUint8(0, 42);
  view.setUint16(1, rpm, Endian.little);
  view.setUint8(3, tps);
  view.setUint8(4, clt);
  return RealtimeDecoder(definition.outputChannels).decode(block);
}

void main() {
  group('column selection', () {
    late MslLogWriter writer;

    setUp(() {
      writer = MslLogWriter.forDefinition(definition, probe: sampleWith());
    });

    test('keeps channels that produce a value', () {
      final labels = [for (final c in writer.columns) c.label];
      expect(labels, containsAll(['Time', 'SecL', 'RPM', 'TPS', 'CLT']));
    });

    test('keeps a computed channel', () {
      expect([for (final c in writer.columns) c.label], contains('Doubled'));
    });

    test('drops a channel that would be blank for the whole log', () {
      // ghost sits past the end of the block, so it can never produce a value.
      expect(
          [for (final c in writer.columns) c.label], isNot(contains('Ghost')));
      expect(writer.dropped, contains('ghost'));
    });

    test('drops a channel whose condition is false', () {
      expect(writer.dropped, contains('optional'));
    });

    test('keeps time even though it is not a channel', () {
      // The recorder supplies it from its own clock.
      expect(writer.columns.first.channel, 'time');
    });
  });

  group('header', () {
    test('has the banner, column and unit rows', () {
      final writer =
          MslLogWriter.forDefinition(definition, probe: sampleWith());
      // Split on newlines only: trimming would eat a trailing empty unit,
      // which is legitimate for a channel that declares none.
      final lines = writer.header().split('\n')..removeLast();

      expect(lines, hasLength(4));
      expect(lines[0], '"speeduino 202504-dev"');
      expect(lines[1], startsWith('"Capture Date:'));

      final labels = lines[2].split('\t');
      final units = lines[3].split('\t');
      expect(labels.first, 'Time');
      expect(labels, contains('RPM'));
      // One unit per column, in the same order.
      expect(units, hasLength(labels.length));
      expect(units[labels.indexOf('RPM')], 'rpm');
      expect(units[labels.indexOf('TPS')], '%');
    });
  });

  group('rows', () {
    late MslLogWriter writer;

    setUp(() =>
        writer = MslLogWriter.forDefinition(definition, probe: sampleWith()));

    List<String> cellsFor(RealtimeSnapshot snapshot, Duration elapsed) {
      final line = writer.row(snapshot, elapsed);
      // Drop the trailing newline only - a blank final cell is meaningful.
      return line.substring(0, line.length - 1).split('\t');
    }

    int indexOf(String label) =>
        writer.columns.indexWhere((c) => c.label == label);

    test('is tab separated with one cell per column', () {
      final cells = cellsFor(sampleWith(), Duration.zero);
      expect(cells, hasLength(writer.columns.length));
    });

    test('formats integers and floats as the definition asks', () {
      final cells = cellsFor(sampleWith(rpm: 3000, tps: 84), Duration.zero);
      expect(cells[indexOf('RPM')], '3000');
      // tps has scale 0.5 and one decimal place.
      expect(cells[indexOf('TPS')], '42.0');
    });

    test('applies translate', () {
      final cells = cellsFor(sampleWith(clt: 130), Duration.zero);
      expect(cells[indexOf('CLT')], '90');
    });

    test('writes elapsed seconds in the time column', () {
      final cells = cellsFor(sampleWith(), const Duration(milliseconds: 1500));
      expect(cells[indexOf('Time')], '1.500');
    });

    test('leaves a cell blank rather than inventing a zero', () {
      // A reading that is absent is not a reading of zero, and a plot should
      // show the gap.
      final short =
          RealtimeDecoder(definition.outputChannels).decode(Uint8List(2));
      final cells = cellsFor(short, Duration.zero);
      expect(cells[indexOf('RPM')], isEmpty);
    });
  });

  group('LogRecorder', () {
    late Directory dir;

    setUp(
        () async => dir = await Directory.systemTemp.createTemp('foxtune_log'));
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('writes a complete log file', () async {
      final recorder = LogRecorder(definition: definition);
      final file = File('${dir.path}/test.msl');

      await recorder.start(file, probe: sampleWith());
      expect(recorder.isRecording, isTrue);
      for (var i = 0; i < 5; i++) {
        recorder.add(sampleWith(rpm: 1000 + i * 500));
      }
      final written = await recorder.stop();

      expect(written, isNotNull);
      expect(recorder.isRecording, isFalse);
      expect(recorder.rowCount, 5);

      final lines = file.readAsLinesSync();
      expect(lines, hasLength(4 + 5));
      // Every row has the same number of columns as the header.
      final width = lines[2].split('\t').length;
      for (final line in lines.skip(4)) {
        expect(line.split('\t'), hasLength(width));
      }
    });

    test('rows appear on disk as they are recorded', () async {
      // A log is most valuable exactly when the session ends abruptly, so
      // rows must not be buffered until stop().
      final recorder = LogRecorder(definition: definition);
      final file = File('${dir.path}/partial.msl');

      await recorder.start(file, probe: sampleWith());
      for (var i = 0; i < 200; i++) {
        recorder.add(sampleWith(rpm: 2000 + i));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
      await recorder.stop();
    });

    test('records from a stream', () async {
      final recorder = LogRecorder(definition: definition);
      final file = File('${dir.path}/stream.msl');
      final controller = StreamController<RealtimeSnapshot>();

      await recorder.start(file, probe: sampleWith());
      recorder.listenTo(controller.stream);
      for (var i = 0; i < 3; i++) {
        controller.add(sampleWith(rpm: 1500 + i));
      }
      await Future<void>.delayed(Duration.zero);
      await recorder.stop();
      await controller.close();

      expect(recorder.rowCount, 3);
    });

    test('refuses to start twice', () async {
      final recorder = LogRecorder(definition: definition);
      await recorder.start(File('${dir.path}/a.msl'), probe: sampleWith());
      expect(
        () => recorder.start(File('${dir.path}/b.msl'), probe: sampleWith()),
        throwsStateError,
      );
      await recorder.stop();
    });

    test('ignores samples when not recording', () {
      final recorder = LogRecorder(definition: definition);
      recorder.add(sampleWith());
      expect(recorder.rowCount, 0);
    });

    test('stop is safe when never started', () async {
      expect(await LogRecorder(definition: definition).stop(), isNull);
    });
  });
}
