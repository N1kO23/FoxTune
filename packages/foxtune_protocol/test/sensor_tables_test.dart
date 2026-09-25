@TestOn('vm')
library;

import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:test/test.dart';

/// Sensor calibrations, written to a simulated Speeduino over a real socket
/// and laid out as the firmware's `comms.cpp` reads them.
void main() {
  late FakeSpeeduino ecu;
  late SocketEcuLink link;
  late EcuClient client;

  setUp(() async {
    ecu = FakeSpeeduino();
    final port = await ecu.start();
    link = await SocketEcuLink.connect('127.0.0.1', port);
    client = EcuClient(link, timeout: const Duration(seconds: 2));
  });

  tearDown(() async {
    await client.close();
    await link.close();
    await ecu.stop();
  });

  List<List<int>> writes() => [
        for (final r in ecu.requests)
          if (r[0] == SpeeduinoCommand.tableWrite) r,
      ];

  test('a temperature table goes in one piece, and is saved as sent', () async {
    final table = [for (var i = 0; i < 64; i++) i * 3 & 0xFF];
    await client.writeSensorTable(0, table, chunkSize: 256);

    final sent = writes().single;
    // 't', CAN id, table, offset and length high byte first, then the data.
    expect(sent.sublist(0, 7), [0x74, 0, 0, 0, 0, 0, 64]);
    expect(sent.sublist(7), table);
    expect(ecu.sensorTables[0], table);
  });

  test(
      'the O2 table goes in pieces of the blocking factor, offsets high '
      'byte first', () async {
    final table = [for (var i = 0; i < 1024; i++) i ~/ 4];
    await client.writeSensorTable(2, table, chunkSize: 256);

    expect([
      for (final w in writes()) w.sublist(2, 7)
    ], [
      [2, 0x00, 0x00, 0x01, 0x00],
      [2, 0x01, 0x00, 0x01, 0x00],
      [2, 0x02, 0x00, 0x01, 0x00],
      [2, 0x03, 0x00, 0x01, 0x00],
    ]);
    expect(ecu.sensorTables[2], table);
  });

  test('its CRC is the one the ECU keeps of what it saved', () async {
    final coolant = [for (var i = 0; i < 64; i++) 200 - i];
    final o2 = [for (var i = 0; i < 1024; i++) 100 + i % 100];
    await client.writeSensorTable(0, coolant, chunkSize: 256);
    await client.writeSensorTable(2, o2, chunkSize: 64);

    expect(await client.sensorTableCrc(0), crc32(coolant));
    expect(await client.sensorTableCrc(2), crc32(o2));
    expect(ecu.requests.last, [0x6B, 0, 2], reason: "'k', CAN id, table");
  });

  test('a temperature table of the wrong length is refused', () async {
    await expectLater(
      client.writeSensorTable(1, List.filled(60, 0), chunkSize: 256),
      throwsA(
        isA<EcuProtocolException>().having(
          (e) => e.response,
          'response',
          SerialResponse.rangeError,
        ),
      ),
    );
    expect(ecu.sensorTables, isNot(contains(1)));
  });
}
