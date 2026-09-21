import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:xml/xml.dart';

import 'tune_state.dart';
import 'value_resolver.dart';

/// What happened while reading a `.msq`.
class MsqImportResult {
  const MsqImportResult({
    required this.signature,
    required this.applied,
    required this.skipped,
    required this.unknown,
  });

  /// Signature declared by the file, if any.
  final String? signature;

  /// Constants that were written into the tune.
  final int applied;

  /// Constants this version could not convert, by name.
  ///
  /// Reported rather than silently ignored: a value that did not load is a
  /// setting the user thinks they have and does not.
  final List<String> skipped;

  /// Names in the file that the loaded definition does not declare.
  ///
  /// Usually a tune from a different firmware version.
  final List<String> unknown;

  bool get isClean => skipped.isEmpty && unknown.isEmpty;

  @override
  String toString() => 'MsqImportResult(applied: $applied, '
      'skipped: ${skipped.length}, unknown: ${unknown.length})';
}

/// Thrown when a `.msq` cannot be applied to the loaded tune.
class MsqException implements Exception {
  MsqException(this.message);

  final String message;

  @override
  String toString() => 'MsqException: $message';
}

/// Reads and writes TunerStudio `.msq` tune files.
///
/// The format is XML holding values in **engineering units**, not raw bytes:
/// a bits field is stored as its option label (`"Even fire"`), a scalar as a
/// decimal, and an array as whitespace-separated values laid out in rows.
/// Conversion therefore runs through the same scaling the editor uses,
/// including expression-based scales.
///
/// Two-dimensional tables are written in ascending-axis order, lowest Y first,
/// which is what TunerStudio writes - not display order. Firmware storage has
/// row 0 at Y-Max, so rows invert on the way in and out; columns do not, since
/// both the file and storage run ascending-X.
abstract final class MsqCodec {
  /// Namespace TunerStudio writes on the root element.
  static const String namespace = 'http://www.msefi.com/:msq';

  /// File format version FoxTune writes.
  static const String fileFormat = '5.0';

  /// Serialises [tune] as a `.msq` document.
  ///
  /// Written by hand rather than through an XML pretty-printer: the row layout
  /// inside a table's text is meaningful to anyone reading the file, and a
  /// pretty-printer collapses it onto one line.
  static String encode(
    TuneState tune, {
    String author = 'FoxTune',
    String tuneComment = '',
    DateTime? writeDate,
  }) {
    final definition = tune.definition;
    final resolver = TuneValueResolver(tune);
    final signature = definition.identity.signature ?? '';
    final out = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="ISO-8859-1"?>')
      ..writeln('<msq xmlns="$namespace">')
      ..writeln('<bibliography author="${_attr(author)}" '
          'tuneComment="${_attr(tuneComment)}" '
          'writeDate="${_attr((writeDate ?? DateTime.now()).toString())}"/>')
      ..writeln('<versionInfo fileFormat="$fileFormat" '
          'firmwareInfo="${_attr(signature)}" '
          'nPages="${definition.constants.pageCount}" '
          'signature="${_attr(signature)}"/>');

    // PcVariables live in a page element with no number, matching TunerStudio.
    out.writeln('<page>');
    out.writeln('</page>');

    for (final page in definition.constants.pages) {
      final size = definition.constants.pageSizes[page.number - 1];
      out.writeln('<page number="${page.number}" size="$size">');
      for (final field in page.fields) {
        _writeField(out, 'constant', field, page.number, tune, resolver);
      }
      out.writeln('</page>');
    }

    out.writeln('</msq>');
    return out.toString();
  }

  static void _writeField(
    StringBuffer out,
    String elementName,
    IniField field,
    int page,
    TuneState tune,
    TuneValueResolver resolver,
  ) {
    switch (field) {
      case IniBitsField():
        final value = tune.readBits(page, field);
        if (value == null) return;
        final label = field.labelFor(value);
        // Bits are stored as the quoted option label, not as a number.
        final text = label == null ? '"$value"' : '"$label"';
        out.writeln('<$elementName name="${_attr(field.name)}">'
            '${_text(text)}</$elementName>');

      case IniScalarField():
        final raw = tune.readRaw(page, field);
        final scale = resolver.valueOf(field.scale);
        final translate = resolver.valueOf(field.translate);
        if (raw == null || scale == null || translate == null) return;
        final digits = field.digits ?? 0;
        final value = (raw * scale + translate).toStringAsFixed(digits);
        out.writeln('<$elementName digits="$digits" '
            'name="${_attr(field.name)}"'
            '${field.units.isEmpty ? '' : ' units="${_attr(field.units)}"'}>'
            '$value</$elementName>');

      case IniArrayField():
        final scale = resolver.valueOf(field.scale);
        final translate = resolver.valueOf(field.translate);
        if (scale == null || translate == null) return;

        final digits = field.digits ?? 0;
        final columns = field.isTable ? field.shape[1] : 1;
        final rows = field.shape[0];

        out.writeln('<$elementName cols="$columns" digits="$digits" '
            'name="${_attr(field.name)}" rows="$rows"'
            '${field.units.isEmpty ? '' : ' units="${_attr(field.units)}"'}>');
        // Ascending-axis order, which is how TunerStudio writes arrays -
        // lowest Y first, not display order. Storage runs the other way (row 0
        // is Y-Max), hence the reverse iteration.
        for (var r = rows - 1; r >= 0; r--) {
          out.write('        ');
          for (var c = 0; c < columns; c++) {
            final index = field.isTable ? r * columns + c : r;
            final raw = tune.readRaw(page, field, index);
            final value = raw == null ? 0.0 : raw * scale + translate;
            out
              ..write(value.toStringAsFixed(digits))
              ..write(' ');
          }
          out.writeln();
        }
        out.writeln('      </$elementName>');
    }
  }

