import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/testing.dart';

/// Runs a simulated Speeduino on a TCP port.
///
/// Point FoxTune at it with "Network ECU" -> `127.0.0.1:2000`. It speaks the
/// real wire protocol - envelope, CRC-32, page read/write/burn, realtime - and
/// drives a running engine into the realtime block, so gauges move and the live
/// table cursor travels. Useful for UI work without a car.
///
/// Usage:
///   dart run foxtune_protocol:fake_ecu [--port 2000] [--ini path] [--static]
Future<void> main(List<String> args) async {
  var port = 2000;
  var iniPath = '../foxtune_ini/test/fixtures/speeduino.ini';
  var simulate = true;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.tryParse(args.elementAtOrNull(i + 1) ?? '') ?? port;
        i++;
      case '--ini':
        iniPath = args.elementAtOrNull(i + 1) ?? iniPath;
        i++;
      case '--static':
        simulate = false;
      case '--help':
      case '-h':
        stdout.writeln('Usage: fake_ecu [--port N] [--ini PATH] [--static]');
        return;
    }
  }

  final file = File(iniPath);
  if (!file.existsSync()) {
    stderr.writeln('Definition not found: $iniPath');
    stderr.writeln('Pass one with --ini.');
    exitCode = 2;
    return;
  }

  final definition =
      IniParser(defined: {'CELSIUS'}).parse(file.readAsStringSync());
  final ecu = FakeSpeeduino(
    signature: definition.identity.signature ?? 'speeduino 202504-dev',
    pageSizes: definition.constants.pageSizes,
    realtimeBlockSize: definition.outputChannels.blockSize ?? 139,
    blockingFactor: definition.constants.blockingFactor ?? 251,
    channels: definition.outputChannels,
  );

  final bound = await ecu.start(host: '0.0.0.0', port: port);
  if (simulate) ecu.simulateEngine();

  stdout
    ..writeln('FoxTune simulated ECU')
    ..writeln('  signature : ${ecu.signature}')
    ..writeln('  listening : 0.0.0.0:$bound')
    ..writeln('  pages     : ${ecu.pageSizes.length}')
    ..writeln('  realtime  : ${ecu.realtimeBlockSize} bytes')
    ..writeln('  engine    : ${simulate ? "running" : "static"}')
    ..writeln('')
    ..writeln('Connect with "Network ECU" -> 127.0.0.1:$bound')
    ..writeln('Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await ecu.stop();
  stdout.writeln('\nStopped.');
}
