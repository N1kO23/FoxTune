import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'ecu_link.dart';

/// An [EcuLink] over a TCP socket.
///
/// This is how a Speeduino is reached through an ESP8266/ESP32 bridge on its
/// secondary serial port. It needs no native plugin, which makes it the only
/// route that also works on iOS - and it lets the whole protocol stack be
/// integration-tested against a simulated ECU with no serial hardware.
class SocketEcuLink implements EcuLink {
  SocketEcuLink._(this._socket, this.description) {
    _subscription = _socket.listen(
      _controller.add,
      onError: _controller.addError,
      onDone: () => unawaited(close()),
    );
  }

  /// Connects to an ECU bridge at [host]:[port].
  static Future<SocketEcuLink> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Ownership transfers to the returned link, which destroys the socket in
    // close(); the analyzer cannot see across that hand-off.
    // ignore: close_sinks
    final socket = await Socket.connect(host, port, timeout: timeout);
    // Telemetry arrives in small frequent bursts; Nagle's algorithm would add
    // latency waiting to coalesce them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    return SocketEcuLink._(socket, '$host:$port');
  }

  final Socket _socket;
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
    _socket.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _subscription.cancel();
    _socket.destroy();
    await _controller.close();
  }
}
