import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

/// Decodes the realtime data block into named, scaled channel values.
///
/// The layout comes entirely from the definition's `[OutputChannels]`, never
/// from fixed offsets, so a firmware update that moves a field is picked up by
/// loading the matching `.ini` rather than by changing this code.
class RealtimeDecoder {
  RealtimeDecoder(this.definition, {this.constantResolver})
      : _compiled = {
          for (final channel in definition.computed)
            if (CompiledExpression.tryCompile(channel.expression)
                case final compiled?)
              channel.name: compiled,
        };

  /// The channel definitions this decoder was built from.
  final IniOutputChannels definition;

  /// Supplies values for identifiers that are not realtime channels.
  ///
  /// Several computed channels depend on *tune constants* rather than
  /// telemetry: `dutyCycle` needs `nSquirts` and `twoStroke`, which live on a
  /// configuration page. Without this the expression cannot resolve and the
  /// gauge reads as unavailable, so a dashboard with a loaded tune should pass
  /// a resolver backed by it.
  final double? Function(String name)? constantResolver;

  /// Computed channels that parsed successfully, by name.
  final Map<String, CompiledExpression> _compiled;

  /// Scale and translate expressions, compiled once and keyed by source.
  ///
  /// Several channels scale by an expression rather than a literal - the VE
  /// table's load axis, `fuelLoad`, scales by `{ fuelLoadFeedBack }`, which in
  /// turn depends on a tune constant. Compiling these per sample would be
  /// wasteful at 30 Hz, so they are cached on the decoder.
  final Map<String, CompiledExpression?> _scaleExpressions = {};

  /// Computed channels whose expression could not be parsed.
  ///
  /// These are reported rather than silently omitted, so a definition this
  /// version cannot fully handle is visible instead of quietly incomplete.
  late final Set<String> unsupportedChannels = {
    for (final channel in definition.computed)
      if (!_compiled.containsKey(channel.name)) channel.name,
  };

  /// Expected block size in bytes, as declared by `ochBlockSize`.
  int? get blockSize => definition.blockSize;

  /// Decodes [block] into a snapshot.
  ///
  /// A block shorter than the definition expects is accepted: fields that fall
  /// outside it read as unavailable. Partial data is common while a connection
  /// is settling, and is better surfaced per-channel than as a hard failure.
  RealtimeSnapshot decode(Uint8List block, {DateTime? timestamp}) =>
      RealtimeSnapshot._(
        block: block,
        definition: definition,
        compiled: _compiled,
        scaleExpressions: _scaleExpressions,
        constantResolver: constantResolver,
        timestamp: timestamp ?? DateTime.now(),
      );
}

/// One decoded sample of the realtime data block.
///
/// Values are computed on demand and memoised, so reading a handful of gauges
/// from a 170-channel definition costs only what is asked for.
class RealtimeSnapshot {
  RealtimeSnapshot._({
    required this.block,
    required IniOutputChannels definition,
    required Map<String, CompiledExpression> compiled,
    required Map<String, CompiledExpression?> scaleExpressions,
    required this.timestamp,
    double? Function(String name)? constantResolver,
  })  : _definition = definition,
        _compiled = compiled,
        _scaleExpressions = scaleExpressions,
        _constantResolver = constantResolver;

  /// The raw bytes this snapshot was decoded from.
  final Uint8List block;

  /// When the sample was taken.
  final DateTime timestamp;

  final IniOutputChannels _definition;
  final Map<String, CompiledExpression> _compiled;
  final Map<String, CompiledExpression?> _scaleExpressions;
  final double? Function(String name)? _constantResolver;

  final Map<String, double?> _cache = {};
  final Set<String> _resolving = {};

  /// Every channel name available, byte-backed and computed.
  Set<String> get names => _definition.allNames;

  /// The value of [name] in engineering units, or `null` if unavailable.
  ///
  /// Unavailable covers: an unknown name, an offset past the end of the block,
  /// an unparsed expression, and any expression that depends on one of those.
  /// Nothing is fabricated to fill a gap.
  double? operator [](String name) => value(name);

  /// See [operator []].
  double? value(String name) {
    if (_cache.containsKey(name)) return _cache[name];

    // A definition could in principle define channels in terms of each other
    // circularly; refuse rather than recurse forever.
    if (!_resolving.add(name)) return null;
    try {
      final result = _compute(name);
      _cache[name] = result;
      return result;
    } finally {
      _resolving.remove(name);
    }
  }

  double? _compute(String name) {
    final field = _definition.channelNamed(name);
    if (field != null) return _decodeField(field);

    final expression = _compiled[name];
    if (expression != null) return expression.evaluate(value);

    // Not telemetry: fall back to the tune, where settings like nSquirts live.
    return _constantResolver?.call(name);
  }

  double? _decodeField(IniField field) {
    final offset = field.offset;
    if (offset == null) return null;

    switch (field) {
      case IniBitsField(:final lowBit, :final highBit, :final type):
        final word = _readRaw(offset, type);
        if (word == null) return null;
        final width = highBit - lowBit + 1;
        final mask = (1 << width) - 1;
        return ((word >> lowBit) & mask).toDouble();

      case IniScalarField(:final type, :final scale, :final translate):
        final raw = _readRaw(offset, type);
        if (raw == null) return null;
        final s = resolveScalar(scale);
        final t = resolveScalar(translate);
        if (s == null || t == null) return null;
        return raw * s + t;

      case IniArrayField():
        // Arrays do not appear in [OutputChannels] in practice; a single
        // value has no meaning without an index.
        return null;
    }
  }

  /// The unscaled value of [name] straight from the block.
  int? rawValue(String name) {
    final field = _definition.channelNamed(name);
    final offset = field?.offset;
    if (field == null || offset == null) return null;
    return _readRaw(offset, field.type);
  }

  /// The option label for a bits channel, e.g. `"On"`.
  String? label(String name) {
    final field = _definition.channelNamed(name);
    if (field is! IniBitsField) return null;
    final raw = value(name);
    return raw == null ? null : field.labelFor(raw.toInt());
  }

  /// Whether a bits channel is set. Useful for status flags.
  bool? flag(String name) {
    final value = this[name];
    return value == null ? null : value != 0;
  }

  /// Resolves an [IniScalarValue] that may be a literal or an expression.
  ///
  /// Expressions are evaluated against this snapshot, so a scale that depends
  /// on another channel or on a tune constant resolves the same way any other
  /// value does - and yields `null` if its inputs are unavailable rather than
  /// silently scaling by one.
  double? resolveScalar(IniScalarValue scalar) {
    switch (scalar) {
      case IniLiteral(:final value):
        return value;
      case IniExpression(:final source):
        final compiled = _scaleExpressions.putIfAbsent(
            source, () => CompiledExpression.tryCompile(source));
        return compiled?.evaluate(value);
    }
  }

  int? _readRaw(int offset, IniDataType type) {
    if (offset < 0 || offset + type.bytes > block.length) return null;
    final view = ByteData.sublistView(block);
    // Payload data is little-endian, unlike the frame envelope.
    return switch (type) {
      IniDataType.u08 => view.getUint8(offset),
      IniDataType.s08 => view.getInt8(offset),
      IniDataType.u16 => view.getUint16(offset, Endian.little),
      IniDataType.s16 => view.getInt16(offset, Endian.little),
      IniDataType.u32 => view.getUint32(offset, Endian.little),
      IniDataType.s32 => view.getInt32(offset, Endian.little),
      IniDataType.f32 => view.getFloat32(offset, Endian.little).round(),
    };
  }

  @override
  String toString() => 'RealtimeSnapshot(${block.length} bytes @ $timestamp)';
}
