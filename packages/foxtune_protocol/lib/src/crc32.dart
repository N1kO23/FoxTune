/// CRC-32 as used by the Speeduino "new generation" serial protocol.
///
/// Standard CRC-32/ISO-HDLC (the zlib / IEEE 802.3 variant): reflected
/// polynomial 0xEDB88320, initial value 0xFFFFFFFF, final XOR 0xFFFFFFFF.
/// This matches the Arduino CRC32 library the firmware uses.
library;

import 'dart:typed_data';

final Uint32List _table = _buildTable();

Uint32List _buildTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var bit = 0; bit < 8; bit++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[i] = c;
  }
  return table;
}

/// Computes the CRC-32 of [bytes].
///
/// [seed] allows incremental computation across chunks: pass the result of a
/// previous call to continue a running checksum.
int crc32(List<int> bytes, [int seed = 0]) {
  var crc = (seed ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
