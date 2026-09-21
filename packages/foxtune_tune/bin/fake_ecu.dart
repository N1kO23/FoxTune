import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show EcuFamily;
import 'package:foxtune_protocol/testing.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:foxtune_tune/simulation.dart';

/// Runs a simulated Speeduino or rusEFI on a TCP port.
///
/// Point FoxTune at it with "Network ECU" -> `127.0.0.1:2000` (Speeduino) or
/// `127.0.0.1:29001` (rusEFI, the port its own simulator uses). Which one it
/// is follows from the definition passed with `--ini`: a rusEFI definition
/// gets rusEFI's commands and page addressing. It speaks the real wire
/// protocol - envelope, CRC-32, page read/write/burn, realtime - and drives a
/// running engine into the realtime block, so gauges move and the live table
/// cursor travels.
///
/// A simulated Speeduino goes further, and its mixture answers to the tune:
/// the VE table in the ECU's pages decides
/// how much fuel goes in, the engine's own airflow decides how much it needed,
/// and the wideband reports the difference through a sensor lag. Edit the VE
/// table in FoxTune and the simulated AFR moves; closed-loop correction trims
/// against it; autotuning can be driven end to end without an engine.
///
/// Seed it with a real tune via `--msq` to get realistic tables and settings.
/// That also matters for correctness, not just realism: channels like
/// `fuelLoad` scale by an expression that depends on a configuration constant,
/// so without a tune loaded they cannot be written at all. Without one, the VE
/// and target tables are seeded from the engine model instead, deliberately a
/// few percent out so there is something to tune.
///
/// Usage:
///   dart run foxtune_tune:fake_ecu [--port N] [--ini PATH] [--msq PATH]
///                                  [--static] [--ve-error PERCENT]
Future<void> main(List<String> args) async {
  int? port;
  var iniPath = '../foxtune_ini/test/fixtures/speeduino.ini';
  String? msqPath;
  var simulate = true;
  var veError = -8.0;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--port':
        port = int.tryParse(args.elementAtOrNull(i + 1) ?? '');
        i++;
      case '--ini':
        iniPath = args.elementAtOrNull(i + 1) ?? iniPath;
        i++;
      case '--msq':
        msqPath = args.elementAtOrNull(i + 1);
        i++;
      case '--static':
        simulate = false;
      case '--ve-error':
        veError = double.tryParse(args.elementAtOrNull(i + 1) ?? '') ?? veError;
        i++;
      case '--help':
      case '-h':
        stdout.writeln('Usage: fake_ecu [--port N] [--ini PATH] [--msq PATH] '
            '[--static] [--ve-error PERCENT]');
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
  final isRusEfi =
      EcuFamily.of(definition.identity.signature ?? '') == EcuFamily.rusefi;

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

  if (isRusEfi) {
    await _serveRusEfi(
      definition,
      tune: tuneLoaded ? tune : null,
      port: port ?? 29001,
      simulate: simulate,
    );
    return;
  }

  // Constants are resolved from the ECU's live pages rather than from a copy,
  // so a setting written over the wire takes effect the way it would on real
  // hardware instead of leaving the realtime block scaled by a stale value.
  late final TunedEngineSimulation engine;
  final ecu = FakeSpeeduino(
    signature: definition.identity.signature ?? 'speeduino',
    pageSizes: definition.constants.pageSizes,
    realtimeBlockSize: definition.outputChannels.blockSize ?? 139,
    blockingFactor: definition.constants.blockingFactor ?? 251,
    channels: definition.outputChannels,
    constantResolver: (name) => engine.resolve(name),
  );

  if (tuneLoaded) {
    for (var page = 1; page <= ecu.pages.length; page++) {
      ecu.pages[page - 1].setAll(0, tune.page(page));
    }
  }

  // The engine reads the ECU's pages directly, so a VE table written over the
  // wire changes what it runs at from the next sample onwards.
  engine = TunedEngineSimulation(definition: definition, pages: ecu.pages);
  if (!tuneLoaded) {
    // Filler bytes are not a tune: the axis bins are not even monotonic.
    // Seeding lays down a coherent base tune, with the VE table deliberately
    // out by a known amount so there is something to tune.
    engine.seedTune(errorPercent: veError);
  }

  final bound = await ecu.start(host: '0.0.0.0', port: port ?? 2000);
  if (simulate) ecu.simulateEngine(simulation: engine);

  stdout
    ..writeln('FoxTune simulated ECU')
    ..writeln('  signature : ${ecu.signature}')
    ..writeln('  listening : 0.0.0.0:$bound')
    ..writeln('  pages     : ${ecu.pageSizes.length}')
    ..writeln('  realtime  : ${ecu.realtimeBlockSize} bytes')
    ..writeln('  engine    : ${simulate ? "running, fuelled from the VE "
        "table" : "static"}');

  if (simulate && !tuneLoaded) {
    stdout.writeln('  ve table  : seeded from the engine model, '
        '${veError.toStringAsFixed(0)}% out');
  }

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

/// Serves a simulated rusEFI.
///
/// Its engine runs canned fuelling rather than answering to the tune: the
/// model that reads the VE table is written against Speeduino's tables and
/// curves. Gauges move, pages read, write, verify and burn as rusEFI's do.
Future<void> _serveRusEfi(
  IniDocument definition, {
  required TuneState? tune,
  required int port,
  required bool simulate,
}) async {
  final ecu = FakeRusEfi.fromDefinition(definition);
  if (tune != null) {
    for (var page = 1; page <= ecu.pages.length; page++) {
      ecu.pages[page - 1].setAll(0, tune.page(page));
    }
  }

  final bound = await ecu.start(host: '0.0.0.0', port: port);
  if (simulate) ecu.simulateEngine();
  final tuneSource = tune == null
      ? 'filler bytes - load one with --msq for real tables'
      : 'from --msq';

  stdout
    ..writeln('FoxTune simulated rusEFI')
    ..writeln('  signature : ${ecu.signature}')
    ..writeln('  listening : 0.0.0.0:$bound')
    ..writeln('  pages     : ${ecu.pageSizes.join(", ")} bytes')
    ..writeln('  realtime  : ${ecu.realtimeBlockSize} bytes')
    ..writeln(
        '  engine    : ${simulate ? "running, canned fuelling" : "static"}')
    ..writeln('  tune      : $tuneSource')
    ..writeln('')
    ..writeln('Connect with "Network ECU" -> 127.0.0.1:$bound')
    ..writeln('Ctrl-C to stop.');

  await ProcessSignal.sigint.watch().first;
  await ecu.stop();
  stdout.writeln('\nStopped.');
}
