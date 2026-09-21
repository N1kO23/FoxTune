import 'package:foxtune_ini/foxtune_ini.dart';

/// Evaluates an expression a definition uses to produce a label.
///
/// Units and titles are not always literal text. A table's load axis declares
/// `bitStringValue(algorithmUnits, algorithm)` - "the option of
/// `algorithmUnits` picked by the `algorithm` setting" - so it reads kPa or %
/// TPS depending on how the engine is set up. The idle load gauge does the same
/// with `iacAlgorithm`.
///
/// Returns `null` for anything else, including `stringValue(...)` over the
/// text aliases FoxTune does not model. Showing the expression source instead
/// - a bare `bitStringValue(al...` - would be worse than showing nothing, so a
/// caller falls back to something plain.
String? evaluateLabel(
  String source, {
  required IniDocument definition,
  required double? Function(String name) resolve,
}) {
  final call = RegExp(r'^bitStringValue\(\s*(\w+)\s*,\s*(\w+)\s*\)$')
      .firstMatch(source.trim());
  if (call == null) return null;

  final options = definition.findField(call.group(1)!);
  final index = resolve(call.group(2)!);
  if (options is! IniBitsField || index == null) return null;

  final label = options.labelFor(index.toInt());
  return label == null || label == 'INVALID' ? null : label;
}

/// Renders a label written as a template: text with `bitStringValue(...)`
/// lookups in it, as a braced indicator label is.
///
/// `Ignition out 1: bitStringValue(outputDiagErrorList, ignitorDiagnostic1)`
/// becomes "Ignition out 1: Open Load". A lookup that cannot be resolved yet -
/// before the first sample arrives - becomes an ellipsis rather than leaving
/// the call's source in a label.
String evaluateLabelTemplate(
  String template, {
  required IniDocument definition,
  required double? Function(String name) resolve,
}) =>
    template
        .replaceAllMapped(
          RegExp(r'bitStringValue\(\s*\w+\s*,\s*\w+\s*\)'),
          (match) =>
              evaluateLabel(
                match.group(0)!,
                definition: definition,
                resolve: resolve,
              ) ??
              '...',
        )
        .trim();

/// What [indicator] says in its [on] or off state, with any lookups in its
/// label resolved through [resolve].
String indicatorLabel(
  IniDialogIndicator indicator, {
  required bool on,
  required IniDocument definition,
  required double? Function(String name) resolve,
}) {
  final text = on ? indicator.onLabel : indicator.offLabel;
  final template =
      on ? indicator.onLabelIsTemplate : indicator.offLabelIsTemplate;
  return template
      ? evaluateLabelTemplate(text, definition: definition, resolve: resolve)
      : text;
}

/// [indicator]'s label with no live data behind it, for lists and titles:
/// lookups become an ellipsis rather than showing their source.
String indicatorLabelText(IniDialogIndicator indicator, {required bool on}) {
  final text = on ? indicator.onLabel : indicator.offLabel;
  final template =
      on ? indicator.onLabelIsTemplate : indicator.offLabelIsTemplate;
  if (!template) return text;
  return text.replaceAll(RegExp(r'bitStringValue\([^)]*\)'), '...').trim();
}
