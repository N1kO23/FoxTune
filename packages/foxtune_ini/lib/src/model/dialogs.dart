/// A `[UserDefined]` dialog: a screenful of settings, described by the
/// definition rather than built by hand.
///
/// Dialogs compose. A screen the user opens is usually a `border` dialog whose
/// regions are other dialogs, each of those a column of fields. Rendering one
/// therefore means walking [items] and recursing into every [IniDialogPanel].
class IniDialog {
  const IniDialog({
    required this.id,
    required this.title,
    required this.items,
    this.layout,
    this.columns,
    this.topicHelp,
    this.webHelp,
  });

  /// Identifier a menu entry or panel references.
  final String id;

  /// Heading. Often empty for dialogs that exist only to be embedded.
  final String title;

  /// Children in source order.
  final List<IniDialogItem> items;

  /// Named layout: `xAxis`, `yAxis`, `border`, `card` or `indexCard`.
  ///
  /// `border` is the one that carries meaning beyond styling, because its
  /// children are placed by the position named on each panel.
  ///
  /// Two further values mark dialogs that were not declared with a `dialog`
  /// line at all: `indicatorPanel` for a block of lamps, and `help` for a
  /// page of prose. Both are referenced exactly as a dialog is, so they are
  /// modelled as one rather than as separate kinds of thing.
  final String? layout;

  /// Column count, where the layout was given as a number instead of a name.
  final int? columns;

  /// Documentation URL for the dialog as a whole.
  final String? topicHelp;

  /// Secondary documentation URL, from a `webHelp` line.
  final String? webHelp;

  /// Whether children are placed by compass position.
  bool get isBorderLayout => layout?.toLowerCase() == 'border';

  @override
  String toString() => 'dialog $id ("$title", ${items.length} items)';
}

/// Anything that can appear inside a dialog.
///
/// ## The two conditions
///
/// Definition lines carry up to two `{ ... }` expressions. The first enables
/// the item - TunerStudio greys it out when false - and the second controls
/// whether it appears at all. The file writes an empty `{}` to skip a slot,
/// as in `field = "Injector Pairing", inj4CylPairing, {}, { nCylinders == 4 }`,
/// so an empty group is recorded as no condition rather than as one that is
/// always false.
sealed class IniDialogItem {
  const IniDialogItem({this.enableCondition, this.visibleCondition});

  /// Expression that must hold for the item to be editable.
  final String? enableCondition;

  /// Expression that must hold for the item to be shown.
  final String? visibleCondition;
}

/// How a field's label is marked up in the definition.
///
/// A leading `!` means the line is a warning - "Outputs WILL NOT work if
/// incorrect board is selected" - and a leading `#` marks an aside. Both are
/// lines the tuner is meant to read rather than skim past, so the marker is
/// kept rather than stripped and forgotten.
enum IniFieldEmphasis { none, warning, note }

