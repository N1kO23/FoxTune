import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../crc32.dart';
import '../speeduino_constants.dart';
import 'fake_ts_ecu.dart';

/// A simulated Speeduino that speaks the real wire protocol over TCP.
///
/// Decodes requests exactly as the firmware does - the page is the second
/// byte of the identifier, after the CAN id; `Q` answers the signature and `S`
/// the display string - so a client that gets either wrong fails here rather
/// than only against hardware.
///
/// Page contents start as deterministic filler, and realtime values are
/// static until [simulateEngine] drives them.
///
/// It keeps sensor calibrations as the firmware does - saved as they arrive,
/// with the CRC-32 `k` answers - and runs the tooth and composite loggers
/// against a simulated trigger wheel, [triggerTeeth] minus [missingTeeth] at
/// [triggerRpm], with a cam pulse once every other turn.
class FakeSpeeduino extends FakeTsEcu {
  FakeSpeeduino({
    super.signature = 'speeduino 202504-dev',
    super.version = 'Speeduino 2025.04-dev',
    super.pageSizes = const [
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
    super.realtimeBlockSize = 139,
    this.canId = 0,
    super.blockingFactor = 251,
    super.channels,
    super.constantResolver,
  });

  final int canId;

  // --- Sensor calibrations ---------------------------------------------------

  /// Calibration tables as last saved, by number - 0 coolant, 1 air
  /// temperature, 2 O2 - each as it was sent.
  final sensorTables = <int, Uint8List>{};

  /// The CRC-32 kept of each saved table, which `k` answers with.
  final sensorTableCrcs = <int, int>{};

  final _o2Table = Uint8List(1024);

  // --- Loggers ---------------------------------------------------------------

  /// Records in one capture, `TOOTH_LOG_SIZE` in the firmware.
  static const toothLogSize = 127;

  /// The simulated trigger wheel: [triggerTeeth] positions, the last
  /// [missingTeeth] of them without a tooth.
  int triggerTeeth = 36;
  int missingTeeth = 1;

  /// How fast the wheel turns; 0 for an engine that is not turning.
  double triggerRpm = 900;

  /// The command that started the logger now running, or `null`.
  int? runningLogger;

  /// Where the wheel had got to when the current capture began, in edges
  /// since the logger first started.
  int _logPhase = 0;
  DateTime _logStart = DateTime.now();

  /// Page number from a two-byte page identifier, or null if it is malformed.
  ///
  /// Mirrors the firmware exactly: byte 1 is the CAN id and byte 2 is the
  /// page. Accepting a little-endian page number here instead would let a
  /// client that sends one look correct against this simulator while failing
  /// against a real ECU - which is precisely what happened.
  int? _pageFrom(Uint8List payload) {
    if (payload.length < 3) return null;
    if (payload[1] != canId) return null;
    return payload[2];
  }

  @override
  void handleCommand(Socket socket, Uint8List payload) {
    switch (payload[0]) {
      // As the firmware answers them: `Q` with the signature, `S` with the
      // display string (`comms.cpp`, `codeVersion` and `productString`).
      case SpeeduinoCommand.query:
        reply(socket, [0x00, ...ascii.encode(signature)]);

      case SpeeduinoCommand.version:
        reply(socket, [0x00, ...ascii.encode(version)]);

      case SpeeduinoCommand.pageRead:
        if (payload.length < 7) {
          reply(socket, [0x84]);
          return;
        }
        final page = _pageFrom(payload);
        final offset = payload[3] | (payload[4] << 8);
        final count = payload[5] | (payload[6] << 8);
        if (page == null || page < 1 || page > pages.length) {
          reply(socket, [0x84]);
          return;
        }
        final contents = pages[page - 1];
        if (count > blockingFactor || offset + count > contents.length) {
          reply(socket, [0x84]);
          return;
        }
        reply(socket, [0x00, ...contents.sublist(offset, offset + count)]);

      case SpeeduinoCommand.pageWrite:
        // 'M', page LE, offset LE, count LE, then the data.
        if (payload.length < 7) {
          reply(socket, [0x84]);
          return;
        }
        final wPage = _pageFrom(payload);
        final wOffset = payload[3] | (payload[4] << 8);
        final wCount = payload[5] | (payload[6] << 8);
        if (wPage == null || wPage < 1 || wPage > pages.length) {
          reply(socket, [0x84]);
          return;
        }
        final target = pages[wPage - 1];
        if (wCount > blockingFactor ||
            wOffset + wCount > target.length ||
            payload.length < 7 + wCount) {
          reply(socket, [0x84]);
          return;
        }
        writeToPage(wPage, wOffset, payload.sublist(7, 7 + wCount));
        reply(socket, [0x00]);

      case SpeeduinoCommand.burn:
      case SpeeduinoCommand.burnCompat:
        if (payload.length < 3) {
          reply(socket, [0x84]);
          return;
        }
        final bPage = _pageFrom(payload);
        if (bPage == null || bPage < 1 || bPage > pages.length) {
          reply(socket, [0x84]);
          return;
        }
        // A burn commits RAM to EEPROM; the simulator records that it happened
        // so a test can assert nothing was persisted without one.
        burn(bPage);
        reply(socket, [0x04]); // SERIAL_RC_BURN_OK

      case SpeeduinoCommand.pageCrc:
        if (payload.length < 3) {
          reply(socket, [0x84]);
          return;
        }
        final cPage = _pageFrom(payload);
        if (cPage == null || cPage < 1 || cPage > pages.length) {
          reply(socket, [0x84]);
          return;
        }
        replyCrc(socket, crc32(pages[cPage - 1]));

      case SpeeduinoCommand.realtime:
        // 'r', canId, 0x30, offset LE, count LE
        if (payload.length < 7 ||
            payload[1] != canId ||
            payload[2] != SpeeduinoCommand.realtimeSubCommand) {
          reply(socket, [0x83]);
          return;
        }
        final offset = payload[3] | (payload[4] << 8);
        final count = payload[5] | (payload[6] << 8);
        if (offset + count > realtime.length) {
          reply(socket, [0x84]);
          return;
        }
        // status1 bit 6, `toothLog1Ready`: the capture has filled.
        if (realtime.length > 1) {
          realtime[1] =
              _captureFull ? realtime[1] | 0x40 : realtime[1] & ~0x40 & 0xFF;
        }
        reply(socket, [0x00, ...realtime.sublist(offset, offset + count)]);

      case SpeeduinoCommand.tableWrite:
        _writeSensorTable(socket, payload);

      case SpeeduinoCommand.tableCrc:
        if (payload.length < 3) {
          reply(socket, [0x84]);
          return;
        }
        replyCrc(socket, sensorTableCrcs[payload[2]] ?? 0);

      case SpeeduinoCommand.toothLoggerStart ||
            SpeeduinoCommand.compositeLoggerStart ||
            SpeeduinoCommand.compositeLogger2Start ||
            SpeeduinoCommand.compositeLogger3Start:
        runningLogger = payload[0];
        _logStart = DateTime.now();
        reply(socket, [0x00]);

      case SpeeduinoCommand.toothLoggerStop ||
            SpeeduinoCommand.compositeLoggerStop ||
            SpeeduinoCommand.compositeLogger2Stop ||
            SpeeduinoCommand.compositeLogger3Stop:
        runningLogger = null;
        reply(socket, [0x00]);

      case SpeeduinoCommand.loggerRead:
        final logger = runningLogger;
        // With no logger running the firmware sends nothing at all.
        if (logger == null) return;
        final logged = _loggedEdges;
        reply(socket, [
          0x00,
          ...(logger == SpeeduinoCommand.toothLoggerStart
              ? _toothLog(logged)
              : _compositeLog(logged)),
        ]);
        // Reading empties the buffer, and logging starts again.
        _logPhase += logged;
        _logStart = DateTime.now();

      default:
        reply(socket, [0x83]); // SERIAL_RC_UKWN_ERR
    }
  }

  /// `t`: CAN id, table, offset and length high byte first, then the data.
  void _writeSensorTable(Socket socket, Uint8List payload) {
    if (payload.length < 7 || payload[1] != canId) {
      reply(socket, [0x84]);
      return;
    }
    final table = payload[2];
    final offset = (payload[3] << 8) | payload[4];
    final count = (payload[5] << 8) | payload[6];
    if (payload.length < 7 + count) {
      reply(socket, [0x84]);
      return;
    }
    final data = payload.sublist(7, 7 + count);
    switch (table) {
      // A temperature table comes whole, 32 values of two bytes, or not at
      // all.
      case 0 || 1:
        if (count != 64) {
          reply(socket, [0x84]);
          return;
        }
        sensorTables[table] = Uint8List.fromList(data);
        sensorTableCrcs[table] = crc32(data);
      // The O2 table comes in pieces, and is saved with the last of them.
      case 2:
        if (offset + count > _o2Table.length) {
          reply(socket, [0x84]);
          return;
        }
        _o2Table.setRange(offset, offset + count, data);
        if (offset + count >= _o2Table.length) {
          sensorTables[2] = Uint8List.fromList(_o2Table);
          sensorTableCrcs[2] = crc32(_o2Table);
        }
      default:
        reply(socket, [0x84]);
        return;
    }
    reply(socket, [0x00]);
  }

  // --- The simulated trigger wheel -------------------------------------------

  int get _presentTeeth => triggerTeeth - missingTeeth;

  /// Microseconds the wheel takes to turn one degree.
  double get _microsPerDegree => 60e6 / triggerRpm / 360;

  /// Edges the running logger has seen since its capture began: teeth for
  /// the tooth logger, edges on either input for a composite one.
  int get _loggedEdges {
    final logger = runningLogger;
    if (logger == null || triggerRpm <= 0 || _presentTeeth <= 0) return 0;
    final elapsed = DateTime.now().difference(_logStart).inMicroseconds;
    final perRevolution = logger == SpeeduinoCommand.toothLoggerStart
        ? _presentTeeth
        // Both edges of every tooth, and one cam edge a turn on average.
        : 2 * _presentTeeth + 1;
    final edges = elapsed / (_microsPerDegree * 360) * perRevolution;
    return edges >= toothLogSize ? toothLogSize : edges.floor();
  }

  bool get _captureFull => _loggedEdges >= toothLogSize;

  /// The time from each tooth to the next, in microseconds, for [count]
  /// teeth from where the wheel had got to; zeroes after them.
  List<int> _toothLog(int count) {
    final pitch = 360 / triggerTeeth * _microsPerDegree;
    final out = <int>[];
    for (var i = 0; i < toothLogSize; i++) {
      var gap = 0;
      if (i < count) {
        // The first tooth after the gap comes after the missing ones too.
        final tooth = (_logPhase + i) % _presentTeeth;
        gap = (tooth == 0 ? pitch * (missingTeeth + 1) : pitch).round();
      }
      out.addAll(_bigEndian32(gap));
    }
    return out;
  }

  /// [count] edges from where the wheel had got to, each a big-endian time
  /// in microseconds and a byte of flags; then padding, as the firmware
  /// pads - the last time again, no flags.
  List<int> _compositeLog(int count) {
    final events = _cycleEvents();
    final cycleMicros = 720 * _microsPerDegree;
    final out = <int>[];
    var lastTime = 0;
    for (var i = 0; i < toothLogSize; i++) {
      if (i >= count) {
        out
          ..addAll(_bigEndian32(lastTime))
          ..add(0);
        continue;
      }
      final index = _logPhase + i;
      final event = events[index % events.length];
      final time =
          (1e6 + (index ~/ events.length) * cycleMicros + event.micros).round();
      lastTime = time;
      out
        ..addAll(_bigEndian32(time))
        ..add(event.flags);
    }
    return out;
  }

  /// One engine cycle of edges, in order: both edges of every tooth over two
  /// turns, and the cam pulse early in the first.
  List<({double micros, int flags})> _cycleEvents() {
    final pitch = 360 / triggerTeeth;
    final edges = <({double angle, bool cam, bool rising})>[
      for (var turn = 0; turn < 2; turn++)
        for (var tooth = 0; tooth < _presentTeeth; tooth++) ...[
          (angle: turn * 360 + tooth * pitch, cam: false, rising: true),
          (
            angle: turn * 360 + (tooth + 0.5) * pitch,
            cam: false,
            rising: false,
          ),
        ],
      (angle: 3.25 * pitch, cam: true, rising: true),
      (angle: 6.25 * pitch, cam: true, rising: false),
    ]..sort((a, b) => a.angle.compareTo(b.angle));

    var crank = false;
    var cam = false;
    return [
      for (final edge in edges)
        () {
          if (edge.cam) {
            cam = edge.rising;
          } else {
            crank = edge.rising;
          }
          // Bits as `decoders.cpp` sets them: 0 primary level, 1 secondary
          // level, 3 set by a secondary edge, 4 sync, 5 first turn.
          final flags = (crank ? 0x01 : 0) |
              (cam ? 0x02 : 0) |
              (edge.cam ? 0x08 : 0) |
              0x10 |
              (edge.angle < 360 ? 0x20 : 0);
          return (micros: edge.angle * _microsPerDegree, flags: flags);
        }(),
    ];
  }

  static List<int> _bigEndian32(int value) => [
        (value >> 24) & 0xFF,
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF,
      ];
}
