import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Runs a simulated Speeduino on a TCP port.
///
/// Point FoxTune at it with "Network ECU" -> `127.0.0.1:2000`. It speaks the
/// real wire protocol - envelope, CRC-32, page read/write/burn, realtime - and
/// drives a running engine into the realtime block, so gauges move and the live
/// table cursor travels.
///
/// Seed it with a real tune via `--msq` to get realistic tables and settings.
/// That also matters for correctness, not just realism: channels like
/// `fuelLoad` scale by an expression that depends on a configuration constant,
/// so without a tune loaded they cannot be written at all.
///
/// Usage:
///   dart run foxtune_tune:fake_ecu [--port N] [--ini PATH] [--msq PATH]
///                                  [--static]
Future<void> main(List<String> args) async {
  var port = 2000;
  var iniPath = '../foxtune_ini/test/fixtures/speeduino.ini';
  String? msqPath;
  var simulate = true;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.tryParse(args.elementAtOrNull(i + 1) ?? '') ?? port;
        i++;
      case '--ini':
        iniPath = args.elementAtOrNull(i + 1) ?? iniPath;
        i++;
      case '--msq':
        msqPath = args.elementAtOrNull(i + 1);
        i++;
      case '--static':
        simulate = false;
      case '--help':
      case '-h':
        stdout.writeln(
            'Usage: fake_ecu [--port N] [--ini PATH] [--msq PATH] [--static]');
        return;
    }
  }

  final iniFile = File(iniPath);
  if (!iniFile.existsSync()) {
    stderr.writeln('Definition not found: $iniPath\nPass one with --ini.');
    exitCode = 2;
    return;
  }

  final definition =
      IniParser(defined: {'CELSIUS'}).parse(iniFile.readAsStringSync());

  // A tune gives the simulator real tables, real axis bins, and the
  // configuration constants that expression-based scaling depends on.
  final tune = TuneState.empty(definition);
  var tuneLoaded = false;
  if (msqPath != null) {
    final msqFile = File(msqPath);
    if (!msqFile.existsSync()) {
      stderr.writeln('Tune not found: $msqPath');
      exitCode = 2;
      return;
    }
    final xml = msqFile.readAsStringSync();
    MsqImportResult result;
    try {
      result = MsqCodec.decode(xml, tune);
    } on MsqException {
      // A base tune is often for a different firmware build than the loaded
      // definition. Values match by name, so load what applies and say what
      // did not rather than refusing outright.
      result = MsqCodec.decode(xml, tune, requireSignatureMatch: false);
      stdout.writeln('  note      : tune signature "${result.signature}" '
          'differs from "${definition.identity.signature}"');
    }
    tuneLoaded = true;
    stdout.writeln('  tune      : ${result.applied} values from '
        '${msqPath.split('/').last}'
        '${result.unknown.isEmpty ? '' : ', ${result.unknown.length} unknown'}'
        '${result.skipped.isEmpty ? '' : ', ${result.skipped.length} skipped'}');
  }

  final resolver = TuneValueResolver(tune);
  final ecu = FakeSpeeduino(
    signature: definition.identity.signature ?? 'speeduino',
    pageSizes: definition.constants.pageSizes,
    realtimeBlockSize: definition.outputChannels.blockSize ?? 139,
    blockingFactor: definition.constants.blockingFactor ?? 251,
    channels: definition.outputChannels,
    constantResolver: resolver.resolve,
  );

  if (tuneLoaded) {
    for (var page = 1; page <= ecu.pages.length; page++) {
      ecu.pages[page - 1].setAll(0, tune.page(page));
    }
  }

  final bound = await ecu.start(host: '0.0.0.0', port: port);
  if (simulate) ecu.simulateEngine();

  stdout
    ..writeln('FoxTune simulated ECU')
    ..writeln('  signature : ${ecu.signature}')
    ..writeln('  listening : 0.0.0.0:$bound')
    ..writeln('  pages     : ${ecu.pageSizes.length}')
    ..writeln('  realtime  : ${ecu.realtimeBlockSize} bytes')
    ..writeln('  engine    : ${simulate ? "running" : "static"}');

  if (simulate && ecu.unresolvedChannels.isNotEmpty) {
    stdout.writeln('  warning   : could not scale '
        '${ecu.unresolvedChannels.join(", ")} - '
        'load a tune with --msq so those resolve');
  }

  stdout
    ..writeln('')
    ..writeln('Connect with "Network ECU" -> 127.0.0.1:$bound')
    ..writeln('Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await ecu.stop();
  stdout.writeln('\nStopped.');
}
