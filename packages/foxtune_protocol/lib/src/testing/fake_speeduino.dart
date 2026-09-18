import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

import '../crc32.dart';
import '../frame.dart';
import '../speeduino_constants.dart';
import 'engine_simulation.dart';

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
    this.channels,
    this.constantResolver,
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

  /// Realtime channel definitions.
  ///
  /// Required only for [simulateEngine]: without them the simulator has no way
  /// to know where a named channel lives in the block, and placing values at
  /// guessed offsets would make the UI look right for the wrong reason.
  final IniOutputChannels? channels;

  /// Supplies values for identifiers that are not realtime channels.
  ///
  /// Needed to invert expression-based scaling. `fuelLoad` - the VE table's
  /// load axis - scales by `{ fuelLoadFeedBack }`, which resolves through a
  /// computed channel to the `algorithm` tune constant. Without a resolver that
  /// channel cannot be written at all, and it keeps whatever filler was in the
  /// block: a nonsense load that pins the live table cursor to the top row.
  final double? Function(String name)? constantResolver;

  /// Page contents, indexed from 0 for page 1.
  final pages = <Uint8List>[];

  /// The realtime data block.
  late Uint8List realtime;

  /// Payloads received, for assertions.
  final requests = <Uint8List>[];

  /// Pages whose RAM has been written but not yet burned.
  final ramDirty = <int>{};

  /// Pages that have been burned to EEPROM.
  final burnedPages = <int>{};

  /// Number of `busy` replies to send before answering normally.
  int busyRepliesRemaining = 0;

  /// When true, the next response is emitted with a corrupted CRC.
  bool corruptNextResponse = false;

  /// When true, a byte is flipped after each page write.
  ///
  /// Simulates a write that does not land intact, so the verify-before-burn
  /// step can be proven to catch it.
  bool mutateAfterWrite = false;

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

  EngineSimulation? _engine;
  Timer? _engineTimer;

  /// Set while resolving, so a computed channel can recurse into the resolver.
  double? Function(String)? resolveRef;

  /// Simulated channels that could not be written because their scale could
  /// not be resolved. Reported rather than left as silent stale filler.
  final unresolvedChannels = <String>{};

  /// Whether the realtime block is being driven by a simulated engine.
  bool get isSimulatingEngine => _engine != null;

  /// Starts writing a running engine into the realtime block.
  ///
  /// Requires [channels]; throws [StateError] otherwise rather than silently
  /// producing a block of zeroes that looks like a stalled engine.
  void simulateEngine({
    EngineSimulation? simulation,
    Duration tick = const Duration(milliseconds: 40),
  }) {
    final definition = channels;
    if (definition == null) {
      throw StateError('simulateEngine() needs the [OutputChannels] '
          'definition; construct FakeSpeeduino with channels:.');
    }
    _engine = simulation ?? EngineSimulation();
    _engineTimer?.cancel();
    _engineTimer = Timer.periodic(tick, (_) => _writeEngineSample());
    _writeEngineSample();
  }

  /// Stops the engine simulation, leaving the last sample in place.
  void stopEngineSimulation() {
    _engineTimer?.cancel();
    _engineTimer = null;
    _engine = null;
  }

  void _writeEngineSample() {
    final engine = _engine;
    final definition = channels;
    if (engine == null || definition == null) return;

    final sample = engine.sample();

    /// Resolves an identifier the same way the decoder will: simulated
    /// channels first, then computed channels, then tune constants.
    double? resolve(String name) {
      final direct = sample[name];
      if (direct != null) return direct;
      final computed = definition.computedNamed(name);
      if (computed != null) {
        final expression = CompiledExpression.tryCompile(computed.expression);
        final result = expression?.evaluate(resolveRef!);
        if (result != null) return result;
      }
      return constantResolver?.call(name);
    }

    resolveRef = resolve;

    double? scalarOf(IniScalarValue scalar) => switch (scalar) {
          IniLiteral(:final value) => value,
          IniExpression(:final source) =>
            CompiledExpression.tryCompile(source)?.evaluate(resolve),
        };

    sample.forEach((name, value) {
      final field = definition.channelNamed(name);

      // Some transmitted values are packed bitfields rather than scalars -
      // nSquirts is one, and computed channels divide by it.
      if (field is IniBitsField) {
        final offset = field.offset;
        if (offset == null || offset >= realtime.length) return;
        final width = field.highBit - field.lowBit + 1;
        final mask = ((1 << width) - 1) << field.lowBit;
        final raw = value.round().clamp(0, (1 << width) - 1);
        realtime[offset] =
            (realtime[offset] & ~mask) | ((raw << field.lowBit) & mask);
        return;
      }

      if (field is! IniScalarField) return;
      final offset = field.offset;
      final scale = scalarOf(field.scale);
      final translate = scalarOf(field.translate);
      if (offset == null || scale == null || translate == null || scale == 0) {
        return;
      }
      _writeScalar(offset, field.type, ((value - translate) / scale).round());
    });

    unresolvedChannels
      ..clear()
      ..addAll([
        for (final name in sample.keys)
          if (definition.channelNamed(name) is IniScalarField &&
              scalarOf((definition.channelNamed(name)! as IniScalarField)
                      .scale) ==
                  null)
            name,
      ]);

    engine.flags().forEach((name, on) {
      final field = definition.channelNamed(name);
      if (field is! IniBitsField) return;
      final offset = field.offset;
      if (offset == null || offset >= realtime.length) return;
      final mask = 1 << field.lowBit;
      realtime[offset] =
          on ? (realtime[offset] | mask) : (realtime[offset] & ~mask);
    });
  }

  void _writeScalar(int offset, IniDataType type, int raw) {
    if (offset + type.bytes > realtime.length) return;
    final view = ByteData.sublistView(realtime);
    // Payload data is little-endian.
    switch (type) {
      case IniDataType.u08:
        view.setUint8(offset, raw.clamp(0, 255));
      case IniDataType.s08:
        view.setInt8(offset, raw.clamp(-128, 127));
      case IniDataType.u16:
        view.setUint16(offset, raw.clamp(0, 65535), Endian.little);
      case IniDataType.s16:
        view.setInt16(offset, raw.clamp(-32768, 32767), Endian.little);
      case IniDataType.u32:
        view.setUint32(offset, raw.clamp(0, 4294967295), Endian.little);
      case IniDataType.s32:
        view.setInt32(offset, raw, Endian.little);
      case IniDataType.f32:
        view.setFloat32(offset, raw.toDouble(), Endian.little);
    }
  }

  Future<void> stop() async {
    stopEngineSimulation();
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

      case SpeeduinoCommand.pageWrite:
        // 'M', page LE, offset LE, count LE, then the data.
        if (payload.length < 7) {
          _reply(socket, [0x84]);
          return;
        }
        final wPage = payload[1] | (payload[2] << 8);
        final wOffset = payload[3] | (payload[4] << 8);
        final wCount = payload[5] | (payload[6] << 8);
        if (wPage < 1 || wPage > pages.length) {
          _reply(socket, [0x84]);
          return;
        }
        final target = pages[wPage - 1];
        if (wCount > blockingFactor ||
            wOffset + wCount > target.length ||
            payload.length < 7 + wCount) {
          _reply(socket, [0x84]);
          return;
        }
        target.setRange(wOffset, wOffset + wCount, payload.sublist(7));
        if (mutateAfterWrite) target[wOffset] ^= 0xFF;
        ramDirty.add(wPage);
        _reply(socket, [0x00]);

      case SpeeduinoCommand.burn:
      case SpeeduinoCommand.burnCompat:
        if (payload.length < 3) {
          _reply(socket, [0x84]);
          return;
        }
        final bPage = payload[1] | (payload[2] << 8);
        if (bPage < 1 || bPage > pages.length) {
          _reply(socket, [0x84]);
          return;
        }
        // A burn commits RAM to EEPROM; the simulator records that it happened
        // so a test can assert nothing was persisted without one.
        burnedPages.add(bPage);
        ramDirty.remove(bPage);
        _reply(socket, [0x04]); // SERIAL_RC_BURN_OK

      case SpeeduinoCommand.pageCrc:
        if (payload.length < 3) {
          _reply(socket, [0x84]);
          return;
        }
        final cPage = payload[1] | (payload[2] << 8);
        if (cPage < 1 || cPage > pages.length) {
          _reply(socket, [0x84]);
          return;
        }
        final crc = crc32(pages[cPage - 1]);
        _reply(socket, [
          0x00,
          (crc >> 24) & 0xFF,
          (crc >> 16) & 0xFF,
          (crc >> 8) & 0xFF,
          crc & 0xFF,
        ]);

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
