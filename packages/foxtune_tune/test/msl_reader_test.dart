@TestOn('vm')
library;

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
  stoich = scalar, U08, 0, ":1", 0.1, 0.0, 8.0, 25.5, 1
[OutputChannels]
  ochGetCommand = "r"
  ochBlockSize  = 8
  rpm     = scalar, U16, 0, "rpm", 1.000, 0.000
  afr     = scalar, U08, 2, "O2",  0.100, 0.000
  VE1     = scalar, U08, 3, "%",   1.000, 0.000
  ghost   = scalar, U08, 4, "x",   1.000, 0.000
  lambda  = { afr / stoich }
  doubled = { rpm * 2 }
  loopA   = { loopB + 1 }
  loopB   = { loopA + 1 }
[Datalog]
  entry = time,   "Time",   float, "%.3f"
  entry = rpm,    "RPM",    int,   "%d"
  entry = afr,    "AFR",    float, "%.2f"
  entry = VE1,    "VE1",    int,   "%d"
  entry = ghost,  "Spare",  int,   "%d"
  entry = ghost,  "Spare",  int,   "%d"
''';

IniDocument get definition => IniParser().parse(_source);

void main() {
  group('reading', () {
    test('reads back what the writer wrote', () {
      final writer = MslLogWriter.forDefinition(definition);
      final text = StringBuffer(writer.header());
      for (var i = 0; i < 3; i++) {
        final block = Uint8List(8);
        ByteData.sublistView(block)
          ..setUint16(0, 2000 + i * 100, Endian.little)
          ..setUint8(2, 147 + i)
          ..setUint8(3, 60);
        text.write(writer.row(
          RealtimeDecoder(definition.outputChannels).decode(block),
          Duration(milliseconds: i * 50),
        ));
      }

      final log = MslLog.parse(text.toString());

      expect(log.banner.first, 'speeduino 202504-dev');
      expect(log.labels, ['Time', 'RPM', 'AFR', 'VE1', 'Spare', 'Spare']);
      expect(log.rowCount, 3);
      expect(log.valueAt(2, 0), closeTo(0.1, 1e-9));
      expect(log.valueAt(1, log.indexOf('RPM')!), 2100);
      expect(log.valueAt(2, log.indexOf('AFR')!), closeTo(14.9, 1e-9));
    });

    test('takes a TunerStudio log as it comes', () {
      // CRLF endings, a units row, a MARK line, a blank cell and a short row.
      const text = '"speeduino 202402"\r\n'
          '"Capture Date: Sat Sep 27 10:00:00 EEST 2026"\r\n'
          'Time\tRPM\tAFR\r\n'
          's\trpm\tO2\r\n'
          '0.000\t800\t14.70\r\n'
          'MARK 000 - Manual - 10:00:01\r\n'
          '0.050\t\t14.60\r\n'
          '0.100\t820\r\n';

      final log = MslLog.parse(text);

      expect(log.banner, [
        'speeduino 202402',
        'Capture Date: Sat Sep 27 10:00:00 EEST 2026',
      ]);
      expect(log.units, ['s', 'rpm', 'O2']);
      expect(log.rowCount, 3);
      expect(log.skippedLines, 1);
      expect(log.valueAt(1, 1), isNull, reason: 'a blank cell is no reading');
      expect(log.valueAt(1, 2), closeTo(14.6, 1e-9));
      expect(log.valueAt(2, 2), isNull, reason: 'a short row lacks the rest');
    });

    test('a log without a units row starts its rows straight away', () {
      final log = MslLog.parse('Time\tRPM\n0\t800\n0.05\t810\n');

      expect(log.units, ['', '']);
      expect(log.rowCount, 2);
      expect(log.valueAt(0, 1), 800);
    });

    test('refuses a file with no column headings', () {
      expect(() => MslLog.parse('"just a banner"\nnothing here\n'),
          throwsFormatException);
    });

    test('parses several columns in one pass and keeps them', () {
      final log = MslLog.parse('Time\tA\tB\tC\n0\t1\t2\t3\n1\t4\t5\t6\n');
      log.load([1, 3]);

      expect(log.column(1), [1, 4]);
      expect(log.column(3), [3, 6]);
      expect(identical(log.column(1), log.column(1)), isTrue);
    });
  });

  group('channels', () {
    MslChannels channelsOf(String text) => MslChannels(
          MslLog.parse(text),
          definition,
          constantResolver: (name) => name == 'stoich' ? 14.7 : null,
        );

    test('matches headings to channels by the definition\'s labels', () {
      final channels = channelsOf(
        'Time\tRPM\tAFR\tVE1\tMystery\n0\t3000\t14.7\t55\t1\n',
      );

      expect(channels.columns, {'time': 0, 'rpm': 1, 'afr': 2, 'VE1': 3});
      expect(channels.unmatched, ['Mystery']);

      final row = channels.row(0);
      expect(row('rpm'), 3000);
      expect(row('VE1'), 55);
    });

    test('works out a computed channel from recorded ones and the tune', () {
      final row = channelsOf('Time\tRPM\tAFR\n0\t3000\t16.17\n').row(0);

      expect(row('lambda'), closeTo(1.1, 1e-9));
      expect(row('doubled'), 6000);
    });

    test('a recorded channel left blank reads as nothing', () {
      final row = channelsOf('Time\tRPM\tAFR\n0\t\t14.7\n').row(0);

      expect(row('rpm'), isNull);
      // And what is computed from it is unavailable too, not zero.
      expect(row('doubled'), isNull);
    });

    test('a repeated heading is matched to each of its entries in turn', () {
      final channels = channelsOf('Time\tSpare\tSpare\n0\t1\t2\n');

      // Both entries are the same channel, so the second has nowhere to go.
      expect(channels.columns['ghost'], 1);
      expect(channels.unmatched, ['Spare']);
    });

    test('a heading that is a channel\'s own name is matched to it', () {
      final channels = channelsOf('Time\tdoubled\n0\t42\n');

      expect(channels.row(0)('doubled'), 42);
    });

    test('a circular definition reads as unavailable rather than hanging', () {
      expect(channelsOf('Time\tRPM\n0\t800\n').row(0)('loopA'), isNull);
    });

    test('reports the units the log gives a channel', () {
      final channels = channelsOf('Time\tRPM\tAFR\ns\trpm\tO2\n0\t800\t14\n');

      expect(channels.unitsOf('afr'), 'O2');
      expect(channels.unitsOf('VE1'), '');
    });
  });

  group('real definitions', () {
    IniDocument fixture(String name, {Set<String> defined = const {}}) {
      final candidates = [
        File('packages/foxtune_ini/test/fixtures/$name'),
        File('../foxtune_ini/test/fixtures/$name'),
      ];
      return IniParser(defined: defined).parse(
          candidates.firstWhere((f) => f.existsSync()).readAsStringSync());
    }

    test('a Speeduino log names every channel autotuning reads', () {
      final doc = fixture('speeduino.ini', defined: {'CELSIUS'});
      final labels = {
        for (final entry in doc.datalog) entry.channel: entry.label,
      };
      final text = '${[
        'Time',
        labels['rpm'],
        labels['fuelLoad'],
        labels['afr'],
        labels['egoCorrection'],
        labels['coolant'],
        labels['engine'],
        labels['pulseWidth'],
        labels['VE1'],
      ].join('\t')}\n0\t3000\t60\t14.7\t100\t85\t0\t3\t55\n';

      final channels = MslChannels(MslLog.parse(text), doc);

      expect(channels.unmatched, isEmpty);
      final config = doc.veAnalyze!;
      final row = channels.row(0);
      expect(row(config.measuredChannel), closeTo(14.7, 1e-9));
      expect(row(config.egoCorrectionChannel), 100);
      for (final filter in config.channelFilters) {
        expect(row(filter.channel), isNotNull, reason: filter.channel);
      }
    });

    test('rusEFI\'s analysis channels are rebuilt from what it logs', () {
      final doc = fixture('rusefi_uaefi.ini');
      final labels = {
        for (final entry in doc.datalog) entry.channel: entry.label,
      };
      final text = '${[
        'Time',
        labels['lambdaValue'],
        labels['afrGasolineScale'],
        labels['Gego'],
      ].join('\t')}\n0\t0.95\t13.97\t103\n';

      // Neither analysis channel is logged; both are computed.
      expect(labels.containsKey('veAnalyzeAfrLambda1'), isFalse);
      expect(labels.containsKey('egoCorrectionForVeAnalyze'), isFalse);

      MslChannels withDisplay(double lambda) => MslChannels(
            MslLog.parse(text),
            doc,
            constantResolver: (name) =>
                name == 'useLambdaOnInterface' ? lambda : null,
          );

      final afr = withDisplay(0).row(0);
      expect(afr('veAnalyzeAfrLambda1'), closeTo(13.97, 1e-9));
      expect(afr('egoCorrectionForVeAnalyze'), 103);

      final lambda = withDisplay(1).row(0);
      expect(lambda('veAnalyzeAfrLambda1'), closeTo(0.95, 1e-9));
    });
  });
}
