/// Lexical helpers for the TunerStudio INI dialect.
///
/// The dialect looks like an ordinary `key = value` INI, but values carry
/// quoted strings, `{ ... }` expressions and `[ ... ]` shapes that may all
/// contain commas and semicolons. Splitting naively on `,` or cutting at the
/// first `;` corrupts those, so every split here is quote- and bracket-aware.
library;

/// Strips a trailing `;` comment, ignoring semicolons inside double quotes.
///
/// The fixture contains literal `";"` option values, so this distinction is
/// load-bearing rather than theoretical.
String stripComment(String line) {
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      inQuotes = !inQuotes;
    } else if (char == ';' && !inQuotes) {
      return line.substring(0, i);
    }
  }
  return line;
}

/// Splits `key = value` into its two halves.
///
/// Returns `null` when the line has no top-level `=`. Only the first `=`
/// outside quotes separates; later ones belong to the value.
({String key, String value})? splitAssignment(String line) {
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      inQuotes = !inQuotes;
    } else if (char == '=' && !inQuotes) {
      return (
        key: line.substring(0, i).trim(),
        value: line.substring(i + 1).trim(),
      );
    }
  }
  return null;
}

/// Splits a value on top-level commas.
///
/// Commas inside `"..."`, `{...}`, `[...]` or `(...)` are preserved, so
/// `bits, U08, [0:3], "a", "b"` yields five tokens and
/// `array, S16, [10], "Lambda", { 0.1 / stoich }` yields five as well.
List<String> splitTopLevel(String value) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  var depth = 0;

  for (var i = 0; i < value.length; i++) {
    final char = value[i];

    if (char == '"') {
      inQuotes = !inQuotes;
      buffer.write(char);
      continue;
    }
    if (!inQuotes) {
      if (char == '{' || char == '[' || char == '(') {
        depth++;
      } else if (char == '}' || char == ']' || char == ')') {
        depth--;
      } else if (char == ',' && depth == 0) {
        tokens.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
    }
    buffer.write(char);
  }

  final last = buffer.toString().trim();
  if (last.isNotEmpty || tokens.isNotEmpty) {
    tokens.add(last);
  }
  return tokens;
}

/// Removes one layer of surrounding double quotes, if present.
String unquote(String token) {
  final trimmed = token.trim();
  if (trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

/// Whether [token] is a `$name` reference to a `#define`.
bool isDefineReference(String token) {
  final trimmed = token.trim();
  return trimmed.startsWith(r'$') && trimmed.length > 1;
}

/// Strips the leading `$` from a define reference.
String defineReferenceName(String token) => token.trim().substring(1);

/// Parses a `[a:b]` bit range, a `[n]` length or an `[n x m]` shape.
///
/// Returns the integers found between the brackets. `[0:3]` yields `[0, 3]`,
/// `[16x16]` yields `[16, 16]`, `[10]` yields `[10]`.
List<int> parseBracketed(String token) {
  final trimmed = token.trim();
  if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
    return const [];
  }
  final inner = trimmed.substring(1, trimmed.length - 1);
  return RegExp(r'-?\d+')
      .allMatches(inner)
      .map((m) => int.parse(m.group(0)!))
      .toList(growable: false);
}
