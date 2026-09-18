/// A small evaluator for the `{ ... }` expressions in an ECU definition.
///
/// TunerStudio definitions compute several channels rather than transmitting
/// them: `coolant = { coolantRaw - 40 }`, `lambda = { afr / stoich }`,
/// `dutyCycle = { rpm ? (100.0 * pulseWidth / pulseLimit) : 0 }`. Without an
/// evaluator a dashboard simply cannot show coolant or intake temperature,
/// because the ECU never sends them.
///
/// Supported: numeric literals, identifiers, `+ - * / %`, unary `- !`,
/// comparisons, `&& ||`, `<< >>`, parentheses and the `? :` ternary. Booleans
/// follow C conventions - false is 0, true is 1, and any non-zero value is
/// truthy.
///
/// Function calls (`bitStringValue`, `arrayValue`, `smoothBasic`) parse but
/// evaluate to `null`, which propagates. A channel that depends on one reads as
/// unavailable rather than as a fabricated number.
library;

/// A parsed expression, ready to evaluate against a set of channel values.
class CompiledExpression {
  const CompiledExpression._(this._root, this.references, this.source);

  final _Node _root;

  /// Identifiers this expression reads. Useful for ordering computed channels
  /// so dependencies evaluate first.
  final Set<String> references;

  /// The original source text.
  final String source;

  /// Parses [source], returning `null` if it cannot be understood.
  static CompiledExpression? tryCompile(String source) {
    try {
      return compile(source);
    } on FormatException {
      return null;
    }
  }

  /// Parses [source], throwing [FormatException] on malformed input.
  static CompiledExpression compile(String source) {
    final tokens = _tokenize(source);
    final parser = _Parser(tokens, source);
    final root = parser.parseExpression();
    parser.expectEnd();
    final references = <String>{};
    root.collectReferences(references);
    return CompiledExpression._(root, references, source);
  }

  /// Evaluates against [resolve], which supplies channel values by name.
  ///
  /// Returns `null` when any input is unavailable or an unsupported function
  /// is reached, so an unknown never surfaces as a plausible-looking number.
  double? evaluate(double? Function(String name) resolve) =>
      _root.evaluate(resolve);

  @override
  String toString() => 'CompiledExpression($source)';
}

// --- Tokenizer -------------------------------------------------------------

enum _TokenType { number, identifier, operator, lparen, rparen, comma, end }

class _Token {
  const _Token(this.type, this.text, this.position);
  final _TokenType type;
  final String text;
  final int position;

  @override
  String toString() => '${type.name}("$text")';
}

const _operators = <String>[
  '<<', '>>', '<=', '>=', '==', '!=', '&&', '||', //
  '+', '-', '*', '/', '%', '<', '>', '!', '?', ':',
];

