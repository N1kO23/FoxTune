import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_editor.dart' show confirm;
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import '../window/window_app_bar.dart';
import 'choose_definition.dart';
import 'definition_library.dart';

/// Every ECU definition FoxTune has, and where to add, save and remove them.
///
/// The built-in one first, then those kept on this device: downloaded or
/// chosen when connecting, or added here ahead of time - which is how to have
/// one ready for an ECU somewhere without internet.
class DefinitionsScreen extends ConsumerStatefulWidget {
  const DefinitionsScreen({super.key});

  /// Opens the list over [context].
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const DefinitionsScreen()));

  @override
  ConsumerState<DefinitionsScreen> createState() => _DefinitionsScreenState();
}

class _DefinitionsScreenState extends ConsumerState<DefinitionsScreen> {
  /// Whether a file is being read - a rusEFI definition takes a moment.
  bool _adding = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = ref.watch(definitionEntriesProvider);
    final connection = ref.watch(connectionProvider);
    final inUse = connection is EcuConnected
        ? connection.definition?.identity.signature
        : null;

    return Scaffold(
      appBar: const WindowAppBar(title: Text('ECU definitions')),
      body: SafeArea(
        child: entries.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not list the definitions: $error'),
            ),
          ),
          data: (list) {
            final kept = [
              for (final entry in list)
                if (!entry.isBuiltIn) entry,
            ];
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Text(
                        'An ECU is read through the definition for its exact '
                        'firmware build, matched by the signature it reports. '
                        'FoxTune looks for it built in first, then among those '
                        'kept on this device, then - if App settings allow - '
                        'downloads it.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const _Heading('Built in'),
                    for (final entry in list)
                      if (entry.isBuiltIn)
                        _EntryTile(
                          entry: entry,
                          inUse: entry.signature == inUse,
                          onSave: () => _save(entry),
                        ),
                    _Heading(
                      'On this device',
                      trailing: FilledButton.tonalIcon(
                        onPressed: _adding ? null : _add,
                        icon: _adding
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add),
                        label: const Text('Add from file'),
                      ),
                    ),
                    if (kept.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Text(
                          'None yet. A definition downloaded or chosen when '
                          'connecting is kept here. Adding one ahead of time '
                          'lets the ECU it is for connect without internet.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    for (final entry in kept)
                      _EntryTile(
                        entry: entry,
                        inUse: entry.signature == inUse,
                        onSave: entry.problem == null
                            ? () => _save(entry)
                            : null,
                        onRemove: () =>
                            _remove(entry, inUse: entry.signature == inUse),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _tell(ScaffoldMessengerState messenger, String message) =>
      tellAboutDefinition(messenger, message);

  void _complain(ScaffoldMessengerState messenger, String message) =>
      tellAboutDefinition(messenger, message, problem: true);

  Future<void> _add() async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await pickDefinitionFile(
      ref,
      messenger,
      title: 'Add a definition',
    );
    if (picked == null || !mounted) return;
    await _keep(picked, messenger);
  }

  /// Runs [work] with the Add button showing it is busy.
  ///
  /// Reading a definition holds up the screen while it runs - a rusEFI one is
  /// some 13,000 lines - so the button is drawn busy before it starts, to say
  /// why.
  Future<T> _busy<T>(Future<T> Function() work) async {
    setState(() => _adding = true);
    await WidgetsBinding.instance.endOfFrame;
    try {
      return await work();
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Keeps [picked], asking first before it replaces one kept already.
  Future<void> _keep(
    PickedFile picked,
    ScaffoldMessengerState messenger, {
    bool replace = false,
  }) async {
    final DefinitionEntry entry;
    try {
      entry = await _busy(
        () => ref
            .read(definitionLibraryProvider)
            .add(
              decodeDefinition(picked.bytes),
              fileName: picked.name,
              replace: replace,
            ),
      );
    } on DefinitionExistsException catch (error) {
      if (!mounted) return;
      final proceed = await confirm(
        context,
        title: 'Replace the kept definition?',
        message:
            'A definition for "${error.signature}" is kept already. '
            'Replace it with ${picked.name}?',
        action: 'Replace',
      );
      if (proceed) await _keep(picked, messenger, replace: true);
      return;
    } on DefinitionRefusedException catch (error) {
      _complain(messenger, '${picked.name}: ${error.message}');
      return;
    } on Object catch (error) {
      _complain(
        messenger,
        '${picked.name} is not a definition FoxTune can read: $error',
      );
      return;
    }
    ref.invalidate(definitionEntriesProvider);

    // An ECU connected and waiting for this very definition takes it at once.
    final connection = ref.read(connectionProvider);
    if (connection is EcuConnected &&
        !connection.definitionMatches &&
        connection.identification.signature.trim() == entry.signature) {
      await ref.read(connectionProvider.notifier).retryDefinition();
      _tell(messenger, 'Added ${entry.name}, and it is now in use.');
    } else {
      _tell(messenger, 'Added ${entry.name}.');
    }
  }

  Future<void> _save(DefinitionEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveBytes(
            dialogTitle: 'Save definition',
            fileName: entry.suggestedFileName,
            extension: 'ini',
            bytes: await ref.read(definitionLibraryProvider).bytesOf(entry),
          );
      if (saved != null) _tell(messenger, 'Saved $saved');
    } on Object catch (error) {
      _complain(messenger, 'Could not save the definition: $error');
    }
  }

  Future<void> _remove(DefinitionEntry entry, {required bool inUse}) async {
    final messenger = ScaffoldMessenger.of(context);
    final proceed = await confirm(
      context,
      title: 'Remove ${entry.name}?',
      message: inUse
          ? 'It is deleted from this device. The connected ECU carries on '
                'with it until you disconnect; next time it is looked for '
                'again.'
          : 'It is deleted from this device. An ECU that needs it is looked '
                'for again when it connects.',
      action: 'Remove',
    );
    if (!proceed) return;
    try {
      await ref.read(definitionLibraryProvider).remove(entry);
    } on Object catch (error) {
      _complain(messenger, 'Could not remove it: $error');
      return;
    }
    ref.invalidate(definitionEntriesProvider);
    _tell(messenger, 'Removed ${entry.name}.');
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

enum _EntryAction { save, remove }

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.inUse,
    this.onSave,
    this.onRemove,
  });

  final DefinitionEntry entry;
  final bool inUse;
  final VoidCallback? onSave;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = entry.problem;

    return ListTile(
      leading: Icon(
        problem != null
            ? Icons.error_outline
            : switch (entry.source) {
                DefinitionSource.bundled => Icons.inventory_2_outlined,
                DefinitionSource.downloaded => Icons.cloud_download_outlined,
                DefinitionSource.picked => Icons.insert_drive_file_outlined,
                DefinitionSource.cached => Icons.description_outlined,
              },
        color: problem != null ? StatusPalette.critical : null,
      ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(_describe(entry)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inUse) const _InUse(),
          PopupMenuButton<_EntryAction>(
            tooltip: 'Definition',
            onSelected: (action) => switch (action) {
              _EntryAction.save => onSave?.call(),
              _EntryAction.remove => onRemove?.call(),
            },
            itemBuilder: (_) => [
              if (onSave != null)
                const PopupMenuItem(
                  value: _EntryAction.save,
                  child: Text('Save a copy'),
                ),
              if (onRemove != null)
                PopupMenuItem(
                  value: _EntryAction.remove,
                  child: Text(
                    'Remove',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _describe(DefinitionEntry entry) {
    if (entry.problem case final problem?) return problem;
    final origin = switch (entry.source) {
      DefinitionSource.bundled => 'Ships with FoxTune',
      DefinitionSource.downloaded =>
        'Downloaded from ${entry.url?.host ?? 'the firmware project'}',
      DefinitionSource.picked =>
        entry.fileName == null
            ? 'Added from a file'
            : 'Added from ${entry.fileName}',
      DefinitionSource.cached => 'Kept from an earlier connection',
    };
    return [
      origin,
      if (entry.added case final added?)
        '${added.year}-${_two(added.month)}-${_two(added.day)}',
      if (entry.sizeBytes case final bytes?) _size(bytes),
    ].join(' · ');
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(0)} kB';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Marks the definition the connected ECU is being read through.
class _InUse extends StatelessWidget {
  const _InUse();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          'In use',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
