/// TunerStudio ECU definition (`.ini`) parser.
///
/// Parses the data model - `[Constants]`, `[OutputChannels]`, `[TableEditor]`,
/// `[CurveEditor]` - rather than TunerStudio's UI layout DSL. Page sizes,
/// scaling and realtime layout are read from the file so FoxTune tracks
/// firmware changes instead of breaking on them.
///
/// ```dart
/// final doc = IniParser(defined: {'CELSIUS'}).parse(source);
/// if (doc.matchesSignature(reportedBySignatureCommand)) {
///   final blockSize = doc.constants.blockingFactor;
/// }
/// ```
///
/// Pure Dart, no dependencies.
library;

export 'src/data_type.dart';
export 'src/expression.dart';
export 'src/ini_exception.dart';
export 'src/model/document.dart';
export 'src/model/fields.dart';
export 'src/model/sections.dart';
export 'src/parser.dart';
export 'src/preprocessor.dart'
    show IniPreprocessor, PreprocessResult, SourceLine;
