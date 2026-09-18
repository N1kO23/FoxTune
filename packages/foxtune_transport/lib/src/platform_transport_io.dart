import 'dart:io';

import 'ecu_transport.dart';
import 'serial_port_transport.dart';
import 'usb_serial_transport.dart';

/// Chooses the transport for the host platform.
EcuTransport createPlatformTransport() {
  if (Platform.isAndroid) return UsbSerialTransport();
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    return SerialPortTransport();
  }
  if (Platform.isIOS) {
    throw UnsupportedError(
      'iOS provides no generic USB serial API, and the External Accessory '
      'framework requires Apple MFi licensing. Reaching a Speeduino from iOS '
      'needs a WiFi (ESP8266/ESP32) or BLE bridge.',
    );
  }
  throw UnsupportedError('No ECU transport for ${Platform.operatingSystem}');
}
