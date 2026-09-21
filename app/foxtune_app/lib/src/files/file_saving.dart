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
/// The file picker behaves quite differently per platform, and each difference
/// on its own breaks saving:
///
/// - **Android** writes the file itself, through the system "Save to" picker,
///   and refuses to save at all unless it is handed the bytes up front.
/// - **Desktop** only asks where to save and returns a path; writing the file
///   is left to the caller, and the bytes it was given are ignored.
/// - **Android** also drops any extension without a registered MIME type from
///   a picker's filter - which is every one FoxTune uses - so filtering there
///   is done by checking the chosen file's name instead.
class FileSaving {
  const FileSaving({required this.mobile});

  /// The behaviour for the platform this is running on.
  factory FileSaving.platform() =>
      FileSaving(mobile: Platform.isAndroid || Platform.isIOS);

  /// Whether the platform picker writes files itself and cannot filter by
  /// FoxTune's extensions.
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
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    final path = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: mobile ? FileType.any : FileType.custom,
      allowedExtensions: mobile ? null : [extension],
      bytes: data,
    );
    if (path == null) return null;

    // On a phone the picker has already written the file, and the path it
    // returns may not even be one this process can write to.
    if (!mobile) await File(path).writeAsBytes(data, flush: true);

    return path.split(RegExp(r'[/\\]')).last;
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
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: dialogTitle,
      type: mobile ? FileType.any : FileType.custom,
      allowedExtensions: mobile ? null : extensions,
      withData: true,
    );
    final file = result?.files.singleOrNull;
    if (file == null) return null;

    final name = file.name;
    final lower = name.toLowerCase();
    if (!extensions.any((e) => lower.endsWith('.${e.toLowerCase()}'))) {
      final expected = extensions.map((e) => '.$e').join(' or ');
      throw WrongFileTypeException('"$name" is not a $expected file.');
    }

    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) {
      throw WrongFileTypeException('"$name" could not be read.');
    }
    return PickedFile(name: name, bytes: bytes);
  }
}
