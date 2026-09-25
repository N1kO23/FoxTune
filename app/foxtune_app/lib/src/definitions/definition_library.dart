import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../app_settings/app_settings.dart';
import '../storage/json_store.dart';

/// Fetches [url], returning its body, or `null` when the server has no such
/// file. Throws when the server cannot be reached.
typedef DefinitionFetcher = Future<String?> Function(Uri url);

/// Where a definition came from.
enum DefinitionSource {
  /// Shipped with FoxTune: the Speeduino release it was built against.
  bundled,

  /// Kept on this device from an earlier connection.
  ///
  /// Also how a kept definition is listed when nothing says how it came to be
  /// kept - one kept before FoxTune started noting that.
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

/// A definition that reads, but is not one to keep.
class DefinitionRefusedException implements Exception {
  const DefinitionRefusedException(this.message);

  /// Why, fit to show a user.
  final String message;

  @override
  String toString() => message;
}

/// A definition for the same firmware is kept already.
class DefinitionExistsException implements Exception {
  const DefinitionExistsException(this.signature);

  final String signature;

  @override
  String toString() => 'A definition for "$signature" is kept already.';
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

/// Where speeduino.com lists the firmware versions it publishes, one a line.
///
/// The same list SpeedyLoader, Speeduino's own firmware loader, offers
/// versions from.
final speeduinoVersionsUrl = Uri.https('speeduino.com', '/fw/versions');

/// Where speeduino.com publishes the definition for [version], one of those
/// [speeduinoVersionsUrl] lists.
Uri speeduinoDefinitionUrl(String version) =>
    Uri.https('speeduino.com', '/fw/$version.ini');

final _speeduinoSignature = RegExp(r'^speeduino (\d{6})(\S*)$');

bool _isSpeeduinoRelease(String signature) =>
    _speeduinoSignature.firstMatch(signature.trim())?.group(2)?.isEmpty ??
    false;

/// Which of the [versions] speeduino.com lists [signature] belongs to, or
/// `null` if none.
///
/// A release reports just its year and month, and goes on reporting it through
/// its revisions: the definition speeduino.com has for `202501.7` declares
/// `speeduino 202501`, as the one for `201902b` declares `speeduino 201902`.
/// So the newest revision of that month stands for it. A development build -
/// `speeduino 202504-dev` - is not published at all.
String? speeduinoRelease(String signature, Iterable<String> versions) {
  final match = _speeduinoSignature.firstMatch(signature.trim());
  if (match == null || match.group(2)!.isNotEmpty) return null;
  final month = match.group(1)!;

  String? newest;
  var newestRevision = -1;
  for (final line in versions) {
    final version = line.trim();
    if (!version.startsWith(month)) continue;
    final revision = _revisionOf(version.substring(month.length));
    if (revision != null && revision > newestRevision) {
      newest = version;
      newestRevision = revision;
    }
  }
  return newest;
}

/// Which revision of its month a speeduino.com version's [suffix] names: `0`
/// for none, `7` for `.7`, and `2` for `b`, as it lettered them once. `null`
/// for anything else.
int? _revisionOf(String suffix) {
  if (suffix.isEmpty) return 0;
  if (suffix.startsWith('.')) return int.tryParse(suffix.substring(1));
  if (RegExp(r'^[a-z]$').hasMatch(suffix)) {
    return suffix.codeUnitAt(0) - 'a'.codeUnitAt(0) + 1;
  }
  return null;
}

/// The site [ecu]'s definition can be downloaded from, or `null` when there is
/// nowhere to try.
String? definitionDownloadSite(EcuIdentification ecu) => switch (ecu.family) {
  EcuFamily.rusefi when rusEfiDefinitionUrl(ecu.signature) != null =>
    'rusefi.com',
  EcuFamily.speeduino when _isSpeeduinoRelease(ecu.signature) =>
    'speeduino.com',
  _ => null,
};

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
///
/// Says it is FoxTune. speeduino.com turns away `Dart/3.x (dart:io)`, the
/// user agent sent otherwise, with a 403 - which would read as the site being
/// down.
Future<String?> fetchDefinitionOverHttp(Uri url) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'FoxTune (+https://github.com/N1kO23/FoxTune)';
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

/// One definition FoxTune has, as the list of them shows it.
class DefinitionEntry {
  const DefinitionEntry({
    required this.signature,
    required this.source,
    this.added,
    this.fileName,
    this.url,
    this.sizeBytes,
    this.file,
    this.problem,
  });

