import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../app_settings/app_settings.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_editor.dart' show confirm;
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import '../window/window_app_bar.dart';
import 'choose_definition.dart';
import 'definition_library.dart';
import 'download_definition.dart';

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

/// What the screen is busy with, if anything.
enum _Work { adding, downloading }

class _DefinitionsScreenState extends ConsumerState<DefinitionsScreen> {
  _Work? _working;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = ref.watch(definitionEntriesProvider);
    final connection = ref.watch(connectionProvider);
    final inUse = connection is EcuConnected
        ? connection.definition?.identity.signature
        : null;
    final downloads = ref.watch(
      appSettingsProvider.select((s) => s.downloadDefinitionsFor),
    );

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
                        'kept on this device, then - where allowed below - '
                        'downloads it.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const _Heading('Download automatically'),
                    for (final (family, subtitle) in const [
                      (
                        EcuFamily.speeduino,
                        'From speeduino.com, for the release a connected '
                            'Speeduino reports',
                      ),
                      (
                        EcuFamily.rusefi,
                        'From rusefi.com, for the exact build a connected '
                            'rusEFI reports',
                      ),
                    ])
                      SwitchListTile(
                        title: Text(
                          family == EcuFamily.rusefi ? 'rusEFI' : 'Speeduino',
                        ),
                        subtitle: Text(subtitle),
                        value: downloads.contains(family),
                        onChanged: (on) => ref
                            .read(appSettingsProvider.notifier)
                            .update((s) => s.withDownloadsFor(family, on: on)),
                      ),
                    const _Heading('Built in'),
                    for (final entry in list)
                      if (entry.isBuiltIn)
                        _EntryTile(
                          entry: entry,
                          inUse: entry.signature == inUse,
                          onSave: () => _save(entry),
                        ),
                    const _Heading('On this device'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _working == null ? _add : null,
                            icon: _working == _Work.adding
                                ? const _Spinner()
                                : const Icon(Icons.add),
                            label: const Text('Add from file'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _working == null ? _download : null,
                            icon: _working == _Work.downloading
                                ? const _Spinner()
                                : const Icon(Icons.cloud_download_outlined),
                            label: const Text('Download'),
                          ),
                        ],
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
    final library = ref.read(definitionLibraryProvider);
    await _keep(
      ({required replace}) => library.add(
        decodeDefinition(picked.bytes),
        fileName: picked.name,
        replace: replace,
      ),
      messenger,
      work: _Work.adding,
      source: picked.name,
      replacement: picked.name,
      done: 'Added',
    );
  }

  Future<void> _download() async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await DownloadDefinitionDialog.ask(context);
    if (choice == null || !mounted) return;
    final library = ref.read(definitionLibraryProvider);
    final rusEfi = choice.family == EcuFamily.rusefi;
    await _keep(
      ({required replace}) => rusEfi
          ? library.downloadRusEfi(choice.version, replace: replace)
          : library.downloadSpeeduino(choice.version, replace: replace),
      messenger,
      work: _Work.downloading,
      source: choice.version,
      replacement: 'the one from ${rusEfi ? 'rusefi.com' : 'speeduino.com'}',
      done: 'Downloaded',
    );
  }

  /// Runs [work] with its button showing it is busy.
  ///
  /// Reading a definition holds up the screen while it runs - a rusEFI one is
  /// some 13,000 lines - so the button is drawn busy before it starts, to say
  /// why.
  Future<T> _busy<T>(_Work work, Future<T> Function() run) async {
    setState(() => _working = work);
    await WidgetsBinding.instance.endOfFrame;
    try {
      return await run();
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  /// Keeps the definition [keep] reads or downloads, from [source], asking
  /// first before it replaces one kept already with [replacement].
  Future<void> _keep(
    Future<DefinitionEntry> Function({required bool replace}) keep,
    ScaffoldMessengerState messenger, {
    required _Work work,
    required String source,
    required String replacement,
    required String done,
    bool replace = false,
  }) async {
    final DefinitionEntry entry;
    try {
      entry = await _busy(work, () => keep(replace: replace));
    } on DefinitionExistsException catch (error) {
      if (!mounted) return;
      final proceed = await confirm(
        context,
        title: 'Replace the kept definition?',
        message:
            'A definition for "${error.signature}" is kept already. '
            'Replace it with $replacement?',
        action: 'Replace',
      );
      if (proceed) {
        await _keep(
          keep,
          messenger,
          work: work,
          source: source,
          replacement: replacement,
          done: done,
          replace: true,
        );
      }
      return;
    } on DefinitionRefusedException catch (error) {
      _complain(messenger, '$source: ${error.message}');
      return;
    } on Object catch (error) {
      _complain(
        messenger,
        '$source is not a definition FoxTune can read: $error',
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
      _tell(messenger, '$done ${entry.name}, and it is now in use.');
    } else {
      _tell(messenger, '$done ${entry.name}.');
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
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
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

/// Small enough to stand in for a button's icon.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
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
