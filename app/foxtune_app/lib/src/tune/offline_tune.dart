import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show EcuIdentification;
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../definitions/choose_definition.dart';
import '../definitions/definition_library.dart';
import '../storage/json_store.dart';
import 'host_values.dart';
import 'msq_actions.dart';

/// A tune opened from a `.msq` file, with no ECU.
///
/// Edited like an ECU's tune, and saved back out as a `.msq`. It never reaches
/// an ECU from here: that is done by connecting and loading the file into the
/// ECU's tune, then burning, so every write still goes through the one path
/// with the guard rails on it.
class OfflineTune {
  const OfflineTune({
    required this.tune,
    required this.fileName,
    required this.saved,
  });

  final TuneState tune;

  /// The file it was opened from or last saved as, for suggesting where to
  /// save it.
  final String fileName;

  /// The tune as opened or last saved: what its changes are shown against.
  final TuneState saved;

  /// Whether it has changes not yet saved.
  bool get unsaved => tune.isDirty;
}

/// The tune open with no ECU, if one is.
final offlineTuneProvider =
    NotifierProvider<OfflineTuneController, OfflineTune?>(
      OfflineTuneController.new,
    );

/// Whether the tune being edited is a file rather than an ECU's.
///
/// A connection takes over while it lasts: the file stays open behind it,
/// changes and all, and comes back when it ends.
final editingOfflineProvider = Provider<bool>(
  (ref) =>
      ref.watch(connectionProvider) is! EcuConnected &&
      ref.watch(offlineTuneProvider) != null,
);

class OfflineTuneController extends Notifier<OfflineTune?> {
  @override
  OfflineTune? build() => null;

  /// Opens [tune], read from [fileName], as it stands.
  void open(TuneState tune, String fileName) {
    tune.markClean();
    state = OfflineTune(tune: tune, fileName: fileName, saved: tune.copy());
  }

  /// Records that the open tune has been saved, as [fileName] where given.
  void markSaved([String? fileName]) {
    final current = state;
    if (current == null) return;
    current.tune.markClean();
    state = OfflineTune(
      tune: current.tune,
      fileName: fileName ?? current.fileName,
      saved: current.tune.copy(),
    );
  }

  /// Lets go of the open tune, changes and all.
  void close() => state = null;

  /// Asks for a `.msq`, finds the definition that reads it, and opens it.
  static Future<void> pickAndOpen(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    void problem(String message) => messenger.showSnackBar(
      SnackBar(
        backgroundColor: StatusPalette.critical,
        content: Text(message),
        duration: const Duration(seconds: 8),
      ),
    );

    final picked = await MsqActions.pick(
      context,
      ref,
      dialogTitle: 'Open tune',
    );
    if (picked == null || !context.mounted) return;
    final xml = picked.text;

    final String? signature;
    try {
      signature = MsqCodec.signatureOf(xml);
    } on MsqException catch (error) {
      problem('${picked.name}: ${error.message}');
      return;
    }
    if (signature == null || signature.isEmpty) {
      problem(
        '${picked.name} does not say which firmware it is for, so there is '
        'no telling which definition reads it.',
      );
      return;
    }

    final definition = await _definitionFor(context, ref, signature);
    if (definition == null || !context.mounted) return;

    final tune = TuneState.empty(definition);
    final outcome = await MsqActions.decodeInto(context, tune, xml);
    if (outcome == null || !context.mounted) return;
    if (!outcome.isClean || outcome.converted.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(MsqActions.describe(outcome))),
      );
    }
    // Gauge Limits and the rest of [PcVariables] are this computer's, kept
    // per ECU family, not the file's - a .msq carries none - so they come back
    // as for a connection, and edits to them are kept the same way.
    await HostValues(ref.read(jsonStoreProvider)).restoreInto(tune);
    if (!context.mounted) return;
    ref.read(offlineTuneProvider.notifier).open(tune, picked.name);
  }

  /// The definition for a tune saved for [signature], found or chosen.
  static Future<IniDocument?> _definitionFor(
    BuildContext context,
    WidgetRef ref,
    String signature,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final library = ref.read(definitionLibraryProvider);

    DefinitionLookup lookup;
    try {
      lookup = await library.find(
        EcuIdentification(signature: signature, version: ''),
      );
    } on Object catch (error) {
      lookup = DefinitionMissing('Looking for it failed: $error');
    }

    switch (lookup) {
      case DefinitionFound(:final definition):
        return definition;
      case DefinitionMissing(:final reason):
        if (!context.mounted) return null;
        final choose = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No definition for this tune'),
            content: Text(
              'The tune is for "$signature". $reason\n\n'
              'Choose its definition file to go on.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Choose the definition file'),
              ),
            ],
          ),
        );
        if (choose != true) return null;

        final picked = await pickDefinitionFile(
          ref,
          messenger,
          title: 'Definition for $signature',
        );
        if (picked == null) return null;
        try {
          return await library.adopt(
            decodeDefinition(picked.bytes),
            signature: signature,
            fileName: picked.name,
          );
        } on DefinitionMismatchException catch (error) {
          tellAboutDefinition(
            messenger,
            'That definition is for '
            '"${error.file ?? 'an unnamed firmware'}", but the tune is for '
            '"$signature".',
            problem: true,
          );
        } on IniParseException catch (error) {
          tellAboutDefinition(
            messenger,
            '${picked.name} is not a definition FoxTune can read: $error',
            problem: true,
          );
        }
        return null;
    }
  }

  /// Asks whether to let go of unsaved changes; `true` when there are none.
  static Future<bool> confirmClose(
    BuildContext context,
    OfflineTune open,
  ) async {
    if (!open.unsaved) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Close without saving?'),
            content: Text(
              'The changes to ${open.fileName} have not been saved. Closing '
              'it now discards them.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
