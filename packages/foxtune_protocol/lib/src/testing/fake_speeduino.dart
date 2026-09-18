import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crc32.dart';
import '../frame.dart';
import '../speeduino_constants.dart';

/// A simulated Speeduino that speaks the real wire protocol over TCP.
///
/// This exists so the whole stack - envelope, CRC, chunking, handshake - can be
/// exercised end to end in CI with no ECU, no serial port and no external
/// simulator binary. It decodes requests exactly as the firmware does, so a
/// framing mistake fails the test rather than passing quietly.
///
/// It is not a behavioural model of an engine: page contents are deterministic
/// filler and realtime values are static.
class FakeSpeeduino {
  FakeSpeeduino({
    this.signature = 'speeduino 202504-dev',
    this.version = 'Speeduino 2025.04-dev',
    this.pageSizes = const [
      128,
      288,
      288,
      128,
      288,
      128,
      240,
      384,
      192,
      192,
      288,
      192,
      128,
      288,
      256
    ],
    this.realtimeBlockSize = 139,
    this.canId = 0,
    this.blockingFactor = 251,
  }) {
    for (var i = 0; i < pageSizes.length; i++) {
      // Deterministic filler: byte value derives from page and offset, so a
      // misaddressed read is visible in the data rather than silently plausible.
      pages.add(Uint8List.fromList([
        for (var o = 0; o < pageSizes[i]; o++) ((i + 1) * 7 + o) & 0xFF,
      ]));
    }
    realtime = Uint8List.fromList(
        [for (var i = 0; i < realtimeBlockSize; i++) (i * 3) & 0xFF]);
  }

  final String signature;
  final String version;
  final List<int> pageSizes;
  final int realtimeBlockSize;
  final int canId;

  /// Largest payload this ECU will serve in one read. A request for more is
  /// answered with a range error, exactly as an over-large real request fails.
  final int blockingFactor;

  /// Page contents, indexed from 0 for page 1.
  final pages = <Uint8List>[];

  /// The realtime data block.
  late Uint8List realtime;

  /// Payloads received, for assertions.
  final requests = <Uint8List>[];

  /// Number of `busy` replies to send before answering normally.
  int busyRepliesRemaining = 0;

  /// When true, the next response is emitted with a corrupted CRC.
  bool corruptNextResponse = false;

  ServerSocket? _server;
  final _clients = <Socket>[];

  /// The port the simulator is listening on.
  int get port => _server?.port ?? -1;

  /// Starts listening on [host]. Port 0 picks a free port.
  Future<int> start({String host = '127.0.0.1', int port = 0}) async {
    final server = await ServerSocket.bind(host, port);
    _server = server;
    server.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      _clients.add(socket);
      final buffer = BytesBuilder(copy: false);
      socket.listen(
        (chunk) => _consume(socket, buffer, chunk),
        onError: (_) {},
        onDone: () => _clients.remove(socket),
      );
    });
    return server.port;
  }

  Future<void> stop() async {
    for (final socket in [..._clients]) {
      socket.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }

  void _consume(Socket socket, BytesBuilder buffer, List<int> chunk) {
    buffer.add(chunk);
    final data = buffer.toBytes();
    var consumed = 0;

    while (data.length - consumed >= 2) {
      final length =
          ByteData.view(data.buffer, data.offsetInBytes + consumed, 2)
              .getUint16(0, Endian.big);
      if (data.length - consumed < 2 + length + 4) break;

      final start = consumed + 2;
      final payload = Uint8List.fromList(
          Uint8List.sublistView(data, start, start + length));
      final crc =
          ByteData.view(data.buffer, data.offsetInBytes + start + length, 4)
              .getUint32(0, Endian.big);
      consumed += 2 + length + 4;

      if (crc32(payload) != crc) {
        _reply(socket, [0x82]); // SERIAL_RC_CRC_ERR
        continue;
      }
      requests.add(payload);
      _handle(socket, payload);
    }

    if (consumed > 0) {
      final rest = data.sublist(consumed);
      buffer
        ..clear()
        ..add(rest);
    }
  }

  void _handle(Socket socket, Uint8List payload) {
    if (busyRepliesRemaining > 0) {
      busyRepliesRemaining--;
      _reply(socket, [0x85]);
      return;
    }
    if (payload.isEmpty) {
      _reply(socket, [0x83]);
      return;
    }

    switch (payload[0]) {
      case SpeeduinoCommand.signature:
        _reply(socket, [0x00, ...ascii.encode(signature)]);

      case SpeeduinoCommand.query:
        _reply(socket, [0x00, ...ascii.encode(version)]);

      case SpeeduinoCommand.pageRead:
        if (payload.length < 7) {
          _reply(socket, [0x84]);
          return;
        }
        final page = payload[1] | (payload[2] << 8);
        final offset = payload[3] | (payload[4] << 8);
        final count = payload[5] | (payload[6] << 8);
        if (page < 1 || page > pages.length) {
          _reply(socket, [0x84]);
          return;
        }
        final contents = pages[page - 1];
        if (count > blockingFactor || offset + count > contents.length) {
          _reply(socket, [0x84]);
          return;
        }
        _reply(socket, [0x00, ...contents.sublist(offset, offset + count)]);

      case SpeeduinoCommand.realtime:
        // 'r', canId, 0x30, offset LE, count LE
        if (payload.length < 7 ||
            payload[1] != canId ||
            payload[2] != SpeeduinoCommand.realtimeSubCommand) {
          _reply(socket, [0x83]);
          return;
        }
        final offset = payload[3] | (payload[4] << 8);
        final count = payload[5] | (payload[6] << 8);
        if (offset + count > realtime.length) {
          _reply(socket, [0x84]);
          return;
        }
        _reply(socket, [0x00, ...realtime.sublist(offset, offset + count)]);

      default:
        _reply(socket, [0x83]); // SERIAL_RC_UKWN_ERR
    }
  }

  void _reply(Socket socket, List<int> payload) {
    final frame = EcuFrame.encode(payload);
    if (corruptNextResponse) {
      corruptNextResponse = false;
      frame[frame.length - 1] ^= 0xFF;
    }
    socket.add(frame);
  }
}