  /// What an ECU must report for this definition to apply; `null` for a file
  /// that could not be read.
  final String? signature;

  /// [DefinitionSource.bundled] for the one built in. For a kept one, how it
  /// came to be kept - [DefinitionSource.cached] where nothing says.
  final DefinitionSource source;

  /// When it was kept.
  final DateTime? added;

  /// The file it was chosen from, where it was chosen from one.
  final String? fileName;

  /// Where it was downloaded from, where it was downloaded.
  final Uri? url;

  final int? sizeBytes;

  /// The kept file; `null` for the one built in.
  final File? file;

  /// Why the file cannot be used, when it cannot. Such an entry can only be
  /// removed.
  final String? problem;

  bool get isBuiltIn => file == null;

  /// What to call it: its signature, or failing that its file's name.
  String get name =>
      signature ?? file?.uri.pathSegments.lastOrNull ?? 'Unknown definition';

  /// A name to offer when saving a copy.
  String get suggestedFileName =>
      file?.uri.pathSegments.lastOrNull ??
      DefinitionLibrary._fileName(signature ?? 'definition');
}

/// Every definition FoxTune has, and the one for whatever ECU is connected.
///
/// A definition has to describe the exact firmware build: page offsets move
/// between releases, and a definition for the wrong one writes settings into
/// the wrong bytes. So a signature is looked up in order of how little it
/// costs:
///
/// 1. the Speeduino definition FoxTune ships with;
/// 2. one kept on this device - from an earlier connection, or added by the
///    user ahead of one;
/// 3. where allowed, the one the firmware project publishes for that exact
///    build: rusEFI for each build, Speeduino for each release.
///
/// Failing all three, the user is asked for the file, which is then kept too.
///
/// Each kept definition is a `.ini` named for its signature, with a `.json`
/// note beside it saying where it came from and when. Only the `.ini` is ever
/// needed to connect; the note is for the list.
class DefinitionLibrary {
  DefinitionLibrary({
    required this._bundled,
    required this._storage,
    required this._fetch,
    this._bundledSource,
    this._symbols = const {},
    this._autoDownload = const {EcuFamily.speeduino, EcuFamily.rusefi},
  });

  final Future<IniDocument> Function() _bundled;
  final Future<String> Function()? _bundledSource;
  final Future<Directory?> Function() _storage;
  final DefinitionFetcher _fetch;
  final Set<String> _symbols;

  /// The firmwares [find] downloads a definition for unasked.
  final Set<EcuFamily> _autoDownload;

  /// The Speeduino definition FoxTune ships with.
  Future<IniDocument> bundled() => _bundled();

  IniDocument _parse(String source) =>
      IniParser(defined: _symbols).parse(source);

  // --- Finding the connected ECU's definition -------------------------------

  /// Looks for the definition of [ecu].
  ///
  /// Downloads it if it is on neither this device nor built in, when
  /// [download] says to - by default, when automatic downloads are on.
  Future<DefinitionLookup> find(EcuIdentification ecu, {bool? download}) async {
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

    final site = definitionDownloadSite(ecu);
    if (site != null && !(download ?? _autoDownload.contains(ecu.family))) {
      return DefinitionMissing(
        'No definition for this firmware version is on this device, and '
        'downloading one from $site is turned off - see ECU definitions, in '
        'App settings.',
      );
    }
    return _download(ecu);
  }

