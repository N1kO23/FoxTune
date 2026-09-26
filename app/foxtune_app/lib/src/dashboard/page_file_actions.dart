import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import '../files/file_saving.dart';
import 'gauge_status.dart';
import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';
import 'layout/page_file.dart';

/// Export and import of one dashboard page as a `.foxdash` file.
///
/// An import is added as a page of its own, so it never replaces one. It can
/// come from any ECU: whatever this one's definition lacks is left out, and
/// the user is told what before anything changes.
abstract final class PageFileActions {
  /// Writes [page], with the limits of the gauges on it, to a file the user
  /// chooses.
  static Future<void> export(
    BuildContext context,
    WidgetRef ref, {
    required DashboardPage page,
    required IniDocument definition,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final layout = ref.read(dashboardLayoutProvider).value;
    if (layout == null) return;
    final stem = page.name.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveText(
            dialogTitle: 'Export ${page.name}',
            fileName:
                '${stem.isEmpty ? 'dashboard' : stem}'
                '.$dashboardPageExtension',
            extension: dashboardPageExtension,
            text: DashboardPageFile.of(page, layout, definition).encode(),
          );
      if (saved == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Exported "${page.name}" to $saved')),
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

  /// Asks for a page file and adds it as a new page. Returns the new page's
  /// id, or `null` if nothing was added.
  static Future<String?> import(
    BuildContext context,
    WidgetRef ref, {
    required IniDocument definition,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    void complain(String message) => messenger.showSnackBar(
      SnackBar(
        backgroundColor: StatusPalette.critical,
        content: Text(message),
        duration: const Duration(seconds: 6),
      ),
    );

    final DashboardPageFile file;
    try {
      final picked = await ref
          .read(fileSavingProvider)
          .pickFile(
            dialogTitle: 'Import a dashboard page',
            extensions: const [dashboardPageExtension],
          );
      if (picked == null) return null;
      file = DashboardPageFile.decode(picked.text);
    } on Object catch (error) {
      complain(switch (error) {
        PageFileException(:final message) => message,
        WrongFileTypeException(:final message) => message,
        _ => 'Could not read the file: $error',
      });
      return null;
    }

    final fitted = file.fitTo(definition);
    if (fitted.page.items.isEmpty) {
      complain(
        'Nothing on "${file.page.name}" is in this ECU\'s definition, so '
        'there is nothing to import.',
      );
      return null;
    }

    if (!context.mounted) return null;
    final choice = await showDialog<_ImportChoice>(
      context: context,
      builder: (_) => _ImportDialog(
        file: file,
        fitted: fitted,
        sameEcu: file.isFor(definition),
      ),
    );
    if (choice == null || !context.mounted) return null;

    final id = ref
        .read(dashboardLayoutProvider.notifier)
        .importPage(fitted.page, choice.limits ? fitted.limits : const {});
    final left = fitted.missing.length;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Imported "${fitted.page.name}"'
          '${left == 0 ? '' : ', leaving out ${_count(left, 'gauge')}'}.',
        ),
      ),
    );
    return id;
  }
}

String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

class _ImportChoice {
  const _ImportChoice({required this.limits});

  /// Whether the limits in the file are used.
  final bool limits;
}

/// Says what an import will do before it does it: above all, what it leaves
/// out.
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({
    required this.file,
    required this.fitted,
    required this.sameEcu,
  });

  final DashboardPageFile file;
  final PageImport fitted;
  final bool sameEcu;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  // Off by default: the page is the common case, and a limit belongs to the
  // gauge, so taking the file's changes every other page showing it too.
  bool _limits = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final DashboardPageFile(:page, :ecu) = widget.file;
    final madeOn = ecu ?? 'an ECU it does not name';
    final fitted = widget.fitted;
    final missing = fitted.missing;
    final limits = fitted.limits.length;

    return AlertDialog(
      title: Text('Import "${page.name}"'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'It is added as a new page, with '
              '${_count(fitted.page.items.length, 'gauge')}.',
            ),
            if (!widget.sameEcu) ...[
              const SizedBox(height: 12),
              Text(
                'It was made on $madeOn, not this one.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: StatusPalette.warning,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "${_count(missing.length, 'gauge')} on it "
                      "${missing.length == 1 ? 'is' : 'are'} not in this "
                      "ECU's definition, and will not be added: "
                      '${missing.join(', ')}.',
                    ),
                  ),
                ],
              ),
            ],
            if (limits > 0) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _limits,
                onChanged: (v) => setState(() => _limits = v ?? false),
                title: Text('Use its limits for ${_count(limits, 'gauge')}'),
                subtitle: Text(
                  'They replace any set here, on every page showing '
                  '${limits == 1 ? 'that gauge' : 'those gauges'}. Left '
                  'off, the gauges keep the limits they have here.',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_ImportChoice(limits: _limits)),
          child: const Text('Import'),
        ),
      ],
    );
  }
}
