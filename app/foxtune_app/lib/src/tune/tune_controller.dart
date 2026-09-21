import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';
import 'package:path_provider/path_provider.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../storage/json_store.dart';
import 'host_values.dart';

/// Whether the user has deliberately enabled writing.
///
/// Read-only is the default and resets on every disconnect, so connecting to
/// an engine can never, by itself, put the app in a state where it can change
/// the tune.
final writeModeProvider = NotifierProvider<WriteModeController, bool>(
  WriteModeController.new,
);

class WriteModeController extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(connectionProvider, (previous, next) {
      if (next is! EcuConnected) state = false;
    });
    return false;
  }

  // ignore: avoid_positional_boolean_parameters
  void set(bool enabled) => state = enabled;
}

/// Whether writing is currently permitted, and why not if it is refused.
final writePermissionProvider = Provider<WritePermission>((ref) {
  final connection = ref.watch(connectionProvider);
  final writeMode = ref.watch(writeModeProvider);
  if (connection is! EcuConnected) {
    return const WritePermission.refused('Not connected to an ECU.');
  }
  return WritePermission.evaluate(
    definition: connection.definition,
    reportedSignature: connection.identification.signature,
    writeModeEnabled: writeMode,
  );
});

/// How far through reading the tune we are.
class TuneLoadProgress {
  const TuneLoadProgress(this.page, this.total);
  final int page;
  final int total;

  double get fraction => total == 0 ? 0 : page / total;
}

/// The tune read from the connected ECU.
final tuneProvider = AsyncNotifierProvider<TuneController, TuneState?>(
  TuneController.new,
);

/// The shared value resolver for the loaded tune.
final tuneResolverProvider = Provider<TuneValueResolver?>((ref) {
  // Depend on the tune so this refreshes as edits land.
  ref.watch(tuneProvider);
  return ref.read(tuneProvider.notifier).resolver;
});

/// The tune as it was last read from the ECU, or last burned to it.
///
/// Editing is compared against this so the editor can show what this session
/// has changed but not yet committed.
final tuneBaselineProvider = Provider<TuneState?>((ref) {
  // Depend on the tune so this refreshes as edits land.
  ref.watch(tuneProvider);
  return ref.read(tuneProvider.notifier).baseline;
});

class TuneController extends AsyncNotifier<TuneState?> {
  TuneLoadProgress? _progress;
  TuneState? _baseline;
  TuneValueResolver? _resolver;

  /// Host-side values as last saved, so a save happens only on a change.
  Map<String, List<double>> _savedHost = const {};

  /// The tune as last synchronised with the ECU.
  TuneState? get baseline => _baseline;

  /// A resolver shared across the screens reading this tune.
  ///
  /// Building one compiles every computed channel in the definition, which is
  /// not something to redo on each frame of a dragged slider. Edits invalidate
  /// its cache instead of replacing it.
  TuneValueResolver? get resolver => _resolver;

  /// Progress of the current read, or `null` when not loading.
  TuneLoadProgress? get progress => _progress;

  @override
  Future<TuneState?> build() async {
    final connection = ref.watch(connectionProvider);
    if (connection is! EcuConnected) return null;

    final definition = connection.definition;
    final client = ref.read(connectionProvider.notifier).client;
    if (definition == null || client == null) return null;

    final blockingFactor = definition.constants.blockingFactor;
    if (blockingFactor == null) {
      throw StateError(
        'The definition declares no blockingFactor, so pages '
        'cannot be read safely.',
      );
    }

    final tune = TuneState.empty(definition);
    await TuneWriter.readAll(
      client,
      into: tune,
      blockingFactor: blockingFactor,
      onProgress: (page, total) => _progress = TuneLoadProgress(page, total),
    );
    _progress = null;
    // Gauge Limits and other host-side values live on this computer, not the
    // ECU, so they come back from the last session rather than from the read.
    _savedHost = await HostValues(ref.read(jsonStoreProvider))
        .restoreInto(tune);
    // Everything from here on is compared against what the ECU actually holds.
    _baseline = tune.copy();
    _resolver = TuneValueResolver(tune);
    return tune;
  }

  /// Re-reads every page from the ECU, discarding unsaved edits.
  Future<void> reload() async {
    state = const AsyncValue.loading();
    ref.invalidateSelf();
  }

  /// Signals that the tune changed, so dependents rebuild.
  void notifyEdited() {
    final tune = state.valueOrNull;
    if (tune == null) return;
    // A setting just changed, and other settings' scales, bounds and
    // visibility conditions may be expressed in terms of it.
    _resolver?.invalidate();
    // If it was a host-side one - a Gauge Limit - it has to outlive the
    // session. Nothing is written unless one actually changed.
    _savedHost = HostValues(ref.read(jsonStoreProvider))
        .saveIfChanged(tune, _savedHost);
    state = AsyncValue.data(tune);
  }

  /// Writes, verifies and burns every page with unsaved changes.
  ///
  /// Throws [WriteRefusedException] if the guard rails forbid it.
  Future<List<CommitResult>> commitDirtyPages() async {
    final tune = state.valueOrNull;
    final connection = ref.read(connectionProvider);
    final client = ref.read(connectionProvider.notifier).client;
    if (tune == null || client == null || connection is! EcuConnected) {
      throw WriteRefusedException('Not connected to an ECU.');
    }

    final definition = connection.definition!;
    final writer = TuneWriter(
      client: client,
      tune: tune,
      permission: ref.read(writePermissionProvider),
      blockingFactor: definition.constants.blockingFactor!,
      burnCommand: _burnCommandFor(definition.constants.burnCommands),
      onSnapshot: _saveSnapshot,
    );

    final results = await writer.commitDirtyPages();
    // The ECU now holds what we hold, so the comparison restarts from here.
    _baseline = tune.copy();
    notifyEdited();
    return results;
  }

  /// Picks the burn command variant the definition declares.
  ///
  /// COMMS_COMPAT builds use `B`, which deliberately slows the EEPROM write.
  static int _burnCommandFor(List<String> templates) {
    final first = templates.isEmpty ? '' : templates.first;
    return first.startsWith('B')
        ? SpeeduinoCommand.burnCompat
        : SpeeduinoCommand.burn;
  }

  /// Writes a restore point before the session's first write.
  static Future<void> _saveSnapshot(TuneState snapshot) async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/FoxTune/snapshots');
    await folder.create(recursive: true);

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    // Raw page bytes, concatenated. Enough to restore exactly what was there
    // before this session touched anything.
    final bytes = <int>[
      for (var page = 1; page <= snapshot.pageCount; page++)
        ...snapshot.page(page),
    ];
    await File('${folder.path}/tune-$stamp.bin').writeAsBytes(bytes);
  }
}