  /// Downloads [ecu]'s definition from where its firmware project publishes
  /// it, and keeps it.
  Future<DefinitionLookup> _download(EcuIdentification ecu) async {
    final signature = ecu.signature;

    final Uri url;
    switch (ecu.family) {
      case EcuFamily.rusefi:
        final published = rusEfiDefinitionUrl(signature);
        if (published == null) {
          return const DefinitionMissing(
            'This signature is not in the form rusEFI publishes definitions '
            'under, so there is nothing to download.',
          );
        }
        url = published;

      case EcuFamily.speeduino:
        if (!_isSpeeduinoRelease(signature)) {
          return const DefinitionMissing(
            'This is a development build of Speeduino. speeduino.com '
            'publishes definitions for releases only; a development '
            "build's is reference/speeduino.ini in its source.",
          );
        }
        final String? versions;
        try {
          versions = await _fetch(speeduinoVersionsUrl);
        } on Object catch (error) {
          return DefinitionMissing(
            'Could not reach speeduino.com to download the definition '
            '($error).',
          );
        }
        final release = versions == null
            ? null
            : speeduinoRelease(
                signature,
                const LineSplitter().convert(versions),
              );
        if (release == null) {
          return const DefinitionMissing(
            'speeduino.com does not list this release, so there is no '
            'definition to download.',
          );
        }
        url = speeduinoDefinitionUrl(release);

      case EcuFamily.other:
        return const DefinitionMissing(
          'No definition for this firmware version is on this device.',
        );
    }

    final String? source;
    try {
      source = await _fetch(url);
    } on Object catch (error) {
      return DefinitionMissing(
        'Could not reach ${url.host} to download the definition ($error).',
      );
    }
    if (source == null) {
      return DefinitionMissing(switch (ecu.family) {
        EcuFamily.rusefi =>
          'rusefi.com has no definition for this build - a firmware built '
              'locally, such as the simulator, never uploads one.',
        _ => '${url.host} has no definition for this release.',
      });
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
      return DefinitionMissing(
        'The definition ${url.host} sent is for a different build.',
      );
    }
    await _keepQuietly(
      signature,
      source,
      from: DefinitionSource.downloaded,
      url: url,
    );
    return DefinitionFound(definition, DefinitionSource.downloaded);
  }

  /// Takes a definition the user chose for the ECU reporting [signature].
  ///
  /// Refused, with [DefinitionMismatchException], unless it describes that
  /// exact build. Kept on this device once accepted, so the next connection
  /// finds it without asking.
  Future<IniDocument> adopt(
    String source, {
    required String signature,
    String? fileName,
  }) async {
    final definition = _parse(source);
    if (!definition.matchesSignature(signature)) {
      throw DefinitionMismatchException(
        ecu: signature,
        file: definition.identity.signature,
      );
    }
    await _keepQuietly(
      signature,
      source,
      from: DefinitionSource.picked,
      fileName: fileName,
    );
    return definition;
  }

  // --- The collection -------------------------------------------------------

  /// Every definition FoxTune has: the one built in first, then those kept on
  /// this device, the most recently kept first.
  ///
  /// Tidies up as it goes. A kept definition without a note - kept before
  /// notes were written - is read once for its signature and given one; one
  /// dropped into the folder under another name is moved to the name a
  /// connection looks for.
  Future<List<DefinitionEntry>> list() async {
    final bundled = await _bundled();
    final kept = <DefinitionEntry>[];
    final folder = await _folder();
    if (folder != null && folder.existsSync()) {
      for (final file in folder.listSync().whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.ini')) continue;
        kept.add(_entryFor(file, folder));
      }
    }
    final never = DateTime.fromMillisecondsSinceEpoch(0);
    kept.sort((a, b) => (b.added ?? never).compareTo(a.added ?? never));
    return [
      DefinitionEntry(
        signature: bundled.identity.signature,
        source: DefinitionSource.bundled,
      ),
      ...kept,
    ];
  }

