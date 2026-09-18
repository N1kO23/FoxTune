/// Flutter implementations of `EcuLink`.
///
/// Desktop (Linux/Windows/macOS) uses libserialport; Android uses USB host
/// mode over OTG. A TCP implementation for the ESP8266/ESP32 WiFi bridge - the
/// only route that also works on iOS - and BLE come later.
///
/// ```dart
/// final transport = EcuTransport.forPlatform();
/// final ports = await transport.listPorts();
/// final link = await transport.open(ports.first);
/// final client = EcuClient(link);
/// final id = await client.identify();
/// ```
library;

export 'src/ecu_transport.dart';
export 'src/serial_port_transport.dart';
export 'src/tcp_transport.dart';
export 'src/usb_serial_transport.dart';
