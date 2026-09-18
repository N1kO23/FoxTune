import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:test/test.dart';

const _definitionSource = '''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 2
pageSize   = 8, 16
page = 1
  aByte   = scalar, U08,  0, "x", 1.0,  0.0, 0.0, 255.0, 0
  aWord   = scalar, U16,  1, "x", 1.0,  0.0, 0.0, 65535.0, 0
  aSigned = scalar, S08,  3, "x", 1.0,  0.0, -128.0, 127.0, 0
  scaled  = scalar, U08,  4, "V", 0.1,  0.0, 0.0, 25.5, 1
page = 2
  values = array, U08, 0, [16], "%", 1.0, 0.0, 0.0, 255.0, 0
''';

IniDocument get definition => IniParser().parse(_definitionSource);

void main() {
  group('construction', () {
    test('allocates pages at the declared sizes', () {
      final tune = TuneState.empty(definition);
      expect(tune.pageCount, 2);
      expect(tune.page(1), hasLength(8));
      expect(tune.page(2), hasLength(16));
      expect(tune.isDirty, isFalse);
    });

    test('accepts pages read from an ECU', () {
      final tune = TuneState.fromPages(definition, [
        Uint8List(8)..[0] = 42,
        Uint8List(16),
      ]);
      expect(tune.page(1)[0], 42);
    });

    test('rejects a page of the wrong size', () {
      // A short page means the definition does not match the ECU; accepting it
      // would put every later offset in the wrong place.
      expect(
        () => TuneState.fromPages(definition, [Uint8List(4), Uint8List(16)]),
        throwsArgumentError,
      );
    });

    test('rejects the wrong number of pages', () {
      expect(() => TuneState.fromPages(definition, [Uint8List(8)]),
          throwsArgumentError);
    });

    test('copies do not share storage', () {
      final tune = TuneState.empty(definition);
      final copy = tune.copy();
      final field = tune.locate('aByte')!;
      tune.writeRaw(field.page, field.field, 99);

      expect(tune.page(1)[0], 99);
      expect(copy.page(1)[0], 0, reason: 'a snapshot must not move with edits');
    });
  });

  group('raw access', () {
    late TuneState tune;

    setUp(() => tune = TuneState.empty(definition));

    test('round-trips each integer width', () {
      for (final (name, value) in const [
        ('aByte', 200),
        ('aWord', 40000),
        ('aSigned', -50),
      ]) {
        final f = tune.locate(name)!;
        tune.writeRaw(f.page, f.field, value);
        expect(tune.readRaw(f.page, f.field), value, reason: name);
      }
    });

    test('stores multi-byte values little-endian', () {
      final f = tune.locate('aWord')!;
      tune.writeRaw(f.page, f.field, 0x1234);
      // Offset 1, low byte first.
      expect(tune.page(1)[1], 0x34);
      expect(tune.page(1)[2], 0x12);
    });

    test('clamps rather than wrapping around', () {
      // 256 wrapping to 0 in a U08 would turn a rich cell into a lean one.
      final f = tune.locate('aByte')!;
      tune.writeRaw(f.page, f.field, 300);
      expect(tune.readRaw(f.page, f.field), 255);

      tune.writeRaw(f.page, f.field, -5);
      expect(tune.readRaw(f.page, f.field), 0);
    });

    test('clamps signed types at both ends', () {
      final f = tune.locate('aSigned')!;
      tune.writeRaw(f.page, f.field, 500);
      expect(tune.readRaw(f.page, f.field), 127);
      tune.writeRaw(f.page, f.field, -500);
      expect(tune.readRaw(f.page, f.field), -128);
    });

    test('indexes into an array field', () {
      final f = tune.locate('values')!;
      for (var i = 0; i < 16; i++) {
        tune.writeRaw(f.page, f.field, i * 2, i);
      }
      expect(tune.readRaw(f.page, f.field, 5), 10);
      expect(tune.page(2)[5], 10);
    });

    test('refuses to write outside a page', () {
      final f = tune.locate('values')!;
      expect(() => tune.writeRaw(f.page, f.field, 1, 99), throwsRangeError);
    });

    test('reads outside a page as unavailable', () {
      final f = tune.locate('values')!;
      expect(tune.readRaw(f.page, f.field, 99), isNull);
    });
  });

  group('dirty tracking', () {
    test('marks only the page that changed', () {
      final tune = TuneState.empty(definition);
      final f = tune.locate('values')!;
      tune.writeRaw(f.page, f.field, 1, 0);

      expect(tune.isDirty, isTrue);
      expect(tune.dirtyPages, {2});
    });

    test('clears after a successful burn', () {
      final tune = TuneState.empty(definition);
      final f = tune.locate('aByte')!;
      tune.writeRaw(f.page, f.field, 1);

      tune.markClean(1);
      expect(tune.isDirty, isFalse);
    });

    test('setPage from the ECU does not mark dirty', () {
      // Data just read back from the ECU is by definition in sync with it.
      final tune = TuneState.empty(definition);
      tune.setPage(1, Uint8List(8)..[0] = 7);
      expect(tune.isDirty, isFalse);
    });
  });

  group('diff', () {
    test('reports contiguous changed ranges', () {
      final before = TuneState.empty(definition);
      final after = before.copy();
      final f = after.locate('values')!;
      after.writeRaw(f.page, f.field, 5, 2);
      after.writeRaw(f.page, f.field, 6, 3);
      after.writeRaw(f.page, f.field, 9, 10);

      final diff = before.diff(after);
      expect(diff.keys, {2});
      expect(diff[2], [
        (offset: 2, length: 2),
        (offset: 10, length: 1),
      ]);
    });

    test('is empty for identical tunes', () {
      final tune = TuneState.empty(definition);
      expect(tune.diff(tune.copy()), isEmpty);
    });
  });
}
