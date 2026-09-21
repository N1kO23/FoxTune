import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Where FoxTune keeps what it remembers between sessions.
final appStorageDirectoryProvider = FutureProvider<Directory>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory('${documents.path}/FoxTune');
});

/// Small JSON documents kept between sessions.
final jsonStoreProvider = Provider<JsonStore>(
  (ref) => JsonStore(() => ref.read(appStorageDirectoryProvider.future)),
);

/// The part of an ECU signature that stays the same across firmware releases.
///
/// `speeduino 202504-dev` and `speeduino 202501` are the same ECU to a tuner:
/// their gauge limits and dashboard layout should carry over an update rather
/// than vanish with it. A different ECU - a rusEFI, later - gets its own.
String ecuFamily(String? signature) {
  final first = (signature ?? '').trim().split(RegExp(r'\s+')).first;
  final safe = first.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
  return safe.isEmpty ? 'unknown' : safe;
}

/// Reads and writes JSON files under the app's storage folder.
///
/// Everything here is a convenience - a remembered layout, a remembered gauge
/// limit - so failures are reported and swallowed rather than thrown. Losing a
/// saved layout is annoying; an edit failing because a save failed would be
/// far worse.
///
/// The file work itself is synchronous. These are documents of a few
/// kilobytes, where a blocking write costs well under a millisecond, and doing
/// it in one step means two quick edits cannot have their writes land out of
/// order.
class JsonStore {
  JsonStore(this._root);

  final Future<Directory> Function() _root;

  /// Reads [path], or returns `null` if it is missing or unreadable.
  Future<Object?> read(String path) async {
    try {
      final file = File('${(await _root()).path}/$path');
      if (!file.existsSync()) return null;
      return jsonDecode(file.readAsStringSync());
    } on Object catch (error) {
      debugPrint('FoxTune: could not read $path: $error');
      return null;
    }
  }

  /// Writes [value] to [path].
  ///
  /// Written to a temporary file and renamed into place, so a crash or a flat
  /// battery mid-write leaves the previous version rather than half a file.
  Future<void> write(String path, Object value) async {
    try {
      final file = File('${(await _root()).path}/$path');
      file.parent.createSync(recursive: true);
      File('${file.path}.tmp')
        ..writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(value),
          flush: true,
        )
        ..renameSync(file.path);
    } on Object catch (error) {
      debugPrint('FoxTune: could not write $path: $error');
    }
  }
}
