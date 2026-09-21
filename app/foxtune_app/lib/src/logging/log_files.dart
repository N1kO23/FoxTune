import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';

/// Where datalogs are recorded.
///
/// App storage rather than a folder the user picks: a log is appended row by
/// row for as long as the engine runs, and the system "Save to" picker on a
/// phone hands back a destination this process cannot keep a file open on.
/// Logs are written here and saved out afterwards with [LogFiles.save].
final logDirectoryProvider = FutureProvider<Directory>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory('${documents.path}/FoxTune/logs');
});

/// Recorded logs, newest first.
final recentLogsProvider = FutureProvider<List<File>>((ref) async {
  final directory = await ref.watch(logDirectoryProvider.future);
  if (!directory.existsSync()) return const [];

  final logs = [
    for (final entity in directory.listSync())
      if (entity is File && entity.path.toLowerCase().endsWith('.msl')) entity,
  ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
  return logs.take(20).toList();
});

/// Getting recorded logs off the device.
abstract final class LogFiles {
  /// Saves [log] wherever the user chooses.
  ///
  /// On a phone this is the only way a log leaves app storage, which nothing
  /// but FoxTune can see.
  static Future<void> save(
    BuildContext context,
    WidgetRef ref,
    File log,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final name = log.path.split(RegExp(r'[/\\]')).last;
    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveBytes(
            dialogTitle: 'Save log',
            fileName: name,
            extension: 'msl',
            bytes: await log.readAsBytes(),
          );
      if (saved == null) return;
      messenger.showSnackBar(SnackBar(content: Text('Saved $saved')));
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not save the log: $error'),
        ),
      );
    }
  }

  /// Lists recorded logs with a way to save each one.
  static Future<void> showList(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (_) => const _LogList(),
      );
}

class _LogList extends ConsumerWidget {
  const _LogList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final logs = ref.watch(recentLogsProvider);

    return SafeArea(
      child: logs.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not list logs: $error'),
        ),
        data: (files) => files.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No logs recorded yet.'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Recorded logs',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  for (final file in files)
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(
                        file.path.split(RegExp(r'[/\\]')).last,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_describe(file)),
                      trailing: TextButton.icon(
                        onPressed: () => LogFiles.save(context, ref, file),
                        icon: const Icon(Icons.save_alt, size: 18),
                        label: const Text('Save'),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  static String _describe(File file) {
    final bytes = file.lengthSync();
    final size = bytes >= 1024 * 1024
        ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
        : '${(bytes / 1024).toStringAsFixed(0)} kB';
    final modified = file.lastModifiedSync();
    final when =
        '${modified.year}-${_two(modified.month)}-${_two(modified.day)} '
        '${_two(modified.hour)}:${_two(modified.minute)}';
    return '$when · $size';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}
