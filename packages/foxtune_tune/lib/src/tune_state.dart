import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';

/// The authoritative tune, held as raw page bytes.
///
/// Keeping bytes as the source of truth - rather than a parallel graph of typed
/// objects - means a round trip to the ECU or to a `.msq` is lossless by
/// construction: anything this version does not understand is still carried
/// through untouched rather than silently dropped.
///
/// Typed access is projected over those bytes through the loaded definition.
class TuneState {
  TuneState._(this.definition, this._pages);

  /// Allocates an empty tune sized by the definition's declared page sizes.
  factory TuneState.empty(IniDocument definition) => TuneState._(
        definition,
        [
          for (final size in definition.constants.pageSizes) Uint8List(size),
        ],
      );

  /// Wraps [pages] read from an ECU. Sizes must match the definition.
  factory TuneState.fromPages(IniDocument definition, List<Uint8List> pages) {
    final expected = definition.constants.pageSizes;
    if (pages.length != expected.length) {
      throw ArgumentError(
          'Expected ${expected.length} pages, got ${pages.length}');
    }
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].length != expected[i]) {
        throw ArgumentError('Page ${i + 1} is ${pages[i].length} bytes, '
            'definition declares ${expected[i]}');
      }
    }
    return TuneState._(
        definition, [for (final p in pages) Uint8List.fromList(p)]);
  }

  /// The definition describing this tune's layout.
  final IniDocument definition;

  final List<Uint8List> _pages;

  /// Page numbers that have been modified since the last [markClean].
  final Set<int> _dirtyPages = {};

  /// 1-based page numbers with unsaved changes.
  Set<int> get dirtyPages => Set.unmodifiable(_dirtyPages);

  /// Whether anything has changed since the last [markClean].
  bool get isDirty => _dirtyPages.isNotEmpty;

  /// Number of pages.
  int get pageCount => _pages.length;

  /// Read-only view of a page's bytes. [page] is 1-based.
  Uint8List page(int page) => Uint8List.sublistView(_pages[page - 1]);

  /// Replaces a page's contents, as when reading it back from the ECU.
  void setPage(int page, List<int> bytes, {bool markDirty = false}) {
    final target = _pages[page - 1];
    if (bytes.length != target.length) {
      throw ArgumentError('Page $page expects ${target.length} bytes, '
          'got ${bytes.length}');
    }
    target.setAll(0, bytes);
    if (markDirty) {
      _dirtyPages.add(page);
    } else {
      _dirtyPages.remove(page);
    }
  }

  /// Clears the dirty set, after a successful write and burn.
  void markClean([int? page]) {
    if (page == null) {
      _dirtyPages.clear();
    } else {
      _dirtyPages.remove(page);
    }
  }

  /// An independent copy, for snapshots and diffing.
  TuneState copy() => TuneState._(
        definition,
        [for (final p in _pages) Uint8List.fromList(p)],
      );

  /// Locates a field by name across all pages.
  ({int page, IniField field})? locate(String name) {
    final hit = definition.constants.findField(name);
    return hit == null ? null : (page: hit.page.number, field: hit.field);
  }

  // --- Raw element access --------------------------------------------------

  /// Reads the raw integer at [index] within [field] on [page].
  ///
  /// [index] is the element index for arrays and ignored for scalars.
  int? readRaw(int page, IniField field, [int index = 0]) {
    final offset = field.offset;
    if (offset == null) return null;
    final bytes = _pages[page - 1];
    final at = offset + index * field.type.bytes;
    if (at < 0 || at + field.type.bytes > bytes.length) return null;

    final view = ByteData.sublistView(bytes);
    // Tune data is little-endian, as the definition's `endianness` declares.
    return switch (field.type) {
      IniDataType.u08 => view.getUint8(at),
      IniDataType.s08 => view.getInt8(at),
      IniDataType.u16 => view.getUint16(at, Endian.little),
      IniDataType.s16 => view.getInt16(at, Endian.little),
      IniDataType.u32 => view.getUint32(at, Endian.little),
      IniDataType.s32 => view.getInt32(at, Endian.little),
      IniDataType.f32 => view.getFloat32(at, Endian.little).round(),
    };
  }

  /// Writes a raw integer, clamped to what the storage type can hold.
  ///
  /// Clamping here is the last line of defence against a value that would wrap
  /// around - 256 becoming 0 in a U08 would turn a rich cell into a lean one.
  void writeRaw(int page, IniField field, int value, [int index = 0]) {
    final offset = field.offset;
    if (offset == null) {
      throw ArgumentError('Field ${field.name} has no offset and cannot be '
          'written to a page');
    }
    final bytes = _pages[page - 1];
    final at = offset + index * field.type.bytes;
    if (at < 0 || at + field.type.bytes > bytes.length) {
      throw RangeError('Writing ${field.name}[$index] would fall outside '
          'page $page');
    }

    final clamped = clampToType(value, field.type);
    final view = ByteData.sublistView(bytes);
    switch (field.type) {
      case IniDataType.u08:
        view.setUint8(at, clamped);
      case IniDataType.s08:
        view.setInt8(at, clamped);
      case IniDataType.u16:
        view.setUint16(at, clamped, Endian.little);
      case IniDataType.s16:
        view.setInt16(at, clamped, Endian.little);
      case IniDataType.u32:
        view.setUint32(at, clamped, Endian.little);
      case IniDataType.s32:
        view.setInt32(at, clamped, Endian.little);
      case IniDataType.f32:
        view.setFloat32(at, clamped.toDouble(), Endian.little);
    }
    _dirtyPages.add(page);
  }

  /// Clamps [value] into the representable range of [type].
  static int clampToType(int value, IniDataType type) {
    final (int lo, int hi) = switch (type) {
      IniDataType.u08 => (0, 255),
      IniDataType.s08 => (-128, 127),
      IniDataType.u16 => (0, 65535),
      IniDataType.s16 => (-32768, 32767),
      IniDataType.u32 => (0, 4294967295),
      IniDataType.s32 => (-2147483648, 2147483647),
      IniDataType.f32 => (-2147483648, 2147483647),
    };
    return value < lo ? lo : (value > hi ? hi : value);
  }

  /// Byte ranges that differ between this tune and [other], per page.
  ///
  /// Used to show what a burn is about to change.
  Map<int, List<({int offset, int length})>> diff(TuneState other) {
    final result = <int, List<({int offset, int length})>>{};
    for (var p = 0; p < _pages.length && p < other._pages.length; p++) {
      final a = _pages[p];
      final b = other._pages[p];
      final ranges = <({int offset, int length})>[];
      var start = -1;
      for (var i = 0; i < a.length && i < b.length; i++) {
        if (a[i] != b[i]) {
          if (start < 0) start = i;
        } else if (start >= 0) {
          ranges.add((offset: start, length: i - start));
          start = -1;
        }
      }
      if (start >= 0) {
        ranges.add((offset: start, length: a.length - start));
      }
      if (ranges.isNotEmpty) result[p + 1] = ranges;
    }
    return result;
  }
}
