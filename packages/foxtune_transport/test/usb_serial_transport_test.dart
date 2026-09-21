import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

void main() {
  group('USB permission', () {
    test('a denial reads as a denial, not as a bug', () {
      // What the plugin actually sends when the user taps "Deny".
      final message = UsbSerialTransport.describeOpenFailure(
        PlatformException(
          code: 'UsbSerialPortAdapter',
          message: 'Failed to acquire permissions.',
        ),
      );

      expect(message, startsWith('USB permission was denied'));
      expect(message, contains('always'));
    });

    test('any other failure keeps the plugin detail', () {
      final message = UsbSerialTransport.describeOpenFailure(
        PlatformException(code: 'x', message: 'Interface busy'),
      );

      expect(message, 'Could not claim the USB device: Interface busy');
    });
  });

  group('device filter', () {
    test('lists exactly the vendors the port picker treats as likely ECUs', () {
      // Plugging in a board whose vendor is missing from the XML would not
      // offer to open FoxTune; one whose vendor is missing from the Dart set
      // would sort to the bottom of the picker. Either is a quiet mismatch.
      final file = [
        File('../../app/foxtune_app/android/app/src/main/res/xml/'
            'device_filter.xml'),
        File('app/foxtune_app/android/app/src/main/res/xml/'
            'device_filter.xml'),
      ].firstWhere((f) => f.existsSync());

      final declared = RegExp(r'vendor-id="(\d+)"')
          .allMatches(file.readAsStringSync())
          .map((m) => int.parse(m.group(1)!))
          .toSet();

      expect(declared, EcuPort.knownEcuVendorIds);
    });
  });

  group('port events', () {
    test('network and desktop transports report none', () async {
      expect(await const TcpEcuTransport().portEvents.isEmpty, isTrue);
    });
  });
}
