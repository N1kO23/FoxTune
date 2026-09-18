import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// Coverage for the parts of the transport layer that do not need a device.
///
/// The desktop serial path itself cannot be exercised here: libserialport
/// rejects pseudo-terminals (`sp_get_port_by_name` returns EINVAL for
/// `/dev/pts/*`), so a socat loopback is not usable as a stand-in for a real
/// port. Protocol coverage over a real byte stream lives in
/// `foxtune_protocol`'s socket integration tests instead; the serial driver
/// itself needs hardware or a tty0tty-style kernel module.
void main() {
  group('EcuPort', () {
    test('labels a port with its description when there is one', () {
      const port =
          EcuPort(address: '/dev/ttyACM0', description: 'Arduino Mega');
      expect(port.label, '/dev/ttyACM0 - Arduino Mega');
    });

    test('falls back to the bare address', () {
      const port = EcuPort(address: '/dev/ttyUSB0');
      expect(port.label, '/dev/ttyUSB0');
      expect(const EcuPort(address: '/dev/ttyUSB0', description: '').label,
          '/dev/ttyUSB0');
    });

    test('recognises common ECU USB vendors', () {
      for (final vid in const [
        0x2341,
        0x1A86,
        0x0403,
        0x10C4,
        0x1EAF,
        0x0483,
        0x16C0
      ]) {
        expect(EcuPort(address: 'x', vendorId: vid).isLikelyEcu, isTrue,
            reason: 'vendor 0x${vid.toRadixString(16)}');
      }
    });

    test('treats an unknown or absent vendor as merely unrecognised', () {
      // This is a sorting hint only - nothing may be hidden on this basis,
      // because plenty of valid setups use adapters not on the list.
      expect(
          const EcuPort(address: 'x', vendorId: 0x9999).isLikelyEcu, isFalse);
      expect(const EcuPort(address: 'x').isLikelyEcu, isFalse);
    });
  });

  group('SerialPortTransport', () {
    test('lists ports without throwing, and sorts likely ECUs first', () async {
      final transport = SerialPortTransport();
      // May legitimately be empty on a machine with no serial hardware; the
      // contract is that enumeration succeeds either way.
      final ports = await transport.listPorts();

      final firstOther = ports.indexWhere((p) => !p.isLikelyEcu);
      final lastLikely = ports.lastIndexWhere((p) => p.isLikelyEcu);
      if (firstOther >= 0 && lastLikely >= 0) {
        expect(lastLikely, lessThan(firstOther),
            reason: 'likely ECUs must sort ahead of other ports');
      }
    }, skip: 'requires libserialport on the host library path');
  });
}
