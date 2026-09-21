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
        reply(socket, [0x00, ...realtime.sublist(offset, offset + count)]);

      default:
        reply(socket, [0x83]); // SERIAL_RC_UKWN_ERR
    }
  }
}
