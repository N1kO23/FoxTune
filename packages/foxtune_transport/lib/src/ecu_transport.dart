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

  /// USB vendor IDs of the boards and adapters Speeduino commonly runs on.
  ///
  /// The Android app's `res/xml/device_filter.xml` lists the same IDs, so that
  /// plugging one of these in offers to open FoxTune. A test keeps the two
  /// lists in step.
  static const knownEcuVendorIds = {
    0x2341, // Arduino
    0x1A86, // CH340/CH341 clones
    0x0403, // FTDI
    0x10C4, // Silicon Labs CP210x
    0x1EAF, // Leaflabs Maple / STM32
    0x0483, // STMicroelectronics
    0x16C0, // Teensy
  };

  /// Whether this port looks like a board Speeduino runs on.
  ///
  /// A hint for sorting a picker, never a gate: plenty of valid setups use
  /// adapters this does not recognise, so nothing is hidden on this basis.
  bool get isLikelyEcu {
    final vid = vendorId;
    return vid != null && knownEcuVendorIds.contains(vid);
  }

  @override
  String toString() => 'EcuPort($label)';
}

/// A port was plugged in or unplugged.
class EcuPortEvent {
  const EcuPortEvent.attached(this.address) : attached = true;

  const EcuPortEvent.detached(this.address) : attached = false;

  /// The port's address, matching [EcuPort.address], where the platform
  /// reports which device it was.
  final String? address;

  /// Whether the port appeared rather than went away.
  final bool attached;

  @override
  String toString() =>
      'EcuPortEvent(${attached ? 'attached' : 'detached'} $address)';
}

/// How long a serial port is left to settle after opening, by default.
///
/// Opening a port asserts DTR, which resets an Arduino-based board: its
/// bootloader runs for about a second before the firmware answers, and talking
/// to it instead yields silence or garbage. Speeduino's definition asks for the
/// same with `delayAfterPortOpen=1000` - but the port is open before any
/// definition is known, so the wait cannot come from there.
const kDelayAfterPortOpen = Duration(milliseconds: 1000);

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

  /// Ports being plugged in and unplugged, where the platform reports it.
  ///
  /// Android does, through USB host broadcasts: that is what lets the port
  /// list refresh itself and a pulled cable be noticed straight away. Desktop
  /// serial offers no such notification, so there this stays empty and the
  /// list has a refresh button instead.
  Stream<EcuPortEvent> get portEvents;

  /// Opens [port] and returns a link ready for [EcuClient].
  ///
  /// A serial port is set to [baudRate], and left [delayAfterOpen] to settle
  /// before the link is handed over - see [kDelayAfterPortOpen]. Neither means
  /// anything to a network link, whose bridge owns the serial side.
  ///
  /// The caller owns the returned link and must close it.
  Future<EcuLink> open(
    EcuPort port, {
    int baudRate = kSpeeduinoBaudRate,
    Duration delayAfterOpen = kDelayAfterPortOpen,
  });
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