List<_Token> _tokenize(String source) {
  final tokens = <_Token>[];
  var i = 0;

  while (i < source.length) {
    final char = source[i];

    if (char.trim().isEmpty) {
      i++;
      continue;
    }

    if (_isDigit(char) ||
        (char == '.' && i + 1 < source.length && _isDigit(source[i + 1]))) {
      final start = i;
      while (i < source.length && (_isDigit(source[i]) || source[i] == '.')) {
        i++;
      }
      tokens.add(_Token(_TokenType.number, source.substring(start, i), start));
      continue;
    }

    if (_isIdentifierStart(char)) {
      final start = i;
      // Dotted names such as `array.boardFuelOutputs` are single identifiers.
      while (i < source.length &&
          (_isIdentifierPart(source[i]) || source[i] == '.')) {
        i++;
      }
      tokens.add(
          _Token(_TokenType.identifier, source.substring(start, i), start));
      continue;
    }

    if (char == '(') {
      tokens.add(_Token(_TokenType.lparen, char, i++));
      continue;
    }
    if (char == ')') {
      tokens.add(_Token(_TokenType.rparen, char, i++));
      continue;
    }
    if (char == ',') {
      tokens.add(_Token(_TokenType.comma, char, i++));
      continue;
    }

    final two = i + 1 < source.length ? source.substring(i, i + 2) : '';
    if (_operators.contains(two)) {
      tokens.add(_Token(_TokenType.operator, two, i));
      i += 2;
      continue;
    }
    if (_operators.contains(char)) {
      tokens.add(_Token(_TokenType.operator, char, i++));
      continue;
    }

    throw FormatException('Unexpected character "$char"', source, i);
  }

  tokens.add(_Token(_TokenType.end, '', source.length));
  return tokens;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

bool _isIdentifierStart(String c) {
  final code = c.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      c == '_';
}

bool _isIdentifierPart(String c) => _isIdentifierStart(c) || _isDigit(c);

// --- Parser ----------------------------------------------------------------

class _Parser {
  _Parser(this.tokens, this.source);

  final List<_Token> tokens;
  final String source;
  int _index = 0;

  _Token get _current => tokens[_index];

  bool _matchOperator(String text) {
    if (_current.type == _TokenType.operator && _current.text == text) {
      _index++;
      return true;
    }
    return false;
  }

  void expectEnd() {
    if (_current.type != _TokenType.end) {
      throw FormatException(
          'Unexpected trailing "${_current.text}"', source, _current.position);
    }
  }

  /// ternary := logicalOr ( '?' expression ':' expression )?
  _Node parseExpression() {
    final condition = _parseLogicalOr();
    if (_matchOperator('?')) {
      final whenTrue = parseExpression();
      if (!_matchOperator(':')) {
        throw FormatException(
            'Expected ":" in ternary', source, _current.position);
      }
      final whenFalse = parseExpression();
      return _TernaryNode(condition, whenTrue, whenFalse);
    }
    return condition;
  }

  _Node _parseLogicalOr() {
    var left = _parseLogicalAnd();
    while (_matchOperator('||')) {
      left = _BinaryNode('||', left, _parseLogicalAnd());
    }
    return left;
  }

  _Node _parseLogicalAnd() {
    var left = _parseEquality();
    while (_matchOperator('&&')) {
      left = _BinaryNode('&&', left, _parseEquality());
    }
    return left;
  }

  _Node _parseEquality() {
    var left = _parseComparison();
    while (true) {
      if (_matchOperator('==')) {
        left = _BinaryNode('==', left, _parseComparison());
      } else if (_matchOperator('!=')) {
        left = _BinaryNode('!=', left, _parseComparison());
      } else {
        return left;
      }
    }
  }

  _Node _parseComparison() {
    var left = _parseShift();
    while (true) {
      if (_matchOperator('<=')) {
        left = _BinaryNode('<=', left, _parseShift());
      } else if (_matchOperator('>=')) {
        left = _BinaryNode('>=', left, _parseShift());
      } else if (_matchOperator('<')) {
        left = _BinaryNode('<', left, _parseShift());
      } else if (_matchOperator('>')) {
        left = _BinaryNode('>', left, _parseShift());
      } else {
        return left;
      }
    }
  }

  _Node _parseShift() {
    var left = _parseAdditive();
    while (true) {
      if (_matchOperator('<<')) {
        left = _BinaryNode('<<', left, _parseAdditive());
      } else if (_matchOperator('>>')) {
        left = _BinaryNode('>>', left, _parseAdditive());
      } else {
        return left;
      }
    }
  }

  _Node _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      if (_matchOperator('+')) {
        left = _BinaryNode('+', left, _parseMultiplicative());
      } else if (_matchOperator('-')) {
        left = _BinaryNode('-', left, _parseMultiplicative());
      } else {
        return left;
      }
    }
  }

  _Node _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      if (_matchOperator('*')) {
        left = _BinaryNode('*', left, _parseUnary());
      } else if (_matchOperator('/')) {
        left = _BinaryNode('/', left, _parseUnary());
      } else if (_matchOperator('%')) {
        left = _BinaryNode('%', left, _parseUnary());
      } else {
        return left;
      }
    }
  }

  _Node _parseUnary() {
    if (_matchOperator('-')) return _UnaryNode('-', _parseUnary());
    if (_matchOperator('!')) return _UnaryNode('!', _parseUnary());
    if (_matchOperator('+')) return _parseUnary();
    return _parsePrimary();
  }

  _Node _parsePrimary() {
    final token = _current;

    switch (token.type) {
      case _TokenType.number:
        _index++;
        final value = double.tryParse(token.text);
        if (value == null) {
          throw FormatException(
              'Malformed number "${token.text}"', source, token.position);
        }
        return _LiteralNode(value);

      case _TokenType.identifier:
        _index++;
        if (_current.type == _TokenType.lparen) {
          // A function call. Arguments are parsed so the expression stays
          // well-formed, but the call itself evaluates to null.
          _index++;
          final args = <_Node>[];
          if (_current.type != _TokenType.rparen) {
            args.add(parseExpression());
            while (_current.type == _TokenType.comma) {
              _index++;
              args.add(parseExpression());
            }
          }
          if (_current.type != _TokenType.rparen) {
            throw FormatException(
                'Expected ")" after arguments', source, _current.position);
          }
          _index++;
          return _CallNode(token.text, args);
        }
        return _IdentifierNode(token.text);

      case _TokenType.lparen:
        _index++;
        final inner = parseExpression();
        if (_current.type != _TokenType.rparen) {
          throw FormatException('Expected ")"', source, _current.position);
        }
        _index++;
        return inner;

      case _TokenType.operator:
      case _TokenType.rparen:
      case _TokenType.comma:
      case _TokenType.end:
        throw FormatException(
            'Unexpected "${token.text}"', source, token.position);
    }
  }
}

