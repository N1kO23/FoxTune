/// Speeduino serial protocol codec.
///
/// Pure Dart: this package knows how to speak to a Speeduino but nothing about
/// serial ports, USB or Flutter. It operates over the [EcuLink] byte pipe, so
/// the entire protocol layer can be exercised in CI against [FakeEcuLink] with
/// no hardware attached.
library;

export 'src/crc32.dart';
export 'src/ecu_client.dart';
export 'src/ecu_link.dart';
export 'src/frame.dart';
export 'src/realtime_decoder.dart';
export 'src/realtime_monitor.dart';
export 'src/response_code.dart';
export 'src/speeduino_constants.dart';
