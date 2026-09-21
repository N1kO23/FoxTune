import 'package:foxtune_ini/foxtune_ini.dart';

/// How to address one ECU's pages and live data, as its definition spells it
/// out.
///
/// A definition writes its commands as templates - `p%2i%2o%2c` for a
/// Speeduino page read, `R%2i%2o%2c` for rusEFI's - and the bytes a page is
/// known by in `pageIdentifier`. Rendering those, rather than hard-coding one
/// firmware's letters, is what lets the same client talk to both: nothing here
/// knows which ECU it is speaking to.
///
/// Placeholders: `%2i` is the page's identifier bytes, `%2o` and `%2c` a
/// two-byte offset and count in the definition's byte order, `%v` the data
/// being written. `\xNN` is a byte and `$tsCanId` the CAN id.
class EcuCommandSet {
  EcuCommandSet({
    this.pageIdentifiers = const [],
    this.pageReadCommands = const [],
    this.pageWriteCommands = const [],
    this.burnCommands = const [],
    this.crcCommands = const [],
    this.realtimeCommand = _speeduinoRealtime,
    this.pageSizes = const [],
    this.blockingFactor = 251,
    this.realtimeBlockingFactor,
    this.canId = 0,
    this.littleEndian = true,
    this.timeout,
  });

  /// Speeduino's commands, for a client that has no definition yet.
  ///
  /// Exactly what the shipped Speeduino definition declares, for any page
  /// number, so code that predates the command set - and tests that talk to a
  /// fake Speeduino without loading its definition - behave as they did.
  factory EcuCommandSet.speeduino({int canId = 0}) =>
      EcuCommandSet(canId: canId);

  /// The commands [definition] declares.
  factory EcuCommandSet.fromDefinition(
    IniDocument definition, {
    int canId = 0,
  }) {
    final constants = definition.constants;
    final timeout = constants.blockReadTimeoutMs;
    return EcuCommandSet(
      pageIdentifiers: constants.pageIdentifiers,
      pageReadCommands: constants.pageReadCommands,
      pageWriteCommands: constants.pageWriteCommands,
      burnCommands: constants.burnCommands,
      crcCommands: constants.crcCheckCommands,
      realtimeCommand:
          definition.outputChannels.getCommand ?? _speeduinoRealtime,
      pageSizes: constants.pageSizes,
      blockingFactor: constants.blockingFactor ?? 251,
      canId: canId,
      littleEndian: constants.endianness.toLowerCase() != 'big',
      timeout: timeout == null ? null : Duration(milliseconds: timeout),
    );
  }

  static const _speeduinoRead = 'p%2i%2o%2c';
  static const _speeduinoWrite = 'M%2i%2o%2c%v';
  static const _speeduinoBurn = 'b%2i';
  static const _speeduinoCrc = 'd%2i';
  static const _speeduinoRealtime = r'r\$tsCanId\x30%2o%2c';

  /// Identifier template per page, indexed from 0.
  final List<String> pageIdentifiers;

  /// Command templates per page, indexed from 0.
  final List<String> pageReadCommands;
  final List<String> pageWriteCommands;
  final List<String> burnCommands;
  final List<String> crcCommands;

  /// The realtime template, the definition's `ochGetCommand`.
  final String realtimeCommand;

  /// Declared size of each page, indexed from 0.
  final List<int> pageSizes;

  /// Largest payload one page transfer may carry.
  final int blockingFactor;

  /// Largest realtime transfer, where it differs from [blockingFactor].
  final int? realtimeBlockingFactor;

  /// CAN id substituted for `$tsCanId`.
  final int canId;

  /// Byte order of offsets and counts.
  final bool littleEndian;

  /// How long the definition says to wait for a reply, if it says.
  final Duration? timeout;

  /// Largest realtime read one request may ask for.
  ///
  /// rusEFI's live data is twice its transfer limit, and it answers an
  /// oversized request with a range error - which TunerStudio never sends,
  /// because it reads in pieces too.
  int get realtimeChunk => realtimeBlockingFactor ?? blockingFactor;

