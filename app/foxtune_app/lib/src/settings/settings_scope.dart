import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// Everything a generated settings screen needs to decide what to show.
///
/// The definition guards most fields with a `{ ... }` expression, and those
/// expressions are what make a screen like Trigger Setup usable at all: choose
/// a missing-tooth wheel and the tooth-count fields appear, choose a distributor
/// and they go. Answering them needs two sources, because the definition draws
/// on both:
///
/// - stored settings, for nearly everything (`{ TrigPattern == 0 }`);
/// - the realtime feed, for the few that ask what the engine is doing right
///   now (`{ testactive }` in the hardware-test dialog).
///
/// Stored settings win where a name exists in both, matching how the tune
/// itself resolves references.
class SettingsScope {
  SettingsScope({required this.tune, required this.resolver, this.realtime});

  /// The tune being edited.
  final TuneState tune;

  /// Resolver over the tune's own constants.
  final TuneValueResolver resolver;

  /// The most recent realtime sample, where the link is live.
  final RealtimeSnapshot? realtime;

  /// The definition behind the tune.
  IniDocument get definition => tune.definition;

  final Map<String, CompiledExpression?> _compiled = {};

  /// Resolves [name] against the tune, falling back to the realtime feed.
  double? resolve(String name) => resolver.resolve(name) ?? realtime?[name];

  /// Evaluates a `{ ... }` condition.
  ///
  /// An unresolvable condition yields [whenUnknown], which defaults to true -
  /// the field is shown. Hiding on an unknown would be worse: a condition over
  /// a realtime channel cannot be answered before the first sample arrives, and
  /// a screen that hides its contents until the engine is running would be
  /// unusable on the bench. Showing a field that turns out not to apply is
  /// recoverable; hiding one the tuner needs is not.
  bool test(String? condition, {bool whenUnknown = true}) {
    if (condition == null || condition.isEmpty) return true;
    final compiled = _compiled.putIfAbsent(
      condition,
      () => CompiledExpression.tryCompile(condition),
    );
    if (compiled == null) return whenUnknown;
    final value = compiled.evaluate(resolve);
    if (value == null) return whenUnknown;
    return value != 0;
  }

  /// Whether [item] should appear on screen at all.
  bool isVisible(IniDialogItem item) => test(item.visibleCondition);

  /// Whether [item] should be editable.
  ///
  /// TunerStudio greys a field out rather than hiding it when its first
  /// condition is false, which keeps a dialog's shape stable as related
  /// settings change. FoxTune does the same.
  bool isEnabled(IniDialogItem item) => test(item.enableCondition);

  /// A view of the setting named [constant], or `null` if it has none.
  SettingView? setting(String constant, {int index = 0}) =>
      SettingView.of(tune, constant, resolver: resolver, index: index);
}
