/// TunerStudio ECU definition (`.ini`) parser.
///
/// Parses the data model - `[Constants]`, `[OutputChannels]`, `[TableEditor]`,
/// `[CurveEditor]` - rather than TunerStudio's UI layout DSL. Page sizes,
/// scaling and realtime layout are read from the file so FoxTune tracks
/// firmware changes instead of breaking on them.
///
/// Pure Dart, no dependencies.
library;

// Parser implementation lands in M1.
