import 'fields.dart';
import 'sections.dart';

/// Identification block from `[MegaTune]` and `[TunerStudio]`.
///
/// [signature] is the value a connected ECU must return for the definition to
/// apply. Matching it is the precondition for any write: a mismatch means the
/// page layout in hand does not describe the ECU on the other end of the wire.
class IniIdentity {
  const IniIdentity({
    this.signature,
    this.queryCommand,
    this.versionInfo,
    this.mtVersion,
    this.iniSpecVersion,
  });

  /// Expected signature string, e.g. `speeduino 202504-dev`.
  final String? signature;

  /// Command that asks the ECU to identify itself, normally `Q`.
  final String? queryCommand;

  /// Command that returns the displayable version string, normally `S`.
  final String? versionInfo;

  /// MegaTune format version.
  final String? mtVersion;

  /// INI specification version this file targets.
  final String? iniSpecVersion;
}

/// A section the parser retains verbatim rather than modelling.
///
/// `[Menu]`, `[UserDefined]` and friends describe TunerStudio's own UI. They
/// are kept as raw lines so a generated-UI pass could use them later without
/// the file needing to be parsed twice.
class IniRawSection {
  const IniRawSection({required this.name, required this.lines});

  /// Section name without brackets.
  final String name;

  /// Source lines belonging to the section, comments stripped.
  final List<String> lines;

  @override
  String toString() => '[$name] (${lines.length} lines)';
}

/// A parsed TunerStudio ECU definition.
class IniDocument {
  const IniDocument({
    required this.identity,
    required this.settingGroups,
    required this.defines,
    required this.constants,
    required this.outputChannels,
    required this.pcVariables,
    required this.datalog,
    required this.tables,
    required this.curves,
    required this.rawSections,
    required this.definedSymbols,
  });

  /// Signature and version information.
  final IniIdentity identity;

  /// Build-configuration groups the user can choose between.
  final List<IniSettingGroup> settingGroups;

  /// `#define` lists, fully expanded.
  final Map<String, List<String>> defines;

  /// Page layout and transport settings.
  final IniConstants constants;

  /// Realtime data block layout.
  final IniOutputChannels outputChannels;

  /// Host-side variables that are not stored on the ECU.
  final List<IniField> pcVariables;

  /// Datalog columns, in the order they should be written.
  final List<IniDatalogEntry> datalog;

  /// 3D table definitions.
  final List<IniTable> tables;

  /// 2D curve definitions.
  final List<IniCurve> curves;

  /// Sections retained verbatim, keyed by name.
  final Map<String, IniRawSection> rawSections;

  /// Preprocessor symbols that were in effect, after `#set` / `#unset`.
  final Set<String> definedSymbols;

  /// Looks up a table by its identifier.
  IniTable? tableNamed(String id) {
    for (final table in tables) {
      if (table.id == id) return table;
    }
    return null;
  }

  /// Looks up a curve by its identifier.
  IniCurve? curveNamed(String id) {
    for (final curve in curves) {
      if (curve.id == id) return curve;
    }
    return null;
  }

  /// Resolves a field by name across page constants and PC variables.
  ///
  /// Curve axes may reference either: most bins are page constants, but some -
  /// `wueAFR`, for instance - are `[PcVariables]` computed host-side. A lookup
  /// restricted to pages would report those as dangling references.
  IniField? findField(String name) {
    final onPage = constants.findField(name);
    if (onPage != null) return onPage.field;
    for (final variable in pcVariables) {
      if (variable.name == name) return variable;
    }
    return null;
  }

  /// Checks a signature reported by a connected ECU against this definition.
  ///
  /// Returns `false` when the definition declares no signature, because an
  /// unknown expectation is not a match.
  bool matchesSignature(String reported) =>
      identity.signature != null && identity.signature == reported.trim();

  @override
  String toString() => 'IniDocument(${identity.signature}, '
      '${constants.pageCount} pages, '
      '${outputChannels.channels.length} channels, '
      '${tables.length} tables, ${curves.length} curves)';
}
