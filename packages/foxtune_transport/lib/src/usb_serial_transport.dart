import 'dart:async';
import 'dart:typed_data';

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:usb_serial/usb_serial.dart';

import 'ecu_transport.dart';

/// Android USB host (OTG) transport.
///
/// This is the path that makes FoxTune useful without a laptop: a phone plugged
/// straight into the ECU with an OTG cable.
class UsbSerialTransport implements EcuTransport {
  @override
  String get name => 'usb_serial (Android USB host)';

  @override
  Future<List<EcuPort>> listPorts() async {
    final devices = await UsbSerial.listDevices();
    final ports = [
      for (final device in devices)
        EcuPort(
          address: device.deviceName,
          description: device.productName,
          manufacturer: device.manufacturerName,
          vendorId: device.vid,
          productId: device.pid,
        ),
    ];
    ports.sort((a, b) {
      if (a.isLikelyEcu == b.isLikelyEcu) return a.address.compareTo(b.address);
      return a.isLikelyEcu ? -1 : 1;
    });
    return ports;
  }

  @override
  Future<EcuLink> open(EcuPort port,
      {int baudRate = kSpeeduinoBaudRate}) async {
    final devices = await UsbSerial.listDevices();
    final device =
        devices.where((d) => d.deviceName == port.address).firstOrNull;
    if (device == null) {
      throw EcuTransportException('Device is no longer attached', port: port);
    }

    // Android prompts the user for permission here; a refusal surfaces as a
    // null port rather than an exception.
    final usbPort = await device.create();
    if (usbPort == null) {
      throw EcuTransportException(
          'Could not claim the device. USB permission may have been denied.',
          port: port);
    }

    if (!await usbPort.open()) {
      throw EcuTransportException('Could not open the device', port: port);
    }

    await usbPort.setDTR(true);
    await usbPort.setRTS(true);
    await usbPort.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    // As on desktop: asserting DTR resets an Arduino-based board, so give the
    // bootloader time to hand over to the firmware.
    await Future<void>.delayed(const Duration(milliseconds: 1000));

    return _UsbSerialLink(usbPort, port.label);
  }
}

class _UsbSerialLink implements EcuLink {
  _UsbSerialLink(this._port, this.description) {
    final input = _port.inputStream;
    if (input == null) {
      throw EcuTransportException('Device provided no input stream');
    }
    _subscription = input.listen(
      _controller.add,
      onError: _controller.addError,
    );
  }

  final UsbPort _port;
  late final StreamSubscription<Uint8List> _subscription;
  final _controller = StreamController<List<int>>.broadcast();

  bool _open = true;

  @override
  final String description;

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isOpen => _open;

  @override
  void send(List<int> bytes) {
    if (!_open) throw StateError('send() on a closed link');
    _port.write(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _subscription.cancel();
    await _port.close();
    await _controller.close();
  }
}
