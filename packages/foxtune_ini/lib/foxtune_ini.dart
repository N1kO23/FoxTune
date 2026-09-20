/// TunerStudio ECU definition (`.ini`) parser.
///
/// Parses the data model - `[Constants]`, `[OutputChannels]`, `[TableEditor]`,
/// `[CurveEditor]` - together with the screens the definition describes in
/// `[Menu]` and `[UserDefined]`. Page sizes, scaling, realtime layout and the
/// settings dialogs are all read from the file, so FoxTune tracks firmware
/// changes instead of breaking on them.
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
export 'src/model/analyze.dart';
export 'src/model/dialogs.dart';
export 'src/model/document.dart';
export 'src/model/fields.dart';
export 'src/model/menus.dart';
export 'src/model/sections.dart';
export 'src/parser.dart';
export 'src/preprocessor.dart'
    show IniPreprocessor, PreprocessResult, SourceLine;