  /// Keeps [source], a definition the user added from a file called
  /// [fileName], without an ECU to check it against.
  ///
  /// It has to read, and has to declare a signature - no ECU could ever be
  /// matched to one that does not. The definition FoxTune ships is not kept a
  /// second time, and one already kept for the same firmware is replaced only
  /// with [replace]; otherwise this throws [DefinitionExistsException].
  Future<DefinitionEntry> add(
    String source, {
    required String fileName,
    bool replace = false,
  }) => _store(
    source,
    from: DefinitionSource.picked,
    fileName: fileName,
    replace: replace,
  );

  /// The versions speeduino.com has definitions for, newest first: its
  /// releases, then `master` - the development build as it stands.
  ///
  /// Its list names more than definitions - `EEPROM_clear` is a firmware that
  /// wipes the settings - so only those are given.
  Future<List<String>> speeduinoVersions() async {
    final String? list;
    try {
      list = await _fetch(speeduinoVersionsUrl);
    } on Object catch (error) {
      throw DefinitionRefusedException(
        'Could not reach speeduino.com ($error).',
      );
    }
    if (list == null) {
      throw const DefinitionRefusedException(
        'speeduino.com has no list of versions.',
      );
    }
    final versions = [
      for (final line in const LineSplitter().convert(list)) line.trim(),
    ];
    return [
      for (final version in versions)
        if (RegExp(r'^\d{6}').hasMatch(version)) version,
      if (versions.contains('master')) 'master',
    ];
  }

  /// Downloads and keeps the definition speeduino.com has for [version], one
  /// of [speeduinoVersions]. As [add] for [replace].
  Future<DefinitionEntry> downloadSpeeduino(
    String version, {
    bool replace = false,
  }) => _fetchAndKeep(speeduinoDefinitionUrl(version), replace: replace);

  /// Downloads and keeps the definition rusEFI publishes for the build that
  /// reports [signature]. As [add] for [replace].
  Future<DefinitionEntry> downloadRusEfi(
    String signature, {
    bool replace = false,
  }) async {
    final url = rusEfiDefinitionUrl(signature);
    if (url == null) {
      throw DefinitionRefusedException(
        '"${signature.trim()}" is not a signature rusEFI publishes '
        'definitions under.',
      );
    }
    return _fetchAndKeep(url, replace: replace, expected: signature.trim());
  }

  Future<DefinitionEntry> _fetchAndKeep(
    Uri url, {
    required bool replace,
    String? expected,
  }) async {
    final String? source;
    try {
      source = await _fetch(url);
    } on Object catch (error) {
      throw DefinitionRefusedException('Could not reach ${url.host} ($error).');
    }
    if (source == null) {
      throw DefinitionRefusedException(
        '${url.host} has no definition for that build.',
      );
    }
    return _store(
      source,
      from: DefinitionSource.downloaded,
      url: url,
      replace: replace,
      expected: expected,
    );
  }

  /// Keeps [source], with no ECU to check it against - see [add].
  ///
  /// Where [expected] is given, the definition has to be for that signature.
  Future<DefinitionEntry> _store(
    String source, {
    required DefinitionSource from,
    required bool replace,
    String? fileName,
    Uri? url,
    String? expected,
  }) async {
    final definition = _parse(source);
    final signature = definition.identity.signature?.trim() ?? '';
    if (signature.isEmpty) {
      throw const DefinitionRefusedException(
        'It declares no signature, so no ECU could ever be matched to it.',
      );
    }
    if (expected != null && signature != expected) {
      throw DefinitionRefusedException(
        'It is the definition for "$signature", not "$expected".',
      );
    }
    if ((await _bundled()).matchesSignature(signature)) {
      throw DefinitionRefusedException(
        'The definition for "$signature" is built into FoxTune already.',
      );
    }
    final existing = await _cacheFile(signature);
    if (!replace && (existing?.existsSync() ?? false)) {
      throw DefinitionExistsException(signature);
    }
    final file = await _keep(
      signature,
      source,
      from: from,
      url: url,
      fileName: fileName,
    );
    return _entryFor(file, file.parent);
  }

