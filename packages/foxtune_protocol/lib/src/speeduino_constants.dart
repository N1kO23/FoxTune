/// Wire-level constants for the Speeduino serial protocol.
///
/// Command letters below are transcribed from the command *templates* in the
/// shipped `speeduino.ini` (`pageReadCommand`, `pageValueWrite`, `burnCommand`,
/// `ochGetCommand`, ...). Anything that varies between firmware builds - page
/// count, page sizes, blocking factor, the signature string, which burn variant
/// applies - is deliberately NOT hardcoded here. Those come from the loaded
/// `.ini`, because baking them in is what breaks a tuner on every firmware
/// update.
library;

/// Standard link settings: 115200 8N1, no flow control.
const int kSpeeduinoBaudRate = 115200;

/// Speeduino transmits multi-byte values low byte first.
const bool kSpeeduinoLittleEndian = true;

/// Command bytes. Single ASCII characters, case sensitive.
///
/// The `%2i`/`%2o`/`%2c` placeholders in the .ini templates denote two-byte
/// little-endian page id, offset and count respectively. `\$tsCanId` is
/// substituted with the configured CAN id.
abstract final class SpeeduinoCommand {
  /// Query firmware version. The .ini's `queryCommand`.
  static const int query = 0x51; // 'Q'

  /// Return the signature string, e.g. "speeduino 202504-dev".
  /// The .ini's `versionInfo`.
  static const int signature = 0x53; // 'S'

  /// Test whether an ECU is present on this port.
  static const int testComms = 0x43; // 'C'

  /// Read a block from a configuration page.
  /// Template: `p%2i%2o%2c`.
  static const int pageRead = 0x70; // 'p'

  /// Write values into a configuration page, in RAM.
  /// Template: `M%2i%2o%2c%v` - used for both `pageValueWrite` and
  /// `pageChunkWrite`. Nothing is persisted until a burn.
  static const int pageWrite = 0x4D; // 'M'

  /// CRC-32 of a whole page, for verifying a write landed intact.
  /// Template: `d%2i`.
  static const int pageCrc = 0x64; // 'd'

  /// CRC-32 of a byte range within a page. Template: `k\$tsCanId%2i%2o%2c`.
  /// Only available when the firmware is in "new mode".
  static const int tableCrc = 0x6B; // 'k'

  /// New-generation realtime data. Template: `r\$tsCanId\x30%2o%2c`.
  /// The field layout comes from `[OutputChannels]`, never from fixed offsets.
  static const int realtime = 0x72; // 'r'

  /// Sub-command byte that follows the CAN id in [realtime].
  static const int realtimeSubCommand = 0x30;

  /// Legacy fixed-layout realtime block. Retained for old firmware only.
  static const int realtimeLegacy = 0x41; // 'A'

  /// Report page sizes.
  static const int pageSizes = 0x6E; // 'n'

  /// Burn the in-RAM page to EEPROM. Template: `b%2i`.
  static const int burn = 0x62; // 'b'

  /// Burn under `COMMS_COMPAT` builds, which deliberately slow the EEPROM
  /// write rate. Template: `B%2i`. Which one applies is decided by the .ini.
  static const int burnCompat = 0x42; // 'B'
}

/// The firmware's own inter-byte timeout. A response that has not arrived
/// within this window will never arrive.
const Duration kEcuCommandTimeout = Duration(milliseconds: 400);

/// Bytes of framing overhead on a new-generation transfer: 2 for the length
/// prefix plus 4 for the trailing CRC-32.
///
/// The usable payload is the firmware's serial buffer minus this. With the
/// current 257-byte buffer that yields the .ini's `blockingFactor = 251`;
/// STM32 and COMMS_COMPAT builds declare 121 instead. Always read the real
/// value from the .ini rather than assuming either.
const int kFramingOverheadBytes = 6;
