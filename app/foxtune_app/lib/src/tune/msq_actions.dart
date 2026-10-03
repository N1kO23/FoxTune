import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'offline_tune.dart';
import 'tune_controller.dart';

/// Saving and loading TunerStudio `.msq` tune files.
///
/// Loading only changes the in-memory tune. Nothing reaches the ECU until the
/// user burns, which keeps the guard rails in one place rather than giving a
/// file load its own path to the hardware.
abstract final class MsqActions {
  /// Writes [tune] to a file the user chooses.
  ///
  /// Returns whether it was saved, so a caller holding edits that exist
  /// nowhere else knows when it is safe to let them go.
  static Future<bool> save(
    BuildContext context,
    WidgetRef ref,
    TuneState tune,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final signature = tune.definition.identity.signature ?? 'tune';
    // A file being edited is saved under its own name by default.
    final open = ref.read(offlineTuneProvider);
    final isOpenFile = identical(open?.tune, tune);
    final suggested = isOpenFile
        ? open!.fileName
        : '${signature.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.msq';

    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveText(
            dialogTitle: 'Save tune',
            fileName: suggested,
            extension: 'msq',
            text: MsqCodec.encode(tune, tuneComment: 'Saved by FoxTune'),
          );
      if (saved == null) return false;
      if (isOpenFile) {
        ref
            .read(offlineTuneProvider.notifier)
            .markSaved(saved.split(RegExp(r'[/\\]')).last);
        ref.read(tuneProvider.notifier).notifyEdited();
      }
      messenger.showSnackBar(SnackBar(content: Text('Saved $saved')));
      return true;
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not save: $error'),
        ),
      );
      return false;
    }
  }

  /// Loads a `.msq` into the in-memory tune.
  static Future<void> load(
    BuildContext context,
    WidgetRef ref,
    TuneState tune,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pick(context, ref);
    if (picked == null || !context.mounted) return;

    final outcome = await decodeInto(context, tune, picked.text);
    if (outcome == null) return;

    ref.read(tuneProvider.notifier).notifyEdited();
    messenger.showSnackBar(
      SnackBar(
        content: Text('${describe(outcome)} Burn to apply them to the ECU.'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  /// Asks the user for a `.msq`; `null` if they cancelled or it could not be
  /// read, which is said.
  static Future<PickedFile?> pick(
    BuildContext context,
    WidgetRef ref, {
    String dialogTitle = 'Open tune',
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      return await ref
          .read(fileSavingProvider)
          .pickFile(dialogTitle: dialogTitle, extensions: const ['msq']);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text(
            error is WrongFileTypeException
                ? error.message
                : 'Could not read the file: $error',
          ),
        ),
      );
      return null;
    }
  }

  /// Reads [xml] into [tune]; `null` if the user declined a mismatch or the
  /// file could not be read, which is said.
  static Future<MsqImportResult?> decodeInto(
    BuildContext context,
    TuneState tune,
    String xml,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    // Try strictly first. A signature mismatch is a real hazard, so the user
    // has to see it and agree rather than having it waved through.
    try {
      return MsqCodec.decode(xml, tune);
    } on MsqException catch (error) {
      if (!context.mounted) return null;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => _MismatchDialog(message: error.message),
      );
      if (proceed != true) return null;
      try {
        return MsqCodec.decode(xml, tune, requireSignatureMatch: false);
      } on MsqException catch (retryError) {
        messenger.showSnackBar(
          SnackBar(
            backgroundColor: StatusPalette.critical,
            content: Text(retryError.message),
          ),
        );
        return null;
      }
    }
  }

  /// What a load came to, fit to show a user.
  static String describe(MsqImportResult outcome) => [
    outcome.isClean
        ? 'Loaded ${outcome.applied} values.'
        : 'Loaded ${outcome.applied} values; '
              '${outcome.skipped.length} skipped, '
              '${outcome.unknown.length} unrecognised.',
    // Said, because a tuner comparing against the file would otherwise see
    // every temperature changed.
    if (outcome.converted.isNotEmpty)
      '${outcome.converted.length} were saved in the other temperature '
          'scale, and converted.',
  ].join(' ');
}

class _MismatchDialog extends StatelessWidget {
  const _MismatchDialog({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Icon(Icons.warning_amber_rounded, color: StatusPalette.warning),
    title: const Text('Tune does not match this ECU'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(message),
        const SizedBox(height: 12),
        const Text(
          'Values are matched by name, so anything the two firmwares share '
          'will load and the rest will be reported. Settings that moved '
          'between versions may still be wrong.',
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Load anyway'),
      ),
    ],
  );
}
