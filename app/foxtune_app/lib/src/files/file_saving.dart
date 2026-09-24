import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How files are saved and opened on this platform.
final fileSavingProvider = Provider<FileSaving>((ref) => FileSaving.platform());

/// A file the user picked, read into memory.
class PickedFile {
  const PickedFile({required this.name, required this.bytes});

  /// The file's name, without any directory.
  final String name;

  /// Its contents.
  final Uint8List bytes;

  /// The contents as text.
  ///
  /// Tune files declare ISO-8859-1, and one written by TunerStudio can carry a
  /// degree sign or an accented comment that is not valid UTF-8. Reading
  /// strictly as UTF-8 would refuse such a file outright, so a malformed read
  /// falls back to Latin-1, which accepts every byte.
  String get text {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}

/// The user picked a file of the wrong kind.
class WrongFileTypeException implements Exception {
  const WrongFileTypeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Saving and opening files, the same way on a phone and a desktop.
///
/// Saving is the same everywhere: the picker is handed the bytes and writes
/// the file itself. Opening is not. Android drops any extension without a
/// registered MIME type from a picker's filter - which is every one FoxTune
/// uses - so filtering there is done by checking the chosen file's name
/// instead.
class FileSaving {
  const FileSaving({required this.mobile});

  /// The behaviour for the platform this is running on.
  factory FileSaving.platform() =>
      FileSaving(mobile: Platform.isAndroid || Platform.isIOS);

  /// Whether the platform picker cannot filter by FoxTune's extensions.
  final bool mobile;

  /// Saves [bytes] where the user chooses.
  ///
  /// Returns the name it was saved under, or `null` if the user cancelled.
  Future<String?> saveBytes({
    required String fileName,
    required String extension,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    final saved = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    );
    if (saved == null) return null;
    return _savedName(saved, offered: fileName, extension: extension);
  }

  /// The name [saved] ended up under, for telling the user.
  ///
  /// A desktop picker returns a `file:` URI ending in that name. Android
  /// returns a `content:` URI, which usually ends in a document ID carrying
  /// it, such as `primary:Download/tune.msq` - but some providers use an
  /// opaque ID like `msf:1000`, and then the name it was offered under stands
  /// in.
  static String _savedName(
    Uri saved, {
    required String offered,
    required String extension,
  }) {
    final last = saved.pathSegments.lastOrNull ?? '';
    if (saved.isScheme('file')) return last;
    final name = last.split(RegExp(r'[/:]')).last;
    return name.toLowerCase().endsWith('.${extension.toLowerCase()}')
        ? name
        : offered;
  }

  /// Saves [text] where the user chooses. See [saveBytes].
  Future<String?> saveText({
    required String fileName,
    required String extension,
    required String text,
    String? dialogTitle,
  }) => saveBytes(
    fileName: fileName,
    extension: extension,
    bytes: utf8.encode(text),
    dialogTitle: dialogTitle,
  );

  /// Asks the user for a file with one of [extensions] and reads it.
  ///
  /// Returns `null` if they cancelled. Throws [WrongFileTypeException] if they
  /// chose a file of another kind, which a phone's picker cannot prevent.
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async {
    final file = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: mobile ? FileType.any : FileType.custom,
      allowedExtensions: mobile ? null : extensions,
    );
    if (file == null) return null;

    final name = file.name;
    final lower = name.toLowerCase();
    if (!extensions.any((e) => lower.endsWith('.${e.toLowerCase()}'))) {
      final expected = extensions.map((e) => '.$e').join(' or ');
      throw WrongFileTypeException('"$name" is not a $expected file.');
    }

    try {
      return PickedFile(name: name, bytes: await file.readAsBytes());
    } on Exception {
      throw WrongFileTypeException('"$name" could not be read.');
    }
  }
}
