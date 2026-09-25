import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';

import 'ecu_transport.dart';

/// Reaches an ECU over TCP.
///
/// This is how a Speeduino is reached through an ESP8266/ESP32 bridge on its
/// secondary serial port. It needs no native plugin, so it is the one transport
/// that works on every platform - including iOS, where generic USB serial is
/// not available at all.
///
/// There is nothing to enumerate: the user supplies an address, so
/// [listPorts] returns empty and [open] takes `host:port`.
class TcpEcuTransport implements EcuTransport {
  const TcpEcuTransport({this.defaultPort = 2000});

  /// Port assumed when an address omits one.
  ///
  /// 2000 is the convention for ESP-based serial bridges.
  final int defaultPort;

  @override
  String get name => 'TCP (WiFi bridge)';

  /// Network endpoints cannot be discovered, so this is always empty.
  @override
  Future<List<EcuPort>> listPorts() async => const [];

  /// A network endpoint is never plugged in, so nothing is reported.
  @override
  Stream<EcuPortEvent> get portEvents => const Stream.empty();

  /// Builds a port from a `host` or `host:port` string.
  EcuPort portFor(String address) =>
      EcuPort(address: address.trim(), description: 'Network ECU');

  @override
  Future<EcuLink> open(
    EcuPort port, {
    int baudRate = kSpeeduinoBaudRate,
    Duration delayAfterOpen = kDelayAfterPortOpen,
  }) async {
    // Both are meaningless over TCP; the bridge owns the serial side.
    final (host, tcpPort) = parseAddress(port.address, defaultPort);
    try {
      return await SocketEcuLink.connect(host, tcpPort);
    } on Object catch (error) {
      throw EcuTransportException('Could not reach $host:$tcpPort - $error',
          port: port);
    }
  }

  /// Splits `host:port`, falling back to [fallbackPort].
  ///
  /// Handles bracketed IPv6 literals, where the colons are part of the host.
  static (String host, int port) parseAddress(
      String address, int fallbackPort) {
    final trimmed = address.trim();

    if (trimmed.startsWith('[')) {
      final close = trimmed.indexOf(']');
      if (close > 0) {
        final host = trimmed.substring(1, close);
        final rest = trimmed.substring(close + 1);
        if (rest.startsWith(':')) {
          return (host, int.tryParse(rest.substring(1)) ?? fallbackPort);
        }
        return (host, fallbackPort);
      }
    }

    final colon = trimmed.lastIndexOf(':');
    if (colon <= 0 ||
        trimmed.contains(':', 0) && trimmed.indexOf(':') != colon) {
      // No port, or a bare IPv6 literal with several colons.
      return (trimmed, fallbackPort);
    }
    final port = int.tryParse(trimmed.substring(colon + 1));
    if (port == null) return (trimmed, fallbackPort);
    return (trimmed.substring(0, colon), port);
  }
}