  /// Escapes a value for use inside a double-quoted attribute.
  static String _attr(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Escapes a value for use as element text.
  static String _text(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Reads a `.msq` into [into].
  ///
  /// Values are matched to the loaded definition **by name**, so a tune saved
  /// from a different firmware version loads whatever still applies and reports
  /// the rest rather than shifting everything by an offset.
  ///
  /// Set [requireSignatureMatch] to refuse a file whose signature differs.
  static MsqImportResult decode(
    String xml,
    TuneState into, {
    bool requireSignatureMatch = true,
  }) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw MsqException('Not a valid XML document: ${e.message}');
    }

    final root = document.rootElement;
    if (root.name.local != 'msq') {
      throw MsqException(
          'Root element is <${root.name.local}>, expected <msq>');
    }

    final signature =
        root.findElements('versionInfo').firstOrNull?.getAttribute('signature');

    final expected = into.definition.identity.signature;
    if (requireSignatureMatch) {
      if (signature == null) {
        throw MsqException('The file declares no signature.');
      }
      if (expected != null && signature.trim() != expected) {
        throw MsqException(
            'This tune is for "$signature" but the loaded definition is for '
            '"$expected". Loading it would put values at the wrong offsets.');
      }
    }

    final resolver = TuneValueResolver(into);
    var applied = 0;
    final skipped = <String>[];
    final unknown = <String>[];

    for (final element in root.descendantElements) {
      if (element.name.local != 'constant') continue;
      final name = element.getAttribute('name');
      if (name == null) continue;

      final located = into.locate(name);
      if (located == null) {
        unknown.add(name);
        continue;
      }

      final ok = _applyField(
          into, located.page, located.field, element.innerText, resolver);
      if (ok) {
        applied++;
      } else {
        skipped.add(name);
      }
    }

    return MsqImportResult(
      signature: signature,
      applied: applied,
      skipped: skipped,
      unknown: unknown,
    );
  }

  static bool _applyField(TuneState tune, int page, IniField field, String text,
      TuneValueResolver resolver) {
    switch (field) {
      case IniBitsField():
        final label = text.trim().replaceAll('"', '');
        var index = field.options.indexOf(label);
        if (index < 0) {
          // Some writers store the numeric value instead of the label.
          final numeric = int.tryParse(label);
          if (numeric == null) return false;
          index = numeric;
        }
        // Preserve the neighbouring bits packed into the same byte.
        tune.writeBits(page, field, index);
        return true;

      case IniScalarField():
        final value = double.tryParse(text.trim());
        if (value == null) return false;
        final scale = resolver.valueOf(field.scale);
        final translate = resolver.valueOf(field.translate);
        if (scale == null || translate == null || scale == 0) return false;
        tune.writeRaw(page, field, (value - translate) / scale);
        return true;

      case IniArrayField():
        final scale = resolver.valueOf(field.scale);
        final translate = resolver.valueOf(field.translate);
        if (scale == null || translate == null || scale == 0) return false;

        final numbers = text
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .map(double.tryParse)
            .toList();
        if (numbers.any((n) => n == null)) return false;

        final columns = field.isTable ? field.shape[1] : 1;
        final rows = field.isTable ? field.shape[0] : field.shape[0];
        if (numbers.length != rows * columns) return false;

        for (var r = 0; r < rows; r++) {
          for (var c = 0; c < columns; c++) {
            // The file is in ascending-axis order and storage is descending,
            // so rows invert. Columns do not: both run ascending-X.
            final source = (rows - 1 - r) * columns + c;
            final index = field.isTable ? r * columns + c : r;
            final value = numbers[source]!;
            tune.writeRaw(page, field, (value - translate) / scale, index);
          }
        }
        return true;
    }
  }
}
