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

    test('maps the two success codes', () {
      expect(SerialResponse.fromByte(0x04), SerialResponse.burnOk);
      expect(SerialResponse.fromByte(0x85), SerialResponse.busy);
    });

    test('ok and burnOk count as success, nothing else does', () {
      const successes = {SerialResponse.ok, SerialResponse.burnOk};
      for (final value in SerialResponse.values) {
        expect(value.isOk, successes.contains(value), reason: value.name);
      }
    });

    test('only busy is retryable', () {
      // Retrying a range error would loop forever; the firmware will never
      // accept it. Only busy is a transient condition.
      for (final value in SerialResponse.values) {
        expect(value.isRetryable, value == SerialResponse.busy,
            reason: value.name);
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
