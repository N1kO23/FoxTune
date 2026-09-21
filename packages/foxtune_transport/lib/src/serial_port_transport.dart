import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import 'ecu_transport.dart';

/// Desktop serial transport, backed by libserialport.
///
/// Covers Linux, Windows and macOS.
class SerialPortTransport implements EcuTransport {
  @override
  String get name => 'libserialport';

  /// libserialport has no attach notification; the port list is refreshed
  /// by hand instead.
  @override
  Stream<EcuPortEvent> get portEvents => const Stream.empty();

  @override
  Future<List<EcuPort>> listPorts() async {
    final ports = <EcuPort>[];
    for (final address in SerialPort.availablePorts) {
      final port = SerialPort(address);
      try {
        ports.add(EcuPort(
          address: address,
          description: _safe(() => port.description),
          manufacturer: _safe(() => port.manufacturer),
          vendorId: _safe(() => port.vendorId),
          productId: _safe(() => port.productId),
        ));
      } finally {
        port.dispose();
      }
    }
    // Surface likely ECUs first without hiding anything else.
    ports.sort((a, b) {
      if (a.isLikelyEcu == b.isLikelyEcu) return a.address.compareTo(b.address);
      return a.isLikelyEcu ? -1 : 1;
    });
    return ports;
  }

  @override
  Future<EcuLink> open(EcuPort port,
      {int baudRate = kSpeeduinoBaudRate}) async {
    final serial = SerialPort(port.address);
    if (!serial.openReadWrite()) {
      serial.dispose();
      throw EcuTransportException(
          'Could not open port: ${SerialPort.lastError}',
          port: port);
    }

    try {
      serial.config = SerialPortConfig()
        ..baudRate = baudRate
        ..bits = 8
        ..parity = SerialPortParity.none
        ..stopBits = 1
        ..setFlowControl(SerialPortFlowControl.none);
    } on Object catch (e) {
      serial.close();
      serial.dispose();
      throw EcuTransportException('Could not configure port: $e', port: port);
    }

    // Opening a port asserts DTR, which resets an Arduino-based board. The
    // .ini's delayAfterPortOpen exists for exactly this: talking to the
    // bootloader instead of the firmware yields silence or garbage.
    await Future<void>.delayed(const Duration(milliseconds: 1000));

    return _SerialPortLink(serial, port.address);
  }

  static T? _safe<T>(T? Function() read) {
    try {
      return read();
    } on Object {
      // Drivers vary in which descriptors they expose; a missing one is not
      // a reason to hide the port.
      return null;
    }
  }
}

class _SerialPortLink implements EcuLink {
  _SerialPortLink(this._port, this.description) {
    _reader = SerialPortReader(_port);
    _subscription = _reader.stream.listen(
      _controller.add,
      onError: _controller.addError,
    );
  }

  final SerialPort _port;
  late final SerialPortReader _reader;
  late final StreamSubscription<Uint8List> _subscription;
  final _controller = StreamController<List<int>>.broadcast();

  bool _open = true;

  @override
  final String description;

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isOpen => _open && _port.isOpen;

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
    _reader.close();
    if (_port.isOpen) _port.close();
    _port.dispose();
    await _controller.close();
  }
}