  static String? _at(List<String> list, int page) =>
      page >= 1 && page <= list.length ? list[page - 1] : null;

  /// The bytes [page] (from 1) is known by.
  List<int> identifierOf(int page) {
    final template = _at(pageIdentifiers, page);
    // Speeduino's shape, for a page the definition does not list: the CAN id
    // and then the page number.
    if (template == null) return [canId & 0xFF, page & 0xFF];
    return render(template);
  }

  /// Reads [count] bytes of [page] from [offset].
  List<int> pageRead(int page, int offset, int count) => render(
        _at(pageReadCommands, page) ?? _speeduinoRead,
        page: page,
        offset: offset,
        count: count,
      );

  /// Writes [data] into [page] at [offset].
  List<int> pageWrite(int page, int offset, List<int> data) => render(
        _at(pageWriteCommands, page) ?? _speeduinoWrite,
        page: page,
        offset: offset,
        count: data.length,
        data: data,
      );

  /// Commits [page] to permanent storage, or `null` for a page that is never
  /// burned.
  ///
  /// rusEFI declares two pages with an empty burn command: working memory,
  /// such as its long-term fuel trims, rather than settings. They take effect
  /// the moment they are written.
  List<int>? burn(int page) {
    final template = _at(burnCommands, page) ?? _speeduinoBurn;
    if (template.trim().isEmpty) return null;
    return render(template, page: page);
  }

  /// Whether [page] has a burn command.
  bool canBurn(int page) => burn(page) != null;

  /// Asks for the CRC-32 of the whole of [page], or `null` if the definition
  /// gives no way to.
  ///
  /// Speeduino's `d%2i` takes the page alone; rusEFI's `k%2i%2o%2c` takes a
  /// range, which here is always the whole page.
  List<int>? pageCrc(int page) {
    final template = _at(crcCommands, page) ?? _speeduinoCrc;
    if (template.trim().isEmpty) return null;
    final size =
        page >= 1 && page <= pageSizes.length ? pageSizes[page - 1] : 0;
    return render(template, page: page, offset: 0, count: size);
  }

  /// Reads [count] bytes of live data from [offset].
  List<int> realtime(int offset, int count) =>
      render(realtimeCommand, offset: offset, count: count);

  /// Renders [template] into the bytes sent.
  List<int> render(
    String template, {
    int? page,
    int offset = 0,
    int count = 0,
    List<int> data = const [],
  }) {
    final out = <int>[];
    var i = 0;

    List<int> word(int value) => littleEndian
        ? [value & 0xFF, (value >> 8) & 0xFF]
        : [(value >> 8) & 0xFF, value & 0xFF];

    bool startsWithAt(String text) => template.startsWith(text, i);

    while (i < template.length) {
      if (startsWithAt(r'\$tsCanId') || startsWithAt(r'$tsCanId')) {
        out.add(canId & 0xFF);
        i += template[i] == r'\' ? 9 : 8;
      } else if (startsWithAt(r'\x') && i + 4 <= template.length) {
        final hex = template.substring(i + 2, i + 4);
        final value = int.tryParse(hex, radix: 16);
        if (value == null) {
          throw FormatException('Bad byte escape in "$template"', template, i);
        }
        out.add(value);
        i += 4;
      } else if (startsWithAt('%2i')) {
        if (page == null) {
          throw FormatException('"$template" needs a page', template, i);
        }
        out.addAll(identifierOf(page));
        i += 3;
      } else if (startsWithAt('%2o')) {
        out.addAll(word(offset));
        i += 3;
      } else if (startsWithAt('%2c')) {
        out.addAll(word(count));
        i += 3;
      } else if (startsWithAt('%v')) {
        out.addAll(data);
        i += 2;
      } else if (template[i] == '%') {
        throw FormatException(
          'Unknown placeholder in command "$template"',
          template,
          i,
        );
      } else {
        out.add(template.codeUnitAt(i) & 0xFF);
        i++;
      }
    }
    return out;
  }
}
