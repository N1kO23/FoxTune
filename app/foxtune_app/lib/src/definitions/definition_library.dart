import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

/// Fetches [url], returning its body, or `null` when the server has no such
/// file. Throws when the server cannot be reached.
typedef DefinitionFetcher = Future<String?> Function(Uri url);

/// Where a definition came from.
enum DefinitionSource {
  /// Shipped with FoxTune: the Speeduino release it was built against.
  bundled,

  /// Kept on this device from an earlier connection.
  cached,

  /// Fetched from the firmware project for this exact build.
  downloaded,

  /// Chosen by the user from a file.
  picked,
}

/// What looking for an ECU's definition came to.
sealed class DefinitionLookup {
  const DefinitionLookup();
}

class DefinitionFound extends DefinitionLookup {
  const DefinitionFound(this.definition, this.source);
  final IniDocument definition;
  final DefinitionSource source;
}

class DefinitionMissing extends DefinitionLookup {
  const DefinitionMissing(this.reason);

  /// Why, fit to show a user.
  final String reason;
}

/// A definition the user chose describes a different ECU.
class DefinitionMismatchException implements Exception {
  const DefinitionMismatchException({required this.ecu, required this.file});

  /// What the connected ECU reports.
  final String ecu;

  /// What the chosen definition is for, where it says.
  final String? file;

  @override
  String toString() =>
      'That definition is for "${file ?? 'an unnamed firmware'}", but the ECU '
      'reports "$ecu".';
}

/// Where rusEFI publishes the definition for [signature], or `null` if the
/// signature is not in the form it publishes under.
///
/// rusEFI builds a definition per board and per build - the signature ends in
/// a hash of the settings layout - and uploads each to a path spelled out by
/// the signature: `rusEFI master.2026.09.21.uaefi.419928595` is at
/// `rusefi/master/2026/09/21/uaefi/419928595.ini`. This is the same scheme its
/// own tools download from.
Uri? rusEfiDefinitionUrl(String signature) {
  final match = RegExp(
    r'^rusEFI ([a-zA-Z0-9_-]+)\.([0-9]{4})\.([0-9]{2})\.([0-9]{2})\.'
    r'([a-zA-Z0-9_-]+)\.([a-zA-Z0-9_-]+)$',
  ).firstMatch(signature.trim());
  if (match == null) return null;
  final [branch, year, month, day, board, hash] = [
    for (var i = 1; i <= 6; i++) match.group(i)!,
  ];
  return Uri.https(
    'rusefi.com',
    '/online/ini/rusefi/$branch/$year/$month/$day/$board/$hash.ini',
  );
}

/// Text from a definition file's bytes.
///
/// Definitions are nominally ASCII, but a degree sign turns up in units, and
/// some are saved as Latin-1 rather than UTF-8. Latin-1 cannot fail, so it is
/// the fallback.
String decodeDefinition(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Fetches a definition over HTTPS.
Future<String?> fetchDefinitionOverHttp(Uri url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(url);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    final body = await response.fold(
      BytesBuilder(copy: false),
      (builder, chunk) => builder..add(chunk),
    );
    return decodeDefinition(body.takeBytes());
  } finally {
    client.close();
  }
}

/// Finds the definition for whatever ECU is connected.
///
/// A definition has to describe the exact firmware build: page offsets move
/// between releases, and a definition for the wrong one writes settings into
/// the wrong bytes. So a signature is looked up in order of how little it
/// costs:
///
/// 1. the Speeduino definition FoxTune ships with;
/// 2. one kept on this device from an earlier connection;
/// 3. for rusEFI, the one rusEFI publishes for that exact build.
///
/// Failing all three, the user is asked for the file, which is then kept too.
class DefinitionLibrary {
  DefinitionLibrary({
    required this._bundled,
    required this._storage,
    required this._fetch,
    this._symbols = const {},
  });

  final Future<IniDocument> Function() _bundled;
  final Future<Directory?> Function() _storage;
  final DefinitionFetcher _fetch;
  final Set<String> _symbols;

  /// The Speeduino definition FoxTune ships with.
  Future<IniDocument> bundled() => _bundled();

  IniDocument _parse(String source) =>
      IniParser(defined: _symbols).parse(source);

  /// Looks for the definition of [ecu].
  Future<DefinitionLookup> find(EcuIdentification ecu) async {
    final signature = ecu.signature;

    final bundled = await _bundled();
    if (bundled.matchesSignature(signature)) {
      return DefinitionFound(bundled, DefinitionSource.bundled);
    }

    final cached = await _readCache(signature);
    if (cached != null) {
      try {
        final definition = _parse(cached);
        if (definition.matchesSignature(signature)) {
          return DefinitionFound(definition, DefinitionSource.cached);
        }
      } on Object catch (error) {
        debugPrint('FoxTune: stored definition for $signature: $error');
      }
    }

    if (ecu.family != EcuFamily.rusefi) {
      return const DefinitionMissing(
        'No definition for this firmware version is on this device.',
      );
    }

    final url = rusEfiDefinitionUrl(signature);
    if (url == null) {
      return const DefinitionMissing(
        'This signature is not in the form rusEFI publishes definitions '
        'under, so there is nothing to download.',
      );
    }

    final String? source;
    try {
      source = await _fetch(url);
    } on Object catch (error) {
      return DefinitionMissing(
        'Could not reach rusefi.com to download the definition ($error).',
      );
    }
    if (source == null) {
      return const DefinitionMissing(
        'rusefi.com has no definition for this build - a firmware built '
        'locally, such as the simulator, never uploads one.',
      );
    }

    final IniDocument definition;
    try {
      definition = _parse(source);
    } on Object catch (error) {
      return DefinitionMissing(
        'The downloaded definition did not read: $error',
      );
    }
    if (!definition.matchesSignature(signature)) {
      return const DefinitionMissing(
        'The definition rusefi.com sent is for a different build.',
      );
    }
    await _writeCache(signature, source);
    return DefinitionFound(definition, DefinitionSource.downloaded);
  }

  /// Takes a definition the user chose for the ECU reporting [signature].
  ///
  /// Refused, with [DefinitionMismatchException], unless it describes that
  /// exact build. Kept on this device once accepted, so the next connection
  /// finds it without asking.
  Future<IniDocument> adopt(String source, {required String signature}) async {
    final definition = _parse(source);
    if (!definition.matchesSignature(signature)) {
      throw DefinitionMismatchException(
        ecu: signature,
        file: definition.identity.signature,
      );
    }
    await _writeCache(signature, source);
    return definition;
  }

  static String _fileName(String signature) =>
      '${signature.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.ini';

  Future<File?> _cacheFile(String signature) async {
    final root = await _storage();
    if (root == null) return null;
    return File('${root.path}/definitions/${_fileName(signature)}');
  }

  Future<String?> _readCache(String signature) async {
    try {
      final file = await _cacheFile(signature);
      if (file == null || !file.existsSync()) return null;
      return decodeDefinition(file.readAsBytesSync());
    } on Object catch (error) {
      debugPrint('FoxTune: could not read a stored definition: $error');
      return null;
    }
  }

  Future<void> _writeCache(String signature, String source) async {
    try {
      final file = await _cacheFile(signature);
      if (file == null) return;
      file.parent.createSync(recursive: true);
      // Written whole and then moved into place, so a crash mid-write cannot
      // leave half a definition to be found next time.
      final partial = File('${file.path}.tmp')..writeAsStringSync(source);
      partial.renameSync(file.path);
    } on Object catch (error) {
      debugPrint('FoxTune: could not keep the definition: $error');
    }
  }
}