  /// Deletes a kept definition, and its note.
  ///
  /// A session using it carries on with the copy it has already read. The
  /// next connection looks for the definition again.
  Future<void> remove(DefinitionEntry entry) async {
    final file = entry.file;
    if (file == null) {
      throw ArgumentError.value(entry.name, 'entry', 'is built in');
    }
    for (final kept in [file, _noteFor(file)]) {
      if (kept.existsSync()) kept.deleteSync();
    }
  }

  /// [entry]'s definition as a file, for saving a copy.
  Future<Uint8List> bytesOf(DefinitionEntry entry) async {
    final file = entry.file;
    if (file != null) return file.readAsBytesSync();
    final bundledSource = _bundledSource;
    if (bundledSource == null) {
      throw StateError('The built-in definition is not available as a file.');
    }
    return utf8.encode(await bundledSource());
  }

  // --- Keeping --------------------------------------------------------------

  static String _fileName(String signature) =>
      '${signature.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.ini';

  /// The note kept beside [definition].
  static File _noteFor(File definition) =>
      File('${definition.path.substring(0, definition.path.length - 4)}.json');

  Future<Directory?> _folder() async {
    final root = await _storage();
    return root == null ? null : Directory('${root.path}/definitions');
  }

  Future<File?> _cacheFile(String signature) async {
    final folder = await _folder();
    return folder == null
        ? null
        : File('${folder.path}/${_fileName(signature)}');
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

  /// Keeps [source], the definition for [signature], with a note of where it
  /// came from.
  ///
  /// Each file is written whole and then moved into place, so a crash
  /// mid-write cannot leave half a definition to be found next time. The
  /// definition goes first: a crash between the two leaves it without its
  /// note, which still connects, and is listed as kept from an earlier
  /// connection.
  Future<File> _keep(
    String signature,
    String source, {
    required DefinitionSource from,
    Uri? url,
    String? fileName,
  }) async {
    final file = await _cacheFile(signature);
    if (file == null) {
      throw const DefinitionRefusedException(
        'There is nowhere on this device to keep definitions.',
      );
    }
    file.parent.createSync(recursive: true);
    _writeWhole(file, source);
    _writeWhole(
      _noteFor(file),
      jsonEncode({
        'signature': signature.trim(),
        'source': from.name,
        'url': ?url?.toString(),
        'fileName': ?fileName,
        'added': DateTime.now().toIso8601String(),
      }),
    );
    return file;
  }

  /// [_keep], where keeping is a convenience: the definition is in use either
  /// way, and failing to keep it only means finding it again next time.
  Future<void> _keepQuietly(
    String signature,
    String source, {
    required DefinitionSource from,
    Uri? url,
    String? fileName,
  }) async {
    try {
      await _keep(signature, source, from: from, url: url, fileName: fileName);
    } on Object catch (error) {
      debugPrint('FoxTune: could not keep the definition: $error');
    }
  }

  static void _writeWhole(File file, String contents) {
    File('${file.path}.tmp')
      ..writeAsStringSync(contents, flush: true)
      ..renameSync(file.path);
  }

  // --- Listing --------------------------------------------------------------

  /// The list's entry for the kept definition [file], in [folder].
  DefinitionEntry _entryFor(File file, Directory folder) {
    final size = file.lengthSync();
    final modified = file.lastModifiedSync();
    final note = _readNote(file);
    if (note != null) {
      return DefinitionEntry(
        signature: note['signature'] as String,
        source: switch (DefinitionSource.values.asNameMap()[note['source']]) {
          final source? when source != DefinitionSource.bundled => source,
          _ => DefinitionSource.cached,
        },
        added: switch (note['added']) {
          final String added => DateTime.tryParse(added) ?? modified,
          _ => modified,
        },
        fileName: switch (note['fileName']) {
          final String name => name,
          _ => null,
        },
        url: switch (note['url']) {
          final String url => Uri.tryParse(url),
          _ => null,
        },
        sizeBytes: size,
        file: file,
      );
    }

    // No note. Read the definition for its signature, once, and note it.
    final String signature;
    try {
      final declared = _parse(decodeDefinition(file.readAsBytesSync()))
          .identity
          .signature
          ?.trim();
      if (declared == null || declared.isEmpty) {
        throw const FormatException('it declares no signature');
      }
      signature = declared;
    } on Object catch (error) {
      return DefinitionEntry(
        signature: null,
        source: DefinitionSource.cached,
        added: modified,
        sizeBytes: size,
        file: file,
        problem: 'Could not be read: $error',
      );
    }

    // A connection looks for it by the name its signature gives, so a file
    // under any other name would never be found.
    var named = file;
    final expected = File('${folder.path}/${_fileName(signature)}');
    if (file.path != expected.path) {
      if (expected.existsSync() &&
          !FileSystemEntity.identicalSync(file.path, expected.path)) {
        return DefinitionEntry(
          signature: signature,
          source: DefinitionSource.cached,
          added: modified,
          sizeBytes: size,
          file: file,
          problem: 'Another copy of a definition that is kept already.',
        );
      }
      named = file.renameSync(expected.path);
    }

    try {
      _writeWhole(
        _noteFor(named),
        jsonEncode({
          'signature': signature,
          'source': DefinitionSource.cached.name,
          'added': modified.toIso8601String(),
        }),
      );
    } on Object catch (error) {
      debugPrint('FoxTune: could not note a kept definition: $error');
    }
    return DefinitionEntry(
      signature: signature,
      source: DefinitionSource.cached,
      added: modified,
      sizeBytes: size,
      file: named,
    );
  }

  /// The note kept beside [file], or `null` if there is none that reads.
  static Map<String, Object?>? _readNote(File file) {
    try {
      final note = _noteFor(file);
      if (!note.existsSync()) return null;
      final json = jsonDecode(note.readAsStringSync());
      if (json is! Map<String, Object?> || json['signature'] is! String) {
        return null;
      }
      return json;
    } on Object {
      return null;
    }
  }
}

/// The Speeduino definition FoxTune ships with, as text.
final bundledDefinitionSourceProvider = FutureProvider<String>(
  (ref) => rootBundle.loadString('assets/speeduino.ini'),
);

/// The Speeduino definition FoxTune ships with, parsed for the chosen
/// temperature scale.
///
/// Parsing ~6000 lines takes long enough to be worth keeping off the build
/// path, so this is a future the UI awaits once.
final bundledDefinitionProvider = FutureProvider<IniDocument>((ref) async {
  final source = await ref.watch(bundledDefinitionSourceProvider.future);
  final unit = ref.watch(temperatureUnitProvider);
  return IniParser(defined: unit.iniSymbols).parse(source);
});

/// How a definition is downloaded. Replaced in tests.
final definitionFetcherProvider = Provider<DefinitionFetcher>(
  (ref) => fetchDefinitionOverHttp,
);

/// Every definition FoxTune has, and where the connected ECU's is found.
final definitionLibraryProvider = Provider<DefinitionLibrary>((ref) {
  final unit = ref.watch(temperatureUnitProvider);
  return DefinitionLibrary(
    bundled: () => ref.read(bundledDefinitionProvider.future),
    bundledSource: () => ref.read(bundledDefinitionSourceProvider.future),
    storage: () async {
      try {
        return await ref.read(appStorageDirectoryProvider.future);
      } on Object {
        // Without storage nothing is kept between sessions, but a definition
        // can still be found for this one.
        return null;
      }
    },
    fetch: ref.watch(definitionFetcherProvider),
    symbols: unit.iniSymbols,
    autoDownload: ref.watch(
      appSettingsProvider.select((s) => s.downloadDefinitionsFor),
    ),
  );
});

/// Every definition FoxTune has - see [DefinitionLibrary.list].
///
/// Disposed when nothing shows it, so each time it is shown it is listed
/// afresh: connecting keeps definitions too, not only the list itself.
final definitionEntriesProvider =
    FutureProvider.autoDispose<List<DefinitionEntry>>(
      (ref) => ref.watch(definitionLibraryProvider).list(),
    );
