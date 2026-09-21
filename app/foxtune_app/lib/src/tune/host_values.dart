import 'dart:async';

import 'package:foxtune_tune/foxtune_tune.dart';

import '../storage/json_store.dart';

/// Keeps host-side values - Gauge Limits and the like - between sessions.
///
/// These are `[PcVariables]`: nothing on the ECU holds them, so without this a
/// warning point set today is back at its factory value tomorrow.
class HostValues {
  const HostValues(this._store);

  final JsonStore _store;

  static String _path(TuneState tune) =>
      'host/${ecuFamily(tune.definition.identity.signature)}.json';

  /// Puts back what was saved for this ECU, and returns what is now in force.
  Future<Map<String, List<double>>> restoreInto(TuneState tune) async {
    final saved = await _store.read(_path(tune));
    if (saved is Map) {
      tune.restoreHost({
        for (final entry in saved.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: [
              for (final v in entry.value as List)
                if (v is num) v.toDouble(),
            ],
      });
    }
    return tune.hostOverrides();
  }

  /// Saves [tune]'s host values if they differ from [previous].
  ///
  /// Returns what is now saved. Comparing first keeps this cheap enough to
  /// call on every edit, which is what lets it be called from one place.
  Map<String, List<double>> saveIfChanged(
    TuneState tune,
    Map<String, List<double>> previous,
  ) {
    final current = tune.hostOverrides();
    if (_same(current, previous)) return previous;
    // Not awaited: the edit has already happened, and a slow disk must not
    // hold up the screen that made it. The store reports its own failures.
    unawaited(_store.write(_path(tune), current));
    return current;
  }

  static bool _same(Map<String, List<double>> a, Map<String, List<double>> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || other.length != entry.value.length) return false;
      for (var i = 0; i < other.length; i++) {
        if (other[i] != entry.value[i]) return false;
      }
    }
    return true;
  }
}