// --- AST -------------------------------------------------------------------

sealed class _Node {
  const _Node();

  double? evaluate(double? Function(String) resolve);

  void collectReferences(Set<String> into);
}

class _LiteralNode extends _Node {
  const _LiteralNode(this.value);
  final double value;

  @override
  double? evaluate(double? Function(String) resolve) => value;

  @override
  void collectReferences(Set<String> into) {}
}

class _IdentifierNode extends _Node {
  const _IdentifierNode(this.name);
  final String name;

  @override
  double? evaluate(double? Function(String) resolve) => resolve(name);

  @override
  void collectReferences(Set<String> into) => into.add(name);
}

class _CallNode extends _Node {
  const _CallNode(this.name, this.arguments);
  final String name;
  final List<_Node> arguments;

  @override
  double? evaluate(double? Function(String) resolve) => null;

  @override
  void collectReferences(Set<String> into) {
    for (final argument in arguments) {
      argument.collectReferences(into);
    }
  }
}

class _UnaryNode extends _Node {
  const _UnaryNode(this.op, this.operand);
  final String op;
  final _Node operand;

  @override
  double? evaluate(double? Function(String) resolve) {
    final value = operand.evaluate(resolve);
    if (value == null) return null;
    return switch (op) {
      '-' => -value,
      '!' => value == 0 ? 1 : 0,
      _ => null,
    };
  }

  @override
  void collectReferences(Set<String> into) => operand.collectReferences(into);
}

class _BinaryNode extends _Node {
  const _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;

  @override
  double? evaluate(double? Function(String) resolve) {
    final a = left.evaluate(resolve);
    if (a == null) return null;

    // Short-circuit, matching C semantics: the right side is not evaluated
    // when the left already decides the result.
    if (op == '&&' && a == 0) return 0;
    if (op == '||' && a != 0) return 1;

    final b = right.evaluate(resolve);
    if (b == null) return null;

    return switch (op) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      // Division by zero yields null rather than infinity, so a gauge reads
      // as unavailable instead of showing "Infinity".
      '/' => b == 0 ? null : a / b,
      '%' => b == 0 ? null : a % b,
      '<' => a < b ? 1 : 0,
      '<=' => a <= b ? 1 : 0,
      '>' => a > b ? 1 : 0,
      '>=' => a >= b ? 1 : 0,
      '==' => a == b ? 1 : 0,
      '!=' => a != b ? 1 : 0,
      '&&' => b != 0 ? 1 : 0,
      '||' => b != 0 ? 1 : 0,
      '<<' => (a.toInt() << b.toInt()).toDouble(),
      '>>' => (a.toInt() >> b.toInt()).toDouble(),
      _ => null,
    };
  }

  @override
  void collectReferences(Set<String> into) {
    left.collectReferences(into);
    right.collectReferences(into);
  }
}

class _TernaryNode extends _Node {
  const _TernaryNode(this.condition, this.whenTrue, this.whenFalse);
  final _Node condition;
  final _Node whenTrue;
  final _Node whenFalse;

  @override
  double? evaluate(double? Function(String) resolve) {
    final test = condition.evaluate(resolve);
    if (test == null) return null;
    // Only the taken branch is evaluated, so `rpm ? 100/rpm : 0` is safe.
    return test != 0 ? whenTrue.evaluate(resolve) : whenFalse.evaluate(resolve);
  }

  @override
  void collectReferences(Set<String> into) {
    condition.collectReferences(into);
    whenTrue.collectReferences(into);
    whenFalse.collectReferences(into);
  }
}
