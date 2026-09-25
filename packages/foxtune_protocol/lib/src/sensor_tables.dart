import 'dart:math' as math;
import 'dart:typed_data';

import 'ecu_client.dart';
import 'response_code.dart';
import 'speeduino_constants.dart';

/// How long one piece of a sensor calibration may take to be answered.
///
/// The ECU saves the table to its EEPROM before it replies, a byte at a
/// time, which on an AVR takes a few milliseconds a byte.
const sensorTableTimeout = Duration(seconds: 3);

/// Speeduino's sensor calibrations: the coolant, air temperature and O2
/// tables it keeps apart from its pages, and saves as they arrive.
///
/// They are written with the definition's `tableWriteCommand`, but not
/// rendered from it as the page commands are. `t\$tsCanId%2i%2o%2c%v` reads
/// as a two-byte table id and a little-endian offset and length, where the
/// firmware (`comms.cpp`) takes one byte for the table and both words high
/// byte first. So the bytes are laid out here as the firmware reads them.
extension SensorTableCommands on EcuClient {
  /// Sends [data] as calibration table [table], [chunkSize] bytes at a time.
  ///
  /// [chunkSize] must be the definition's `tableBlockingFactor`, not merely
  /// something that fits. Firmware up to 202305 saves the O2 table only on
  /// the piece that starts where its own chunking puts the last one - 768
  /// for 256-byte pieces - so a table sent in any other size is never saved.
  ///
  /// There is no burn: the ECU saves each table the moment it has all of it.
  Future<void> writeSensorTable(
    int table,
    List<int> data, {
    required int chunkSize,
  }) async {
    if (chunkSize <= 0) {
      throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
    }
    for (var offset = 0; offset < data.length; offset += chunkSize) {
      final count = math.min(chunkSize, data.length - offset);
      await send([
        SpeeduinoCommand.tableWrite,
        canId & 0xFF,
        table & 0xFF,
        (offset >> 8) & 0xFF,
        offset & 0xFF,
        (count >> 8) & 0xFF,
        count & 0xFF,
        ...data.sublist(offset, offset + count),
      ], timeout: sensorTableTimeout);
    }
  }

  /// The CRC-32 the ECU keeps of calibration table [table], as it last
  /// saved it.
  ///
  /// It is worked out over the bytes as they were sent, so it can be compared
  /// with the CRC-32 of a table made here. Firmware before 202501 kept a
  /// broken one for the O2 table, though: the running checksum shared its
  /// state with the serial link's, which every reply reset.
  Future<int> sensorTableCrc(int table) async {
    final data = await send([
      SpeeduinoCommand.tableCrc,
      canId & 0xFF,
      table & 0xFF,
    ]);
    if (data.length < 4) {
      throw EcuProtocolException(
        'Calibration CRC reply was ${data.length} bytes, expected 4',
      );
    }
    // High byte first, like the page CRC.
    return ByteData.sublistView(data).getUint32(0, Endian.big);
  }
}
