@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

IniOutputChannels channelsFrom(String source) =>
    IniParser().parse(source).outputChannels;

void main() {
  group('scalar decoding', () {
    final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 16
  u8    = scalar, U08,  0, "x", 1.000, 0.000
  s8    = scalar, S08,  1, "x", 1.000, 0.000
  u16   = scalar, U16,  2, "x", 1.000, 0.000
  s16   = scalar, S16,  4, "x", 1.000, 0.000
  volts = scalar, U08,  6, "V", 0.100, 0.000
  tempF = scalar, U08,  7, "F", 1.800, -22.230
''');

    late RealtimeSnapshot snapshot;

    setUp(() {
      final block = Uint8List(16);
      final view = ByteData.sublistView(block);
      view.setUint8(0, 200);
      view.setInt8(1, -50);
      // Payload data is little-endian, unlike the frame envelope.
      view.setUint16(2, 6000, Endian.little);
      view.setInt16(4, -1234, Endian.little);
      view.setUint8(6, 138); // 13.8 V
      view.setUint8(7, 100);
      snapshot = RealtimeDecoder(channels).decode(block);
    });

    test('reads each integer width and sign', () {
      expect(snapshot['u8'], 200);
      expect(snapshot['s8'], -50);
      expect(snapshot['u16'], 6000);
      expect(snapshot['s16'], -1234);
    });

    test('reads multi-byte values little-endian', () {
      // 6000 = 0x1770. Big-endian would decode as 0x7017 = 28695.
      expect(snapshot.rawValue('u16'), 6000);
      expect(snapshot.block[2], 0x70);
      expect(snapshot.block[3], 0x17);
    });

    test('applies scale and translate', () {
      expect(snapshot['volts'], closeTo(13.8, 1e-9));
      expect(snapshot['tempF'], closeTo(100 * 1.8 - 22.23, 1e-9));
    });

    test('exposes the unscaled value too', () {
      expect(snapshot.rawValue('volts'), 138);
    });

    test('returns null for an unknown channel', () {
      expect(snapshot['nope'], isNull);
      expect(snapshot.rawValue('nope'), isNull);
    });
  });

  group('bits decoding', () {
    final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  status  = scalar, U08, 0, "bits", 1.000, 0.000
  running = bits,   U08, 0, [0:0]
  crank   = bits,   U08, 0, [1:1]
  mode    = bits,   U08, 1, [0:2], "Off", "On", "Auto", "Hold", "A", "B", "C", "D"
''');

    test('extracts single bits', () {
      // 0b00000010 - crank set, running clear.
      final snapshot =
          RealtimeDecoder(channels).decode(Uint8List.fromList([0x02, 0, 0, 0]));
      expect(snapshot['running'], 0);
      expect(snapshot['crank'], 1);
      expect(snapshot.flag('crank'), isTrue);
      expect(snapshot.flag('running'), isFalse);
    });

    test('extracts a multi-bit field and labels it', () {
      final snapshot =
          RealtimeDecoder(channels).decode(Uint8List.fromList([0, 0x03, 0, 0]));
      expect(snapshot['mode'], 3);
      expect(snapshot.label('mode'), 'Hold');
    });

    test('masks off neighbouring bits', () {
      // 0b11111011: mode occupies [0:2] only, so the high bits must not leak.
      final snapshot =
          RealtimeDecoder(channels).decode(Uint8List.fromList([0, 0xFB, 0, 0]));
      expect(snapshot['mode'], 3);
    });

    test('label is null for a non-bits channel', () {
      final snapshot = RealtimeDecoder(channels).decode(Uint8List(4));
      expect(snapshot.label('status'), isNull);
    });
  });

  group('short blocks', () {
    final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 16
  early = scalar, U08,  0, "x", 1.000, 0.000
  late  = scalar, U16, 14, "x", 1.000, 0.000
''');

    test('decodes what is present and reports the rest unavailable', () {
      // A truncated block is normal while a connection settles; it must not
      // fail the whole sample or produce a made-up reading.
      final snapshot = RealtimeDecoder(channels).decode(Uint8List(4));
      expect(snapshot['early'], 0);
      expect(snapshot['late'], isNull);
    });

    test('handles a field straddling the end of the block', () {
      final snapshot = RealtimeDecoder(channels).decode(Uint8List(15));
      expect(snapshot['late'], isNull, reason: 'U16 at 14 needs 16 bytes');
    });
  });

  group('computed channels', () {
    test('evaluates an expression over decoded values', () {
      final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  coolantRaw = scalar, U08, 0, "C", 1.000, 0.000
  coolant    = { coolantRaw - 40 }
''');
      final snapshot =
          RealtimeDecoder(channels).decode(Uint8List.fromList([120, 0, 0, 0]));
      expect(snapshot['coolantRaw'], 120);
      expect(snapshot['coolant'], 80);
    });

    test('resolves a chain of computed channels', () {
      final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  rpm            = scalar, U16, 0, "rpm", 1.000, 0.000
  revolutionTime = { rpm ? (60000.0 / rpm) : 0 }
  cycleTime      = { revolutionTime * 2 }
''');
      final block = Uint8List(4);
      ByteData.sublistView(block).setUint16(0, 6000, Endian.little);
      final snapshot = RealtimeDecoder(channels).decode(block);

      expect(snapshot['revolutionTime'], 10);
      expect(snapshot['cycleTime'], 20);
    });

    test('guards a division the definition protects with a ternary', () {
      final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  rpm            = scalar, U16, 0, "rpm", 1.000, 0.000
  revolutionTime = { rpm ? (60000.0 / rpm) : 0 }
''');
      // Engine stopped: the ternary must keep this from dividing by zero.
      final snapshot = RealtimeDecoder(channels).decode(Uint8List(4));
      expect(snapshot['revolutionTime'], 0);
    });

    test('refuses to loop on a circular definition', () {
      final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  a = { b + 1 }
  b = { a + 1 }
''');
      final snapshot = RealtimeDecoder(channels).decode(Uint8List(4));
      expect(snapshot['a'], isNull);
      expect(snapshot['b'], isNull);
    });

    test('reports a channel using an unsupported function as unavailable', () {
      final channels = channelsFrom('''
[OutputChannels]
  ochBlockSize = 4
  loops  = scalar, U08, 0, "", 1.000, 0.000
  smooth = { smoothBasic(loops, 75) }
''');
      final decoder = RealtimeDecoder(channels);
      final snapshot = decoder.decode(Uint8List.fromList([10, 0, 0, 0]));
      // Better an unavailable gauge than a fabricated reading.
      expect(snapshot['smooth'], isNull);
      expect(snapshot['loops'], 10);
    });
  });

  group('against the real speeduino.ini', () {
    late IniDocument doc;

    setUpAll(() {
      final candidates = [
        File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
        File('../foxtune_ini/test/fixtures/speeduino.ini'),
      ];
      final fixture = candidates.firstWhere((f) => f.existsSync());
      doc = IniParser(defined: {'CELSIUS'}).parse(fixture.readAsStringSync());
    });

    /// Builds a block with [raws] written at each named channel's real offset.
    Uint8List blockWith(Map<String, int> raws) {
      final channels = doc.outputChannels;
      final block = Uint8List(channels.blockSize!);
      final view = ByteData.sublistView(block);
      raws.forEach((name, value) {
        final field = channels.channelNamed(name)! as IniScalarField;
        final offset = field.offset!;
        switch (field.type) {
          case IniDataType.u08:
            view.setUint8(offset, value);
          case IniDataType.s08:
            view.setInt8(offset, value);
          case IniDataType.u16:
            view.setUint16(offset, value, Endian.little);
          case IniDataType.s16:
            view.setInt16(offset, value, Endian.little);
          case IniDataType.u32:
          case IniDataType.s32:
          case IniDataType.f32:
            throw UnsupportedError('not needed by this test');
        }
      });
      return block;
    }

    test('every computed channel in the file compiles', () {
      final decoder = RealtimeDecoder(doc.outputChannels);
      expect(decoder.unsupportedChannels, isEmpty,
          reason: 'unparsed: ${decoder.unsupportedChannels}');
    });

    test('decodes the primary dashboard channels', () {
      final decoder = RealtimeDecoder(doc.outputChannels);
      final snapshot = decoder.decode(blockWith({
        'rpm': 3500,
        'map': 95,
        'batteryVoltage': 138, // scale 0.1
        'tps': 84, // scale 0.5
        'afr': 147, // scale 0.1
        'advance': 22,
        'coolantRaw': 130, // offset by 40
        'iatRaw': 65,
      }));

      expect(snapshot['rpm'], 3500);
      expect(snapshot['map'], 95);
      expect(snapshot['batteryVoltage'], closeTo(13.8, 1e-9));
      expect(snapshot['tps'], closeTo(42, 1e-9));
      expect(snapshot['afr'], closeTo(14.7, 1e-9));
      expect(snapshot['advance'], 22);

      // These exist only as expressions - the ECU never sends them.
      expect(snapshot['coolant'], 90);
      expect(snapshot['iat'], 25);
    });

    test('computes derived values a dashboard shows', () {
      final decoder = RealtimeDecoder(doc.outputChannels);
      final snapshot = decoder.decode(blockWith({'rpm': 6000}));

      expect(snapshot['revolutionTime'], closeTo(10, 1e-9));
      expect(snapshot['MAPxRPM'], isNotNull);
    });

    test('reads zero rpm without dividing by zero', () {
      final decoder = RealtimeDecoder(doc.outputChannels);
      final snapshot = decoder.decode(blockWith({'rpm': 0}));

      expect(snapshot['rpm'], 0);
      expect(snapshot['revolutionTime'], 0);
      expect(snapshot['dutyCycle'], 0);
    });

    test('CELSIUS and Fahrenheit builds decode the same byte differently', () {
      final candidates = [
        File('packages/foxtune_ini/test/fixtures/speeduino.ini'),
        File('../foxtune_ini/test/fixtures/speeduino.ini'),
      ];
      final source =
          candidates.firstWhere((f) => f.existsSync()).readAsStringSync();
      final fahrenheit = IniParser().parse(source);

      final metricDecoder = RealtimeDecoder(doc.outputChannels);
      final imperialDecoder = RealtimeDecoder(fahrenheit.outputChannels);
      final block = blockWith({'coolantRaw': 140}); // 100 C

      expect(metricDecoder.decode(block)['coolant'], 100);
      expect(imperialDecoder.decode(block)['coolant'], closeTo(212, 1e-9));
    });
  });
}
