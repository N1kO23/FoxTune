import 'package:foxtune_ini/src/preprocessor.dart';
import 'package:test/test.dart';

List<String> lines(String source) => source.trim().split('\n');

List<String> emitted(String source, {Set<String> defined = const {}}) =>
    IniPreprocessor(defined: defined)
        .run(lines(source))
        .lines
        .map((l) => l.text)
        .toList();

void main() {
  group('conditionals', () {
    const source = '''
alpha = 1
#if CELSIUS
temp = C
#else
temp = F
#endif
omega = 2
''';

    test('takes the #if branch when the symbol is defined', () {
      expect(emitted(source, defined: {'CELSIUS'}),
          ['alpha = 1', 'temp = C', 'omega = 2']);
    });

    test('takes the #else branch when it is not', () {
      expect(emitted(source), ['alpha = 1', 'temp = F', 'omega = 2']);
    });

    test('handles #elif chains, taking only the first match', () {
      const chain = '''
#if mcu_teensy
board = teensy
#elif mcu_stm32
board = stm32
#else
board = mega
#endif
''';
      expect(emitted(chain, defined: {'mcu_stm32'}), ['board = stm32']);
      expect(emitted(chain, defined: {'mcu_teensy'}), ['board = teensy']);
      expect(emitted(chain), ['board = mega']);
      // Both defined: the earliest matching branch wins, exactly once.
      expect(emitted(chain, defined: {'mcu_teensy', 'mcu_stm32'}),
          ['board = teensy']);
    });

    test('suppresses nested blocks inside a branch that was not taken', () {
      const nested = '''
#if OUTER
#if INNER
deep = yes
#endif
shallow = yes
#endif
after = yes
''';
      expect(emitted(nested, defined: {'INNER'}), ['after = yes']);
      expect(emitted(nested, defined: {'OUTER', 'INNER'}),
          ['deep = yes', 'shallow = yes', 'after = yes']);
      expect(emitted(nested, defined: {'OUTER'}),
          ['shallow = yes', 'after = yes']);
    });

    test('nests several levels deep', () {
      const deep = '''
#if A
#if B
#if C
abc = 1
#else
ab = 1
#endif
#endif
#endif
''';
      expect(emitted(deep, defined: {'A', 'B', 'C'}), ['abc = 1']);
      expect(emitted(deep, defined: {'A', 'B'}), ['ab = 1']);
      expect(emitted(deep, defined: {'A'}), isEmpty);
    });
  });

  group('duplicate assignment across branches', () {
    // This is the blockingFactor shape from the real file: assigned once in an
    // if/else, then conditionally reassigned. Both surviving lines must be
    // emitted in order so the structural parser can apply last-write-wins.
    const source = '''
#if mcu_stm32
blockingFactor = 121
#else
blockingFactor = 251
#endif
#if COMMS_COMPAT
blockingFactor = 121
#endif
''';

    test('emits only the reachable assignments, in order', () {
      expect(emitted(source), ['blockingFactor = 251']);
      expect(emitted(source, defined: {'mcu_stm32'}), ['blockingFactor = 121']);
      expect(emitted(source, defined: {'COMMS_COMPAT'}),
          ['blockingFactor = 251', 'blockingFactor = 121']);
    });
  });

  group('#set and #unset', () {
    test('affect branches that follow them', () {
      const source = '''
#set FEATURE
#if FEATURE
on = 1
#endif
#unset FEATURE
#if FEATURE
still_on = 1
#endif
''';
      expect(emitted(source), ['on = 1']);
    });

    test('are ignored inside a branch that was not taken', () {
      const source = '''
#if NEVER
#set FEATURE
#endif
#if FEATURE
on = 1
#endif
''';
      expect(emitted(source), isEmpty);
    });
  });

  group('#define', () {
    test('collects a simple list, unquoted', () {
      final result =
          IniPreprocessor().run(lines('#define pins = "A0", "A1", "A2"'));
      expect(result.defines['pins'], ['A0', 'A1', 'A2']);
    });

    test('expands the \$invalid_xN repeat shorthand to the right length', () {
      final result = IniPreprocessor()
          .run(lines(r'#define opts = "Off", "On", $invalid_x6'));
      expect(result.defines['opts'], hasLength(8));
      expect(result.defines['opts']!.sublist(2), everyElement('INVALID'));
    });

    test('expands references to earlier defines', () {
      final result = IniPreprocessor().run(lines(r'''
#define base = "a", "b"
#define combined = $base, "c"
'''));
      expect(result.defines['combined'], ['a', 'b', 'c']);
    });

    test('keeps an unresolved forward reference verbatim', () {
      final result =
          IniPreprocessor().run(lines(r'#define x = $notDefinedYet, "b"'));
      expect(result.defines['x'], [r'$notDefinedYet', 'b']);
    });

    test('does not collect defines from a branch that was not taken', () {
      final result = IniPreprocessor().run(lines('''
#if NEVER
#define hidden = "a"
#endif
'''));
      expect(result.defines.containsKey('hidden'), isFalse);
    });
  });

  group('comments and structure', () {
    test('strips comments but keeps semicolons inside quotes', () {
      expect(emitted('sep = ";" ;this is a comment'), ['sep = ";"']);
    });

    test('reports the original line number of surviving lines', () {
      final result = IniPreprocessor().run(lines('''
a = 1
#if NEVER
b = 2
#endif
c = 3
'''));
      expect(result.lines.map((l) => l.number), [1, 5]);
    });
  });

  group('malformed input', () {
    test('rejects an unterminated #if', () {
      expect(() => IniPreprocessor().run(lines('#if A\nx = 1')),
          throwsA(isA<Exception>()));
    });

    test('rejects #endif without #if', () {
      expect(() => IniPreprocessor().run(lines('#endif')),
          throwsA(isA<Exception>()));
    });

    test('refuses a compound condition rather than guessing', () {
      expect(() => IniPreprocessor().run(lines('#if A && B\n#endif')),
          throwsA(isA<Exception>()));
    });
  });
}
