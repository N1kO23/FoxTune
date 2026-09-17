/// Thrown when an ECU definition file cannot be parsed.
class IniParseException implements Exception {
  IniParseException(this.message, {this.line, this.lineNumber});

  /// What went wrong.
  final String message;

  /// The offending source line, if the failure is tied to one.
  final String? line;

  /// 1-based line number in the source file.
  final int? lineNumber;

  @override
  String toString() {
    final where = lineNumber == null ? '' : ' (line $lineNumber)';
    final text = line == null ? '' : '\n  $line';
    return 'IniParseException$where: $message$text';
  }
}
