import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'tune_controller.dart';

/// Import and export of a single table as a TunerStudio `.table` file.
///
/// Like a `.msq` load, an import only changes the in-memory tune. Nothing
/// reaches the ECU until the user burns.
abstract final class TableFileActions {
  /// Writes the open table to a file the user chooses.
  static Future<void> export(
    BuildContext context,
    WidgetRef ref,
    TableView view,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final suggested =
        '${view.table.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.table';

    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveText(
            dialogTitle: 'Export ${view.title}',
            fileName: suggested,
            extension: 'table',
            text: TableFileCodec.encode(view),
          );
      if (saved == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Exported ${view.title} to $saved')),
      );
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not export: $error'),
        ),
      );
    }
  }

  /// Loads a `.table` file into the open table.
  static Future<void> import(
    BuildContext context,
    WidgetRef ref,
    TableView view,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    TableFileData data;
    try {
      final picked = await ref
          .read(fileSavingProvider)
          .pickFile(
            dialogTitle: 'Import into ${view.title}',
            extensions: const ['table'],
          );
      if (picked == null || !context.mounted) return;
      data = TableFileCodec.decode(picked.text);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text(switch (error) {
            TableFileException(:final message) => message,
            WrongFileTypeException(:final message) => message,
            _ => 'Could not read the file: $error',
          }),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    if (!context.mounted) return;
    final choice = await showDialog<_ImportChoice>(
      context: context,
      builder: (_) => _ImportDialog(view: view, data: data),
    );
    if (choice == null) return;

    final outcome = TableFileCodec.applyTo(
      view,
      data,
      importAxes: choice.importAxes,
    );
    ref.read(tuneProvider.notifier).notifyEdited();

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          outcome.resampled
              ? 'Imported ${outcome.sourceShape} into ${outcome.targetShape}, '
                    'interpolated onto this table\'s axes. Burn to apply.'
              : 'Imported ${outcome.cellsWritten} cells'
                    '${outcome.axesWritten ? ' and the axes' : ''}. '
                    'Burn to apply.',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

class _ImportChoice {
  const _ImportChoice({required this.importAxes});
  final bool importAxes;
}

/// Confirms an import, stating plainly what it will do.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.view, required this.data});

  final TableView view;
  final TableFileData data;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  bool _importAxes = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sameShape =
        widget.data.rows == widget.view.rows &&
        widget.data.columns == widget.view.columns;

    return AlertDialog(
      title: Text('Import into ${widget.view.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'File: ${widget.data.rows} x ${widget.data.columns}     '
            'This table: ${widget.view.rows} x ${widget.view.columns}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (sameShape)
            const Text('The shapes match, so values are copied cell for cell.')
          else
            Text(
              'The shapes differ, so the file will be interpolated onto this '
              "table's axes. Values outside the file's range hold at its edge "
              'rather than being extrapolated.',
              style: theme.textTheme.bodyMedium,
            ),
          const SizedBox(height: 12),
          Text(
            'Values are clamped to what the definition permits, and nothing '
            'reaches the ECU until you burn.',
            style: theme.textTheme.bodySmall,
          ),
          if (sameShape) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _importAxes,
              // Off by default: importing values is the common case, and
              // moving the axes changes what every other row and column means.
              onChanged: (v) => setState(() => _importAxes = v ?? false),
              title: const Text('Also replace the axis bins'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_ImportChoice(importAxes: _importAxes)),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
