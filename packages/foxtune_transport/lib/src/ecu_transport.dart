import 'package:foxtune_protocol/foxtune_protocol.dart';

import 'platform_transport_stub.dart'
    if (dart.library.io) 'platform_transport_io.dart';

/// A serial endpoint an ECU might be attached to.
class EcuPort {
  const EcuPort({
    required this.address,
    this.description,
    this.manufacturer,
    this.vendorId,
    this.productId,
  });

  /// Platform address: a device path on desktop, a device name on Android.
  final String address;

  /// Human-readable product description, when the driver reports one.
  final String? description;

  /// Manufacturer string, when reported.
  final String? manufacturer;

  /// USB vendor id, when known.
  final int? vendorId;

  /// USB product id, when known.
  final int? productId;

  /// A label suitable for a port picker.
  String get label => description == null || description!.isEmpty
      ? address
      : '$address - $description';

  /// Whether this port looks like a board Speeduino runs on.
  ///
  /// A hint for sorting a picker, never a gate: plenty of valid setups use
  /// adapters this does not recognise, so nothing is hidden on this basis.
  bool get isLikelyEcu {
    final vid = vendorId;
    if (vid == null) return false;
    return const {
      0x2341, // Arduino
      0x1A86, // CH340/CH341 clones
      0x0403, // FTDI
      0x10C4, // Silicon Labs CP210x
      0x1EAF, // Leaflabs Maple / STM32
      0x0483, // STMicroelectronics
      0x16C0, // Teensy
    }.contains(vid);
  }

  @override
  String toString() => 'EcuPort($label)';
}

/// Enumerates serial ports and opens links to them.
///
/// Implementations are platform-specific; obtain the right one with
/// [EcuTransport.forPlatform].
abstract class EcuTransport {
  /// The transport appropriate to the current platform.
  ///
  /// Throws [UnsupportedError] on iOS, which offers no generic USB serial API
  /// at all - reaching a Speeduino there requires a WiFi or BLE bridge, which
  /// will arrive as separate implementations of this same interface.
  static EcuTransport forPlatform() => createPlatformTransport();

  /// Human-readable name of this transport, for diagnostics.
  String get name;

  /// Lists currently attached ports.
  Future<List<EcuPort>> listPorts();

  /// Opens [port] and returns a link ready for [EcuClient].
  ///
  /// The caller owns the returned link and must close it.
  Future<EcuLink> open(EcuPort port, {int baudRate = kSpeeduinoBaudRate});
}

/// Thrown when a port cannot be opened.
class EcuTransportException implements Exception {
  EcuTransportException(this.message, {this.port});

  final String message;
  final EcuPort? port;

  @override
  String toString() => port == null
      ? 'EcuTransportException: $message'
      : 'EcuTransportException: $message (${port!.address})';
}