/// A labelled setting, bound to a constant.
///
/// Also covers the two degenerate forms the file uses freely: a label with no
/// constant is a line of explanatory text, and an empty label is vertical
/// space.
final class IniDialogField extends IniDialogItem {
  const IniDialogField({
    required this.label,
    this.constant,
    this.readOnly = false,
    this.emphasis = IniFieldEmphasis.none,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Text shown beside the control, with any styling prefix removed.
  final String label;

  /// Styling the definition asked for, from a `!` or `#` label prefix.
  final IniFieldEmphasis emphasis;

  /// Name of the constant this edits, or `null` for text and spacers.
  final String? constant;

  /// Whether the value is shown but not editable, from `displayOnlyField`.
  final bool readOnly;

  /// Whether this is blank space rather than content.
  bool get isSpacer => label.isEmpty && constant == null;

  /// Whether this is a line of prose rather than a control.
  bool get isText => label.isNotEmpty && constant == null;

  @override
  String toString() =>
      'field "$label"${constant == null ? '' : ' -> $constant'}';
}

/// Another dialog, a table or a curve embedded in this one.
final class IniDialogPanel extends IniDialogItem {
  const IniDialogPanel({
    required this.target,
    this.position,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Identifier of the dialog, table or curve to embed.
  final String target;

  /// Compass placement within a `border` layout: North, South, East, West or
  /// Center. Null when the parent lays children out in order.
  final String? position;

  @override
  String toString() => 'panel $target';
}

/// A setting presented as a slider rather than a numeric entry.
final class IniDialogSlider extends IniDialogItem {
  const IniDialogSlider({
    required this.label,
    required this.constant,
    this.orientation = 'horizontal',
    super.enableCondition,
    super.visibleCondition,
  });

  /// Text shown beside the slider.
  final String label;

  /// Name of the constant this edits.
  final String constant;

  /// `horizontal` or `vertical`.
  final String orientation;

  @override
  String toString() => 'slider "$label" -> $constant';
}

/// A button that sends a command to the ECU.
///
/// The command is a `[ControllerCommands]` entry, which typically triggers a
/// calibration or a hardware test rather than writing a setting.
final class IniDialogCommandButton extends IniDialogItem {
  const IniDialogCommandButton({
    required this.label,
    required this.command,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Button text.
  final String label;

  /// Name of the controller command to send.
  final String command;

  @override
  String toString() => 'commandButton "$label" -> $command';
}

/// A lamp driven by a realtime expression.
final class IniDialogIndicator extends IniDialogItem {
  const IniDialogIndicator({
    required this.expression,
    required this.offLabel,
    required this.onLabel,
    this.offBackground,
    this.offForeground,
    this.onBackground,
    this.onForeground,
    this.offLabelIsTemplate = false,
    this.onLabelIsTemplate = false,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Expression over realtime channels deciding which state is shown.
  final String expression;

  /// Text shown while the expression is false.
  final String offLabel;

  /// Text shown while the expression is true.
  final String onLabel;

  /// Whether [offLabel] is written in braces: text with live lookups in it,
  /// such as `{ Ignition out 1: bitStringValue(outputDiagErrorList,
  /// ignitorDiagnostic1) }`, rather than plain text. rusEFI writes its
  /// diagnostic lamps this way, so the lamp says what is wrong, not just
  /// that something is.
  final bool offLabelIsTemplate;

  /// Whether [onLabel] is a template. See [offLabelIsTemplate].
  final bool onLabelIsTemplate;

  /// Colour names as the definition writes them, e.g. `green`, `black`.
  final String? offBackground;
  final String? offForeground;
  final String? onBackground;
  final String? onForeground;

  @override
  String toString() => 'indicator "$offLabel"/"$onLabel"';
}

/// A line of static prose, from a `text` line.
final class IniDialogText extends IniDialogItem {
  const IniDialogText({
    required this.text,
    super.enableCondition,
    super.visibleCondition,
  });

  /// The text, which may contain simple HTML such as `<br>`.
  final String text;

  @override
  String toString() => 'text "$text"';
}

/// A gauge from `[GaugeConfigurations]`, embedded in a dialog.
final class IniDialogGauge extends IniDialogItem {
  const IniDialogGauge({
    required this.gauge,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Identifier of the gauge configuration to show.
  final String gauge;

  @override
  String toString() => 'gauge $gauge';
}

/// A scrolling plot of realtime channels.
final class IniDialogLiveGraph extends IniDialogItem {
  const IniDialogLiveGraph({
    required this.id,
    required this.title,
    this.lines = const [],
    super.enableCondition,
    super.visibleCondition,
  });

  /// Identifier of the graph.
  final String id;

  /// Heading.
  final String title;

  /// Channels plotted on it, in declaration order.
  final List<String> lines;

  @override
  String toString() => 'liveGraph $id (${lines.length} lines)';
}

/// A drop-down of named presets that each write several constants at once.
///
/// Speeduino uses these for "Common Pressure Sensors": picking MPX4250A sets
/// `mapMin` and `mapMax` together, which is a good deal less error-prone than
/// asking a tuner to look the numbers up.
final class IniDialogSettingSelector extends IniDialogItem {
  const IniDialogSettingSelector({
    required this.label,
    required this.options,
    super.enableCondition,
    super.visibleCondition,
  });

  /// Text shown beside the drop-down.
  final String label;

  /// Presets in declaration order.
  final List<IniSettingPreset> options;

  @override
  String toString() => 'settingSelector "$label" (${options.length} options)';
}

/// One entry of an [IniDialogSettingSelector].
class IniSettingPreset {
  const IniSettingPreset({required this.label, required this.assignments});

  /// Display name, e.g. `MPX4250A/MPXA4250A`.
  final String label;

  /// Constant name to value, in engineering units.
  final Map<String, double> assignments;

  @override
  String toString() => 'settingOption "$label" (${assignments.length} values)';
}
