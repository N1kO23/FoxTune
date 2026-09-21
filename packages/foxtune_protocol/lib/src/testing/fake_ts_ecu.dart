import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

import '../crc32.dart';
import '../frame.dart';
import 'engine_simulation.dart';

/// A simulated ECU that speaks the TunerStudio wire protocol over TCP.
///
/// The envelope - length, payload, CRC-32 - and everything around it are the
/// same for every firmware: listening, framing, page memory, and writing a
/// simulated engine into the realtime block. What differs is how each
/// firmware reads the commands inside the envelope, which is left to
/// [handleCommand] in a subclass - `FakeSpeeduino`, `FakeRusEfi`.
///
/// This exists so the whole stack can be exercised end to end in CI with no
/// ECU, no serial port and no external simulator binary. A subclass decodes
/// requests exactly as its firmware does, so a framing or addressing mistake
/// fails the test rather than passing quietly.
abstract class FakeTsEcu {
  FakeTsEcu({
    required this.signature,
    required this.version,
    required this.pageSizes,
    required this.realtimeBlockSize,
    required this.blockingFactor,
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

  /// What the ECU answers its signature query with.
  final String signature;

  /// The human-readable version string.
  final String version;

  final List<int> pageSizes;
  final int realtimeBlockSize;

  /// Largest payload this ECU will serve in one transfer. A request for more
  /// is answered with a range error, exactly as an over-large real request
  /// fails.
  final int blockingFactor;

  /// Realtime channel definitions.
  ///
  /// Required only for [simulateEngine]: without them the simulator has no way
  /// to know where a named channel lives in the block, and placing values at
  /// guessed offsets would make the UI look right for the wrong reason.
  final IniOutputChannels? channels;

  /// Supplies values for identifiers that are not realtime channels.
  ///
  /// Needed to invert expression-based scaling. Speeduino's `fuelLoad` scales
  /// by `{ fuelLoadFeedBack }`, which resolves through a computed channel to
  /// the `algorithm` tune constant. Without a resolver that channel cannot be
  /// written at all.
  final double? Function(String name)? constantResolver;

  /// Page contents, indexed from 0 for page 1.
  final pages = <Uint8List>[];

  /// The realtime data block.
  late Uint8List realtime;

  /// Payloads received, for assertions.
  final requests = <Uint8List>[];

  /// Pages whose RAM has been written but not yet burned.
  final ramDirty = <int>{};

  /// Pages that have been burned to permanent storage.
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

  Future<void> stop() async {
    stopEngineSimulation();
    for (final socket in [..._clients]) {
      socket.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }

  // --- Commands --------------------------------------------------------------

  /// Answers one request, as this firmware does.
  void handleCommand(Socket socket, Uint8List payload);

  /// Sends [payload] - a status byte and any data - in an envelope.
  void reply(Socket socket, List<int> payload) {
    final frame = EcuFrame.encode(payload);
    if (corruptNextResponse) {
      corruptNextResponse = false;
      frame[frame.length - 1] ^= 0xFF;
    }
    socket.add(frame);
  }

  /// Replies with a CRC-32 in the envelope's byte order.
  void replyCrc(Socket socket, int crc) => reply(socket, [
        0x00,
        (crc >> 24) & 0xFF,
        (crc >> 16) & 0xFF,
        (crc >> 8) & 0xFF,
        crc & 0xFF,
      ]);

  /// Writes [data] into [page] (from 1) at [offset], as a RAM write does.
  void writeToPage(int page, int offset, List<int> data) {
    final target = pages[page - 1];
    target.setRange(offset, offset + data.length, data);
    if (mutateAfterWrite && data.isNotEmpty) target[offset] ^= 0xFF;
    ramDirty.add(page);
  }

  /// Records a burn of [page] (from 1).
  void burn(int page) {
    burnedPages.add(page);
    ramDirty.remove(page);
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
        reply(socket, [0x82]); // CRC failure
        continue;
      }
      requests.add(payload);
      if (busyRepliesRemaining > 0) {
        busyRepliesRemaining--;
        reply(socket, [0x85]);
        continue;
      }
      if (payload.isEmpty) {
        reply(socket, [0x83]);
        continue;
      }
      handleCommand(socket, payload);
    }

    if (consumed > 0) {
      final rest = data.sublist(consumed);
      buffer
        ..clear()
        ..add(rest);
    }
  }

  // --- Engine simulation ---------------------------------------------------

  EngineSimulation? _engine;
  Timer? _engineTimer;

  /// Set while resolving, so a computed channel can recurse into the resolver.
  double? Function(String)? resolveRef;

  /// Simulated channels that could not be written because their scale could
  /// not be resolved. Reported rather than left as silent stale filler.
  final unresolvedChannels = <String>{};

  /// Whether the realtime block is being driven by a simulated engine.
  bool get isSimulatingEngine => _engine != null;

  /// The channel values to write for one instant of [engine].
  ///
  /// The simulation names channels as Speeduino's definition does; a firmware
  /// that names them otherwise renames them here.
  Map<String, double> channelValues(
    EngineSimulation engine,
    EngineConditions now,
  ) =>
      engine.sampleAt(now);

  /// The status flags to write for one instant of [engine].
  Map<String, bool> flagValues(EngineSimulation engine, EngineConditions now) =>
      engine.flagsAt(now);

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
          'definition; construct the fake with channels:.');
    }
    _engine = simulation ?? EngineSimulation();
    // The test pattern goes: it exists to expose a misaddressed read, and
    // under a running engine it decodes as nonsense - a 16-bit channel the
    // simulation leaves alone reads two pattern bytes, which is how gamma
    // enrichment came to show 13875%. A real ECU reports zero for what it is
    // not doing, so channels the simulation does not drive read zero too.
    realtime.fillRange(0, realtime.length, 0);
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

    // One instant, asked for once: a model that integrates state - a closed
    // fuelling loop, say - must not be stepped twice per tick.
    final now = engine.conditions();
    final sample = channelValues(engine, now);

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
      // Speeduino's nSquirts is one, and computed channels divide by it.
      if (field is IniBitsField) {
        _writeBits(field, value.round());
        return;
      }

      if (field is! IniScalarField) return;
      final offset = field.offset;
      final scale = scalarOf(field.scale);
      final translate = scalarOf(field.translate);
      if (offset == null || scale == null || translate == null || scale == 0) {
        return;
      }
      _writeScalar(offset, field.type, (value - translate) / scale);
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

    flagValues(engine, now).forEach((name, on) {
      final field = definition.channelNamed(name);
      if (field is IniBitsField) _writeBits(field, on ? 1 : 0);
    });
  }

  /// Writes [value] into [field]'s bits, leaving the rest of its word alone.
  ///
  /// The whole word, not one byte: rusEFI packs its status flags into 32-bit
  /// words, so bit 20 lives two bytes past the field's offset.
  void _writeBits(IniBitsField field, int value) {
    final offset = field.offset;
    final bytes = field.type.bytes;
    if (offset == null || offset + bytes > realtime.length) return;
    var word = 0;
    for (var i = 0; i < bytes; i++) {
      word |= realtime[offset + i] << (8 * i);
    }
    final width = field.highBit - field.lowBit + 1;
    final mask = ((1 << width) - 1) << field.lowBit;
    final raw = value.clamp(0, (1 << width) - 1);
    word = (word & ~mask) | ((raw << field.lowBit) & mask);
    for (var i = 0; i < bytes; i++) {
      realtime[offset + i] = (word >> (8 * i)) & 0xFF;
    }
  }

  /// Writes an unscaled value. Floats are written as they are; integer
  /// types are rounded and clamped to what they hold.
  void _writeScalar(int offset, IniDataType type, double raw) {
    if (offset + type.bytes > realtime.length) return;
    final view = ByteData.sublistView(realtime);
    final whole = raw.round();
    // Payload data is little-endian.
    switch (type) {
      case IniDataType.u08:
        view.setUint8(offset, whole.clamp(0, 255));
      case IniDataType.s08:
        view.setInt8(offset, whole.clamp(-128, 127));
      case IniDataType.u16:
        view.setUint16(offset, whole.clamp(0, 65535), Endian.little);
      case IniDataType.s16:
        view.setInt16(offset, whole.clamp(-32768, 32767), Endian.little);
      case IniDataType.u32:
        view.setUint32(offset, whole.clamp(0, 4294967295), Endian.little);
      case IniDataType.s32:
        view.setInt32(
          offset,
          whole.clamp(-2147483648, 2147483647),
          Endian.little,
        );
      case IniDataType.f32:
        view.setFloat32(offset, raw, Endian.little);
    }
  }
}
