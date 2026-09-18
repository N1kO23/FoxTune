import 'dart:typed_data';

import 'package:foxtune_protocol/foxtune_protocol.dart';

import 'tune_state.dart';
import 'write_guard.dart';

/// What happened when a page was committed.
class CommitResult {
  const CommitResult({
    required this.page,
    required this.bytesWritten,
    required this.verified,
    required this.burned,
  });

  final int page;
  final int bytesWritten;

  /// Whether the ECU's own CRC matched what we intended to store.
  final bool verified;

  /// Whether the page was committed to EEPROM.
  final bool burned;

  @override
  String toString() => 'CommitResult(page $page, $bytesWritten bytes, '
      'verified: $verified, burned: $burned)';
}

/// Commits tune changes to an ECU, with the guard rails applied in order.
///
/// The sequence for every page is deliberate:
///
/// 1. Refuse unless [permission] allows it.
/// 2. Snapshot the tune to disk before the first write of a session, so there
///    is always something to go back to.
/// 3. Write to RAM.
/// 4. Ask the ECU for the page's CRC and compare. A write that did not land
///    intact must never be burned.
/// 5. Only then burn to EEPROM.
///
/// Verification before burning is the step that matters most: RAM can be
/// re-written, but a corrupt page committed to EEPROM is what strands someone
/// at the roadside.
class TuneWriter {
  TuneWriter({
    required this.client,
    required this.tune,
    required this.permission,
    required this.blockingFactor,
    this.burnCommand = SpeeduinoCommand.burn,
    this.onSnapshot,
  });

  final EcuClient client;
  final TuneState tune;

  /// Whether writes are allowed, and why not if they are refused.
  final WritePermission permission;

  /// Maximum payload per transfer, from the definition.
  final int blockingFactor;

  /// Burn command variant the definition declares.
  final int burnCommand;

  /// Invoked once, before the first write of the session, with a copy of the
  /// tune as it was. Intended to persist a restore point.
  final Future<void> Function(TuneState snapshot)? onSnapshot;

  bool _snapshotTaken = false;

  /// Whether the session's restore point has been taken.
  bool get snapshotTaken => _snapshotTaken;

  /// Writes, verifies and burns a single page.
  ///
  /// Throws [WriteRefusedException] if the guard rails forbid it, and
  /// [EcuProtocolException] if verification fails - in which case nothing is
  /// burned.
  Future<CommitResult> commitPage(int page) async {
    final reason = permission.reason;
    if (!permission.allowed) {
      throw WriteRefusedException(reason ?? 'Writing is not permitted.');
    }

    await _ensureSnapshot();

    final bytes = tune.page(page);
    await client.writePage(
      page,
      data: bytes,
      blockingFactor: blockingFactor,
    );

    final expected = crc32(bytes);
    final reported = await client.pageCrc(page);
    if (reported != expected) {
      // Deliberately not burned: a page that did not arrive intact must not be
      // made permanent.
      throw EcuProtocolException(
          'Page $page failed verification after writing: the ECU reports CRC '
          '0x${reported.toRadixString(16)}, expected '
          '0x${expected.toRadixString(16)}. Nothing was burned.');
    }

    await client.burnPage(page, burnCommand: burnCommand);
    tune.markClean(page);

    return CommitResult(
      page: page,
      bytesWritten: bytes.length,
      verified: true,
      burned: true,
    );
  }

  /// Commits every page with unsaved changes, lowest page first.
  ///
  /// Stops at the first failure rather than pressing on, so a verification
  /// problem does not get repeated across the rest of the tune.
  Future<List<CommitResult>> commitDirtyPages() async {
    final pages = tune.dirtyPages.toList()..sort();
    final results = <CommitResult>[];
    for (final page in pages) {
      results.add(await commitPage(page));
    }
    return results;
  }

  Future<void> _ensureSnapshot() async {
    if (_snapshotTaken) return;
    final callback = onSnapshot;
    // Mark first: a snapshot that throws must not cause a retry loop that
    // writes the tune to disk on every attempt.
    _snapshotTaken = true;
    if (callback != null) {
      await callback(tune.copy());
    }
  }

  /// Reads every page from the ECU into [tune].
  ///
  /// Used to establish a known-good starting point before editing.
  static Future<TuneState> readAll(
    EcuClient client, {
    required TuneState into,
    required int blockingFactor,
    void Function(int page, int of)? onProgress,
  }) async {
    final sizes = into.definition.constants.pageSizes;
    for (var i = 0; i < sizes.length; i++) {
      final page = i + 1;
      final data = await client.readPage(
        page,
        count: sizes[i],
        blockingFactor: blockingFactor,
      );
      into.setPage(page, Uint8List.fromList(data));
      onProgress?.call(page, sizes.length);
    }
    return into;
  }
}
