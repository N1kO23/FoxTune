import 'dart:async';

/// A bidirectional byte pipe to an ECU.
///
/// This is the seam between the protocol codec and the outside world. Nothing
/// above this interface knows whether the bytes arrive over USB serial, USB
/// OTG, a TCP socket or a BLE characteristic, which is what keeps the codec
/// pure Dart and testable without hardware.
///
/// Implementations live in `foxtune_transport` (Flutter) or, for tests, in
/// [FakeEcuLink] below.
abstract class EcuLink {
  /// Bytes arriving from the ECU, in arrival order.
  ///
  /// Chunk boundaries are meaningless - a single logical response may be split
  /// across several events, and several responses may arrive in one event. The
  /// framing layer is responsible for reassembly.
  Stream<List<int>> get incoming;

  /// Whether the link is currently open.
  bool get isOpen;

  /// A human-readable identifier for the endpoint, e.g. `/dev/ttyACM0`.
  String get description;

  /// Queues [bytes] for transmission to the ECU.
  void send(List<int> bytes);

  /// Closes the link and releases the underlying resource.
  ///
  /// Safe to call more than once.
  Future<void> close();
}

/// An in-memory [EcuLink] for tests.
///
/// [sent] accumulates everything the codec transmitted, and [deliver] pushes
/// bytes back as though the ECU had replied. This is what lets the whole
/// protocol layer be exercised in CI with no serial port present.
class FakeEcuLink implements EcuLink {
  final _controller = StreamController<List<int>>.broadcast();

  /// Every byte passed to [send], flattened in order.
  final List<int> sent = <int>[];

  bool _open = true;

  @override
  Stream<List<int>> get incoming => _controller.stream;

  @override
  bool get isOpen => _open;

  @override
  String get description => 'fake';

  @override
  void send(List<int> bytes) {
    if (!_open) {
      throw StateError('send() on a closed FakeEcuLink');
    }
    sent.addAll(bytes);
  }

  /// Simulates [bytes] arriving from the ECU.
  void deliver(List<int> bytes) {
    if (!_open) {
      throw StateError('deliver() on a closed FakeEcuLink');
    }
    _controller.add(bytes);
  }

  /// Discards everything recorded in [sent].
  void clearSent() => sent.clear();

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _controller.close();
  }
}
