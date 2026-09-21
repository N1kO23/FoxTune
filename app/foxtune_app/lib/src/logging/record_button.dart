import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/gauge_status.dart';
import 'log_controller.dart';
import 'log_files.dart';

/// Start/stop control for datalogging, with live status.
class RecordButton extends ConsumerStatefulWidget {
  const RecordButton({super.key});

  @override
  ConsumerState<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends ConsumerState<RecordButton> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Rows arrive far faster than anyone can read them, so the counter is
    // refreshed on a slow tick rather than rebuilt per sample.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      ref.read(logSessionProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(logSessionProvider);
    final theme = Theme.of(context);

    ref.listen(logSessionProvider, (previous, next) {
      final error = next.error;
      if (error != null && error != previous?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: StatusPalette.critical,
            content: Text(error),
          ),
        );
      }
      if ((previous?.recording ?? false) && !next.recording) {
        final path = next.path;
        if (path != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Recorded ${next.rows} rows'),
              duration: const Duration(seconds: 8),
              // The log is in app storage, which on a phone nothing else can
              // see; saving it out is the step that makes it usable.
              action: SnackBarAction(
                label: 'Save log…',
                onPressed: () => LogFiles.save(context, ref, File(path)),
              ),
            ),
          );
        }
      }
    });

    if (!session.recording) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            onPressed: () => ref.read(logSessionProvider.notifier).start(),
            icon: const Icon(Icons.fiber_manual_record, size: 16),
            label: const Text('Record'),
          ),
          IconButton(
            tooltip: 'Recorded logs',
            onPressed: () => LogFiles.showList(context),
            icon: const Icon(Icons.folder_open_outlined),
          ),
        ],
      );
    }

    final minutes = session.elapsed.inMinutes.toString().padLeft(2, '0');
    final seconds = (session.elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: StatusPalette.critical,
          ),
          onPressed: () => ref.read(logSessionProvider.notifier).stop(),
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('Stop'),
        ),
        const SizedBox(width: 10),
        Text(
          '$minutes:$seconds · ${session.rows} rows',
          style: theme.textTheme.labelSmall?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (session.droppedChannels.isNotEmpty) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: 'Not logged: ${session.droppedChannels.join(", ")}',
            child: Icon(
              Icons.info_outline,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
