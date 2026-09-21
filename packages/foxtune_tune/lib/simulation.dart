/// A simulated engine that answers to the tune in the ECU's pages.
///
/// Kept out of the main library because it reaches into
/// `package:foxtune_protocol/testing.dart`, which depends on `dart:io`.
///
/// ```dart
/// final ecu = FakeSpeeduino(channels: definition.outputChannels);
/// final engine = TunedEngineSimulation(
///   definition: definition,
///   pages: ecu.pages,
/// )..seedTune(errorPercent: -8);
/// ecu.simulateEngine(simulation: engine);
/// ```
library;

export 'src/simulation/tuned_engine.dart';
