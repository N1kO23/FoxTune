import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import 'tune_controller.dart';

/// Unburned edits kept back when a connection ended.
///
/// The loaded tune belongs to the connection: when the connection goes, the
/// tune goes with it. Without this, any edit not yet burned would vanish with
/// no trace - and on a phone in a car the connection can end with nothing
/// more than a knocked cable.
class RecoveredEdits {
  RecoveredEdits({required this.tune, required this.pages, required this.at});

  /// A copy of the tune as it stood, edits included.
  final TuneState tune;

  /// The pages that held unburned changes.
  final Set<int> pages;

  /// When the connection ended.
  final DateTime at;

  /// The signature the tune was read from, for naming a saved file.
  String get signature => tune.definition.identity.signature ?? 'tune';
}

/// Edits rescued from the last connection, until saved or discarded.
final recoveredEditsProvider =
    NotifierProvider<RecoveredEditsController, RecoveredEdits?>(
      RecoveredEditsController.new,
    );

class RecoveredEditsController extends Notifier<RecoveredEdits?> {
  @override
  RecoveredEdits? build() => null;

  /// Holds [edits] until they are saved or discarded.
  void keep(RecoveredEdits edits) => state = edits;

  /// Lets go of the edits, once saved or discarded.
  void clear() => state = null;
}

/// Rescues unburned edits when a connection ends.
///
/// The loaded tune is rebuilt - to nothing - as soon as the connection
/// changes, so the tune is remembered as it loads and checked the moment the
/// connection leaves [EcuConnected]. This lives apart from both the tune and
/// the connection because it has to watch the two of them, and the tune
/// already depends on the connection: having either one reach into the other
/// is a cycle.
///
/// Watched from the app shell so it lives as long as the app does.
final unburnedEditsGuardProvider = Provider<void>((ref) {
  TuneState? loaded;

  ref.listen<AsyncValue<TuneState?>>(tuneProvider, (previous, next) {
    final tune = next.value;
    if (tune != null) loaded = tune;
  }, fireImmediately: true);

  ref.listen<EcuConnectionState>(connectionProvider, (previous, next) {
    if (previous is! EcuConnected || next is EcuConnected) return;
    final tune = loaded;
    loaded = null;
    if (tune == null || !tune.isDirty) return;

    ref
        .read(recoveredEditsProvider.notifier)
        .keep(
          RecoveredEdits(
            tune: tune.copy(),
            pages: tune.dirtyPages,
            at: DateTime.now(),
          ),
        );
  });
});
