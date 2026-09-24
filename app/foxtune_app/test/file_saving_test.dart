import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/files/file_saving.dart';

/// Stands in for the platform picker, recording what it was asked.
class _FakePicker extends FilePickerPlatform {
  _FakePicker({this.saved, this.picked});

  final Uri? saved;
  final PlatformFile? picked;

  FileType? lastType;
  List<String>? lastExtensions;
  Uint8List? lastBytes;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    lastBytes = bytes;
    return saved;
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    lastType = type;
    lastExtensions = allowedExtensions;
    return picked;
  }
}

/// A picked file held in memory, or one that fails to read if [bytes] is
/// `null`.
final class _MemoryFile extends PlatformFile {
  _MemoryFile(this.name, this.bytes);

  @override
  final String name;
  final List<int>? bytes;

  @override
  Uri get uri => Uri.file('/picked/$name');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => bytes?.length;

  @override
  Future<int?> length() async => bytes?.length;

  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = this.bytes;
    if (bytes == null) throw FileSystemException('Permission denied', name);
    return Uint8List.fromList(bytes);
  }

  @override
  Stream<Uint8List> readAsByteStream() => Stream.fromFuture(readAsBytes());
}

void main() {
  group('saving', () {
    test('hands the picker the bytes, and leaves the writing to it', () async {
      // Every platform's picker writes the file itself; on Android the path
      // behind it may not even be one this process can open.
      final target = '${Directory.systemTemp.path}/not-for-us.msq';
      final picker = _FakePicker(saved: Uri.file(target));
      FilePickerPlatform.instance = picker;

      final saved = await const FileSaving(mobile: false)
          .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

      expect(saved, 'not-for-us.msq');
      expect(utf8.decode(picker.lastBytes!), '<msq/>');
      expect(File(target).existsSync(), isFalse);
    });

    test('names an Android save after the document it created', () async {
      FilePickerPlatform.instance = _FakePicker(
        saved: Uri.parse(
          'content://com.android.externalstorage.documents/document/'
          'primary%3ADownload%2Fmy-tune.msq',
        ),
      );

      final saved = await const FileSaving(mobile: true)
          .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

      expect(saved, 'my-tune.msq');
    });

    test('falls back to the offered name for an opaque document', () async {
      FilePickerPlatform.instance = _FakePicker(
        saved: Uri.parse(
          'content://com.android.providers.downloads.documents/document/'
          'msf%3A1000',
        ),
      );

      final saved = await const FileSaving(mobile: true)
          .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

      expect(saved, 'tune.msq');
    });

    test('a cancelled save reports nothing saved', () async {
      FilePickerPlatform.instance = _FakePicker();

      final saved = await const FileSaving(mobile: false)
          .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

      expect(saved, isNull);
    });
  });

  group('opening', () {
    test('filters by extension on desktop', () async {
      final picker = _FakePicker();
      FilePickerPlatform.instance = picker;

      await const FileSaving(mobile: false).pickFile(extensions: const ['msq']);

      expect(picker.lastType, FileType.custom);
      expect(picker.lastExtensions, ['msq']);
    });

    test('does not filter on a phone', () async {
      // `.msq` has no MIME type, so an Android filter would silently drop it.
      final picker = _FakePicker();
      FilePickerPlatform.instance = picker;

      await const FileSaving(mobile: true).pickFile(extensions: const ['msq']);

      expect(picker.lastType, FileType.any);
      expect(picker.lastExtensions, isNull);
    });

    test('reads a file of the right kind', () async {
      FilePickerPlatform.instance = _FakePicker(
        picked: _MemoryFile('base.MSQ', utf8.encode('<msq/>')),
      );

      final picked = await const FileSaving(mobile: true)
          .pickFile(extensions: const ['msq']);

      expect(picked!.name, 'base.MSQ');
      expect(picked.text, '<msq/>');
    });

    test(
      'refuses a file of another kind, which a phone cannot filter out',
      () async {
        FilePickerPlatform.instance = _FakePicker(
          picked: _MemoryFile('photo.jpg', const [0xFF, 0xD8]),
        );

        expect(
          const FileSaving(mobile: true).pickFile(extensions: const ['msq']),
          throwsA(
            isA<WrongFileTypeException>().having(
              (e) => e.message,
              'message',
              contains('.msq'),
            ),
          ),
        );
      },
    );

    test('reports a file that cannot be read', () async {
      FilePickerPlatform.instance = _FakePicker(
        picked: _MemoryFile('tune.msq', null),
      );

      expect(
        const FileSaving(mobile: false).pickFile(extensions: const ['msq']),
        throwsA(
          isA<WrongFileTypeException>().having(
            (e) => e.message,
            'message',
            contains('could not be read'),
          ),
        ),
      );
    });

    test('reads a Latin-1 tune that is not valid UTF-8', () async {
      // TunerStudio writes `.msq` as ISO-8859-1; a degree sign there is a
      // single 0xB0 byte, which strict UTF-8 decoding rejects.
      FilePickerPlatform.instance = _FakePicker(
        picked: _MemoryFile('tune.msq', latin1.encode('<units>°C</units>')),
      );

      final picked = await const FileSaving(mobile: false)
          .pickFile(extensions: const ['msq']);

      expect(picked!.text, '<units>°C</units>');
    });
  });
}
