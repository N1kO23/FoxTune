import 'ini_exception.dart';
import 'tokenizer.dart';

/// A source line that survived preprocessing, with its original position.
class SourceLine {
  const SourceLine(this.number, this.text);

  /// 1-based line number in the original file.
  final int number;

  /// The line with comments stripped and whitespace trimmed.
  final String text;

  @override
  String toString() => '$number: $text';
}

/// The result of running the preprocessor over an ECU definition file.
class PreprocessResult {
  const PreprocessResult({required this.lines, required this.defines});

  /// Lines inside branches that were taken, in order.
  final List<SourceLine> lines;

  /// `#define` lists, fully expanded.
  final Map<String, List<String>> defines;
}

/// Evaluates the `#if` / `#define` layer of a TunerStudio ECU definition.
///
/// This must run before any structural parsing. `speeduino.ini` nests
/// conditionals about six deep and assigns some keys - `blockingFactor` among
/// them - more than once across branches. A parser that ignores the directives
/// reads offsets from branches that were never taken, which is the difference
/// between a working tune and a damaged engine.
///
/// Conditions in practice are bare symbol names (`CELSIUS`, `mcu_stm32`,
/// `COMMS_COMPAT`), so no boolean expression grammar is implemented. An
/// unexpected compound condition raises rather than being guessed at.
class IniPreprocessor {
  IniPreprocessor({Set<String>? defined}) : _symbols = {...?defined};

  final Set<String> _symbols;

  /// Symbols currently defined, after any `#set` / `#unset` encountered.
  Set<String> get symbols => Set.unmodifiable(_symbols);

  PreprocessResult run(List<String> rawLines) {
    final output = <SourceLine>[];
    final defines = <String, List<String>>{};

    // One frame per open #if. `active` is whether this branch emits lines,
    // `taken` whether any branch in this chain already matched, and `parent`
    // whether the enclosing scope was itself emitting.
    final stack = <_Frame>[];
    bool emitting() => stack.every((f) => f.active);

    for (var i = 0; i < rawLines.length; i++) {
      final lineNumber = i + 1;
      final text = stripComment(rawLines[i]).trim();
      if (text.isEmpty) continue;

      if (text.startsWith('#')) {
        // A `#` with no directive word after it is a comment: rusEFI heads
        // blocks of its definition with lines like `# Digital outputs`.
        if (text.length == 1 || text.codeUnitAt(1) <= 0x20) continue;
        final directive = _directiveOf(text);
        switch (directive.name) {
          case 'if':
            final parentActive = emitting();
            final matched =
                parentActive && _evaluate(directive.argument, lineNumber);
            stack.add(_Frame(
                active: matched, taken: matched, parentActive: parentActive));

          case 'elif':
            if (stack.isEmpty) {
              throw IniParseException('#elif without #if',
                  line: text, lineNumber: lineNumber);
            }
            final frame = stack.last;
            final matched = frame.parentActive &&
                !frame.taken &&
                _evaluate(directive.argument, lineNumber);
            frame
              ..active = matched
              ..taken = frame.taken || matched;

          case 'else':
            if (stack.isEmpty) {
              throw IniParseException('#else without #if',
                  line: text, lineNumber: lineNumber);
            }
            final frame = stack.last;
            final matched = frame.parentActive && !frame.taken;
            frame
              ..active = matched
              ..taken = frame.taken || matched;

          case 'endif':
            if (stack.isEmpty) {
              throw IniParseException('#endif without #if',
                  line: text, lineNumber: lineNumber);
            }
            stack.removeLast();

          case 'set':
            if (emitting()) {
              _symbols.add(directive.argument);
            }

          case 'unset':
            if (emitting()) {
              _symbols.remove(directive.argument);
            }

          case 'define':
            if (emitting()) {
              _recordDefine(directive.argument, defines, lineNumber);
            }

          default:
            throw IniParseException(
                'Unknown preprocessor directive "#${directive.name}"',
                line: text,
                lineNumber: lineNumber);
        }
        continue;
      }

      if (emitting()) {
        output.add(SourceLine(lineNumber, text));
      }
    }

    if (stack.isNotEmpty) {
      throw IniParseException('${stack.length} unterminated #if block(s)');
    }

    return PreprocessResult(lines: output, defines: defines);
  }

  ({String name, String argument}) _directiveOf(String text) {
    final body = text.substring(1).trim();
    final space = body.indexOf(RegExp(r'\s'));
    if (space < 0) return (name: body.toLowerCase(), argument: '');
    return (
      name: body.substring(0, space).toLowerCase(),
      argument: body.substring(space + 1).trim(),
    );
  }

  bool _evaluate(String condition, int lineNumber) {
    final symbol = condition.trim();
    if (symbol.isEmpty) {
      throw IniParseException('Empty #if condition', lineNumber: lineNumber);
    }
    // Every condition in the wild is a bare symbol. Refuse to guess at
    // anything else rather than silently taking the wrong branch.
    if (RegExp(r'[^\w]').hasMatch(symbol)) {
      throw IniParseException(
          'Unsupported compound #if condition "$symbol"; only bare symbols '
          'are understood',
          lineNumber: lineNumber);
    }
    return _symbols.contains(symbol);
  }

  void _recordDefine(
      String argument, Map<String, List<String>> defines, int lineNumber) {
    final assignment = splitAssignment(argument);
    if (assignment == null) {
      throw IniParseException('Malformed #define', lineNumber: lineNumber);
    }
    final values = <String>[];
    for (final token in splitTopLevel(assignment.value)) {
      values.addAll(_expandToken(token, defines, <String>{}));
    }
    defines[assignment.key] = values;
  }

  /// Expands `$name` references and the `$invalid_xN` repeat shorthand.
  ///
  /// The repeat form matters: a bits field indexes its option list by raw
  /// value, so a list of the wrong length mislabels every entry past the gap.
  List<String> _expandToken(
      String token, Map<String, List<String>> defines, Set<String> seen) {
    final trimmed = token.trim();
    if (!isDefineReference(trimmed)) {
      return [unquote(trimmed)];
    }

    final name = defineReferenceName(trimmed);

    final repeat = RegExp(r'^invalid_x(\d+)$').firstMatch(name);
    if (repeat != null) {
      final count = int.parse(repeat.group(1)!);
      return List<String>.filled(count, 'INVALID');
    }

    if (seen.contains(name)) {
      // A self-referential define would otherwise recurse forever.
      return [trimmed];
    }
    final target = defines[name];
    if (target == null) {
      // Forward or external reference: keep it verbatim for a later pass.
      return [trimmed];
    }
    return [
      for (final value in target)
        ..._expandToken(value, defines, {...seen, name})
    ];
  }
}

class _Frame {
  _Frame({
    required this.active,
    required this.taken,
    required this.parentActive,
  });

  /// Whether this branch is currently emitting lines.
  bool active;

  /// Whether any branch of this chain has matched yet.
  bool taken;

  /// Whether the enclosing scope was emitting when this #if opened.
  final bool parentActive;
}
