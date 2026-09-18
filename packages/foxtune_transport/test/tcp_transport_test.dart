import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

void main() {
  group('address parsing', () {
    (String, int) parse(String address) =>
        TcpEcuTransport.parseAddress(address, 2000);

    test('splits host and port', () {
      expect(parse('192.168.4.1:3000'), ('192.168.4.1', 3000));
      expect(parse('speeduino.local:1234'), ('speeduino.local', 1234));
    });

    test('falls back to the default port', () {
      expect(parse('192.168.4.1'), ('192.168.4.1', 2000));
      expect(parse('speeduino.local'), ('speeduino.local', 2000));
    });

    test('trims surrounding whitespace', () {
      expect(parse('  10.0.0.5:2000  '), ('10.0.0.5', 2000));
    });

    test('treats a bare IPv6 literal as a host, not host:port', () {
      // The colons belong to the address; splitting on the last one would
      // produce a nonsense host.
      expect(parse('fe80::1'), ('fe80::1', 2000));
    });

    test('honours a bracketed IPv6 literal with a port', () {
      expect(parse('[fe80::1]:2000'), ('fe80::1', 2000));
      expect(parse('[::1]'), ('::1', 2000));
    });

    test('falls back when the port is not a number', () {
      expect(parse('host:abc'), ('host:abc', 2000));
    });
  });

  group('TcpEcuTransport', () {
    test('has nothing to enumerate', () async {
      expect(await const TcpEcuTransport().listPorts(), isEmpty);
    });

    test('reports a clear failure for an unreachable host', () async {
      const transport = TcpEcuTransport();
      await expectLater(
        transport.open(transport.portFor('127.0.0.1:1')),
        throwsA(isA<EcuTransportException>()),
      );
    });
  });
}
