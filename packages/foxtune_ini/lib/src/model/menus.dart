/// One entry in a menu: a leaf pointing at a screen, a separator, or a group
/// of further entries.
///
/// The target is left as a name rather than resolved here. A `subMenu` may
/// point at a `[UserDefined]` dialog, a `[TableEditor]` table or a
/// `[CurveEditor]` curve, and which of the three it is depends on the rest of
/// the document - so resolution belongs to the caller that has the whole
/// document in hand - see `IniDocument.targetKind`.
class IniMenuItem {
  const IniMenuItem({
    required this.target,
    required this.label,
    this.page,
    this.condition,
    this.children = const [],
  });

  /// A horizontal rule between entries.
  factory IniMenuItem.separator() =>
      const IniMenuItem(target: 'std_separator', label: '');

  /// The screen this entry opens. Empty for separators and groups.
  final String target;

  /// Display label. May carry a `&` accelerator marker.
  final String label;

  /// Page the target edits, where the entry names one.
  ///
  /// Only meaningful for TunerStudio's built-in editors, which need telling
  /// which page to show. Generated dialogs find their pages through the
  /// constants they reference.
  final int? page;

  /// Expression gating whether this entry is offered at all.
  final String? condition;

  /// Entries nested under a `groupMenu`.
  final List<IniMenuItem> children;

  /// Whether this is a separator rather than a destination.
  bool get isSeparator => target == 'std_separator';

  /// Whether this entry groups others rather than opening a screen itself.
  bool get isGroup => children.isNotEmpty;

  /// Whether the target is one of TunerStudio's own built-in editors.
  ///
  /// These are sensor-calibration wizards and an SD-card browser that live in
  /// TunerStudio rather than in the definition, so there is nothing here to
  /// generate a screen from.
  bool get isBuiltIn => target.startsWith('std_') && !isSeparator;

  /// [label] with the `&` accelerator marker removed.
  String get displayLabel => stripAccelerator(label);

  @override
  String toString() => 'subMenu $target ("$label")';
}

/// A top-level menu, e.g. "Settings" or "Tuning".
class IniMenu {
  IniMenu({required this.label, List<IniMenuItem>? items})
      : items = items ?? <IniMenuItem>[];

  /// Display label. May carry a `&` accelerator marker.
  final String label;

  /// Entries in source order, separators included.
  final List<IniMenuItem> items;

  /// [label] with the `&` accelerator marker removed.
  String get displayLabel => stripAccelerator(label);

  /// Entries excluding separators, with groups flattened away.
  ///
  /// Useful for search, where a nesting level the user cannot see should not
  /// hide an entry from them.
  List<IniMenuItem> get leaves => [
        for (final item in items)
          if (!item.isSeparator) ...item.isGroup ? item.children : [item],
      ];

  @override
  String toString() => 'menu "$label" (${items.length} items)';
}

/// Removes the `&` that marks a keyboard accelerator in a menu label.
///
/// `&Tuning` is TunerStudio's way of saying Alt-T opens that menu; shown
/// verbatim it reads as a typo. A doubled `&&` is a literal ampersand.
String stripAccelerator(String label) => label
    .replaceAll('&&', '\u0000')
    .replaceAll('&', '')
    .replaceAll('\u0000', '&');
