import 'package:foxtune_ini/foxtune_ini.dart';

/// Why writing to a connected ECU is or is not permitted.
///
/// Writing a bad table to a running engine destroys hardware, so permission is
/// something that must be *earned* by positive evidence, never assumed. Every
/// constructor here states a reason, and the default is refusal.
class WritePermission {
  const WritePermission._(this.allowed, this.reason);

  /// Writing is permitted.
  const WritePermission.granted() : this._(true, null);

  /// Writing is refused, with a reason fit to show the user.
  const WritePermission.refused(String reason) : this._(false, reason);

  /// Whether writes may proceed.
  final bool allowed;

  /// Why writes are refused, or `null` when they are permitted.
  final String? reason;

  /// Decides whether this session may write.
  ///
  /// Both conditions are required, and both are about avoiding a specific
  /// disaster:
  ///
  /// * A **signature mismatch** means the definition in hand may not describe
  ///   the ECU on the wire, so every page offset is suspect. Writing under
  ///   those conditions puts arbitrary bytes in arbitrary places.
  /// * **Write mode** must be turned on deliberately. Read-only is the default
  ///   so that connecting to an engine, by itself, can never change it.
  static WritePermission evaluate({
    required IniDocument? definition,
    required String? reportedSignature,
    required bool writeModeEnabled,
  }) {
    if (definition == null) {
      return const WritePermission.refused(
          'No ECU definition is loaded, so the page layout is unknown.');
    }
    final expected = definition.identity.signature;
    if (expected == null) {
      return const WritePermission.refused(
          'The loaded definition declares no signature, so it cannot be '
          'confirmed to match this ECU.');
    }
    if (reportedSignature == null) {
      return const WritePermission.refused(
          'The ECU has not reported a signature.');
    }
    if (!definition.matchesSignature(reportedSignature)) {
      return WritePermission.refused(
          'The ECU reports "$reportedSignature" but the loaded definition is '
          'for "$expected". Page offsets cannot be trusted.');
    }
    if (!writeModeEnabled) {
      return const WritePermission.refused(
          'Write mode is off. Enable it deliberately to make changes.');
    }
    return const WritePermission.granted();
  }

  @override
  String toString() =>
      allowed ? 'WritePermission.granted' : 'WritePermission.refused($reason)';
}

/// Thrown when a write is attempted that the guard rails forbid.
class WriteRefusedException implements Exception {
  WriteRefusedException(this.reason);

  final String reason;

  @override
  String toString() => 'WriteRefusedException: $reason';
}
