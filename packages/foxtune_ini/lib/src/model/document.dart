import 'dialogs.dart';
import 'fields.dart';
import 'menus.dart';
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

/// What kind of screen a menu entry or panel points at.
///
/// A target name alone does not say which: `triggerSettings` is a dialog,
/// `afrTable1Tbl` a table and `airdensity_curve` a curve, and only the rest of
/// the document distinguishes them. See [IniDocument.targetKind].
enum IniTargetKind {
  /// A `[UserDefined]` dialog, which FoxTune generates a screen from.
  dialog,

  /// A `[TableEditor]` table, opened in the table editor.
  table,

  /// The 3D view of a `[TableEditor]` table, named by its map identifier.
  ///
  /// Speeduino's "3D Tuning Maps" menu points at `veTable1Map` where the
  /// "Tuning" menu points at `veTable1Tbl` - the same data, opened as a
  /// surface rather than as a grid.
  map,

  /// A `[CurveEditor]` curve, opened in the curve editor.
  curve,

  /// One of TunerStudio's own editors, named `std_*`. These live in
  /// TunerStudio rather than in the definition, so there is nothing here to
  /// build a screen from.
  builtIn,

  /// A name the document does not define.
  unknown,
}

/// A section the parser retains verbatim rather than modelling.
///
/// `[FrontPage]` and friends describe parts of TunerStudio's own UI that
/// FoxTune does not reproduce. They are kept as raw lines rather than dropped,
/// so a later pass can use them without the file needing a second parse.
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
    this.menus = const [],
    this.dialogs = const [],
    this.settingHelp = const {},
    this.defaultValues = const {},
    this.requiresPowerCycle = const {},
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

  /// Top-level menus from `[Menu]`, in declaration order.
  final List<IniMenu> menus;

  /// Settings dialogs from `[UserDefined]`, in declaration order.
  final List<IniDialog> dialogs;

  /// Per-constant help text from `[SettingContextHelp]`.
  final Map<String, String> settingHelp;

  /// Factory values from `[ConstantsExtensions]`, keyed by constant name.
  ///
  /// These are the only values `[PcVariables]` entries ever have: a PC
  /// variable lives on the host, not on a page, so nothing else supplies one.
  /// Several menu conditions ask whether the selected board has a real-time
  /// clock, which is exactly such a lookup.
  final Map<String, List<double>> defaultValues;

  /// Constants whose change only takes effect after the ECU is power-cycled.
  final Set<String> requiresPowerCycle;

  /// Looks up a dialog by its identifier.
  IniDialog? dialogNamed(String id) {
    for (final dialog in dialogs) {
      if (dialog.id == id) return dialog;
    }
    return null;
  }

  /// Help text for a constant, or `null` when the definition supplies none.
  String? helpFor(String constant) => settingHelp[constant];

  /// Classifies what [target] - a `subMenu` or `panel` name - points at.
  IniTargetKind targetKind(String target) {
    if (target.startsWith('std_')) return IniTargetKind.builtIn;
    if (dialogNamed(target) != null) return IniTargetKind.dialog;
    if (tableNamed(target) != null) return IniTargetKind.table;
    if (tableForMap(target) != null) return IniTargetKind.map;
    if (curveNamed(target) != null) return IniTargetKind.curve;
    return IniTargetKind.unknown;
  }

  /// Looks up a table by its *map* identifier - the 3D view's name.
  IniTable? tableForMap(String mapId) {
    for (final table in tables) {
      if (table.mapId == mapId) return table;
    }
    return null;
  }

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
      '${tables.length} tables, ${curves.length} curves, '
      '${dialogs.length} dialogs)';
}
