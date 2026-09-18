import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import 'tune_controller.dart';

/// Saving and loading TunerStudio `.msq` tune files.
///
/// Loading only changes the in-memory tune. Nothing reaches the ECU until the
/// user burns, which keeps the guard rails in one place rather than giving a
/// file load its own path to the hardware.
abstract final class MsqActions {
  /// Writes the current tune to a file the user chooses.
  static Future<void> save(
    BuildContext context,
    WidgetRef ref,
    TuneState tune,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final signature = tune.definition.identity.signature ?? 'tune';
    final suggested =
        '${signature.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.msq';

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save tune',
      fileName: suggested,
      type: FileType.custom,
      allowedExtensions: const ['msq'],
    );
    if (path == null) return;

    try {
      final xml = MsqCodec.encode(tune, tuneComment: 'Saved by FoxTune');
      await File(path).writeAsString(xml);
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${path.split('/').last}')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not save: $error'),
        ),
      );
    }
  }

  /// Loads a `.msq` into the in-memory tune.
  static Future<void> load(
    BuildContext context,
    WidgetRef ref,
    TuneState tune,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Open tune',
      type: FileType.custom,
      allowedExtensions: const ['msq'],
    );
    final path = result?.files.single.path;
    if (path == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    String xml;
    try {
      xml = await File(path).readAsString();
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not read the file: $error'),
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
