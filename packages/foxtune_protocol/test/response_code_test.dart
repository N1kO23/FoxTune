import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('SerialResponse', () {
    test('maps the firmware result bytes', () {
      expect(SerialResponse.fromByte(0x00), SerialResponse.ok);
      expect(SerialResponse.fromByte(0x80), SerialResponse.timeout);
      expect(SerialResponse.fromByte(0x82), SerialResponse.crcError);
      expect(SerialResponse.fromByte(0x83), SerialResponse.unknownCommand);
      expect(SerialResponse.fromByte(0x84), SerialResponse.rangeError);
    });

    test('returns null for an unrecognised byte', () {
      expect(SerialResponse.fromByte(0x7F), isNull);
      expect(SerialResponse.fromByte(0xFF), isNull);
    });

    test('only ok counts as success', () {
      for (final value in SerialResponse.values) {
        expect(value.isOk, value == SerialResponse.ok, reason: value.name);
      }
    });
  });

  group('EcuProtocolException', () {
    test('names the response code when it has one', () {
      final e =
          EcuProtocolException('bad page', response: SerialResponse.rangeError);
      expect(e.toString(), contains('bad page'));
      expect(e.toString(), contains('rangeError'));
    });

    test('reads cleanly without a response code', () {
      expect(EcuProtocolException('no reply').toString(),
          'EcuProtocolException: no reply');
    });
  });
}
