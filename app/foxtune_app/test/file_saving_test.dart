import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/files/file_saving.dart';

/// Stands in for the platform picker, recording what it was asked.
class _FakePicker extends FilePicker {
  _FakePicker({this.savePath, this.picked});

  final String? savePath;
  final PlatformFile? picked;

  FileType? lastType;
  List<String>? lastExtensions;
  Uint8List? lastBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    lastType = type;
    lastExtensions = allowedExtensions;
    lastBytes = bytes;
    return savePath;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastType = type;
    lastExtensions = allowedExtensions;
    final file = picked;
    return file == null ? null : FilePickerResult([file]);
  }
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('foxtune_files'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('saving', () {
    test(
      'on desktop, writes the file the picker only chose a path for',
      () async {
        final target = '${temp.path}/tune.msq';
        final picker = _FakePicker(savePath: target);
        FilePicker.platform = picker;

        final saved = await const FileSaving(mobile: false)
            .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

        expect(saved, 'tune.msq');
        expect(File(target).readAsStringSync(), '<msq/>');
        expect(picker.lastType, FileType.custom);
        expect(picker.lastExtensions, ['msq']);
      },
    );

    test(
      'on a phone, hands over the bytes and leaves the writing to it',
      () async {
        // Android's picker refuses to save without the bytes, writes them
        // itself, and returns a path this process may not be able to open.
        final target = '${temp.path}/not-for-us.msq';
        final picker = _FakePicker(savePath: target);
        FilePicker.platform = picker;

        await const FileSaving(mobile: true)
            .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

        expect(utf8.decode(picker.lastBytes!), '<msq/>');
        expect(File(target).existsSync(), isFalse);
        // `.msq` has no MIME type, so an Android filter would silently drop it.
        expect(picker.lastType, FileType.any);
        expect(picker.lastExtensions, isNull);
      },
    );

    test('a cancelled save writes nothing', () async {
      FilePicker.platform = _FakePicker();

      final saved = await const FileSaving(mobile: false)
          .saveText(fileName: 'tune.msq', extension: 'msq', text: '<msq/>');

      expect(saved, isNull);
      expect(temp.listSync(), isEmpty);
    });
  });

  group('opening', () {
    PlatformFile file(String name, List<int> bytes) => PlatformFile(
      name: name,
      size: bytes.length,
      bytes: Uint8List.fromList(bytes),
    );

    test('reads a file of the right kind', () async {
      FilePicker.platform = _FakePicker(
        picked: file('base.MSQ', utf8.encode('<msq/>')),
      );

      final picked = await const FileSaving(mobile: true)
          .pickFile(extensions: const ['msq']);

      expect(picked!.name, 'base.MSQ');
      expect(picked.text, '<msq/>');
    });

    test(
      'refuses a file of another kind, which a phone cannot filter out',
      () async {
        FilePicker.platform = _FakePicker(
          picked: file('photo.jpg', const [0xFF, 0xD8]),
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

    test('reads a Latin-1 tune that is not valid UTF-8', () async {
      // TunerStudio writes `.msq` as ISO-8859-1; a degree sign there is a
      // single 0xB0 byte, which strict UTF-8 decoding rejects.
      FilePicker.platform = _FakePicker(
        picked: file('tune.msq', latin1.encode('<units>°C</units>')),
      );

      final picked = await const FileSaving(mobile: false)
          .pickFile(extensions: const ['msq']);

      expect(picked!.text, '<units>°C</units>');
    });
  });
}
