import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
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
    final suggested =
        '${signature.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.msq';

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
    String xml;
    try {
      final picked = await ref
          .read(fileSavingProvider)
          .pickFile(dialogTitle: 'Open tune', extensions: const ['msq']);
      if (picked == null || !context.mounted) return;
      xml = picked.text;
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
      return;
    }

    // Try strictly first. A signature mismatch is a real hazard, so the user
    // has to see it and agree rather than having it waved through.
    MsqImportResult outcome;
    try {
      outcome = MsqCodec.decode(xml, tune);
    } on MsqException catch (error) {
      if (!context.mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (_) => _MismatchDialog(message: error.message),
      );
      if (proceed != true) return;
      try {
        outcome = MsqCodec.decode(xml, tune, requireSignatureMatch: false);
      } on MsqException catch (retryError) {
        messenger.showSnackBar(
          SnackBar(
            backgroundColor: StatusPalette.critical,
            content: Text(retryError.message),
          ),
        );
        return;
      }
    }

    ref.read(tuneProvider.notifier).notifyEdited();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.isClean
              ? 'Loaded ${outcome.applied} values. Burn to apply them to the ECU.'
              : 'Loaded ${outcome.applied} values; '
                    '${outcome.skipped.length} skipped, '
                    '${outcome.unknown.length} unrecognised. '
                    'Burn to apply them to the ECU.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }
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
