import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import 'definition_library.dart';

/// A definition to download: a Speeduino version, as speeduino.com lists it,
/// or the signature of a rusEFI build.
typedef DefinitionDownload = ({EcuFamily family, String version});

/// Asks which definition to download: the firmware first, then which one.
///
/// Speeduino publishes a list of its releases, so that is offered to choose
/// from. rusEFI publishes a definition for every board and every build - over
/// 400 branches, and dozens of boards on a single day - and no list of them,
/// so for rusEFI it is the signature the ECU reports.
class DownloadDefinitionDialog extends ConsumerStatefulWidget {
  const DownloadDefinitionDialog({super.key});

  /// Asks, over [context]; `null` if the user cancelled.
  static Future<DefinitionDownload?> ask(BuildContext context) =>
      showDialog<DefinitionDownload>(
        context: context,
        builder: (_) => const DownloadDefinitionDialog(),
      );

  @override
  ConsumerState<DownloadDefinitionDialog> createState() =>
      _DownloadDefinitionDialogState();
}

class _DownloadDefinitionDialogState
    extends ConsumerState<DownloadDefinitionDialog> {
  /// The connected ECU, where one is - it is most likely what the definition
  /// is wanted for.
  late final EcuIdentification? _connected = switch (ref.read(
    connectionProvider,
  )) {
    EcuConnected(:final identification) => identification,
    _ => null,
  };

  late EcuFamily _family = _connected?.family == EcuFamily.rusefi
      ? EcuFamily.rusefi
      : EcuFamily.speeduino;

  late final _signature = TextEditingController(
    text: _connected?.family == EcuFamily.rusefi ? _connected!.signature : '',
  );

  /// speeduino.com's list, fetched the first time Speeduino is shown.
  Future<List<String>>? _versions;

  Future<List<String>> get _speeduinoVersions =>
      _versions ??= ref.read(definitionLibraryProvider).speeduinoVersions();

  @override
  void dispose() {
    _signature.dispose();
    super.dispose();
  }

  /// What is wrong with the signature typed in, if anything; empty while
  /// there is none to judge.
  String? get _signatureProblem {
    final signature = _signature.text.trim();
    if (signature.isEmpty) return '';
    return rusEfiDefinitionUrl(signature) == null
        ? 'Not a signature rusEFI publishes a definition under.'
        : null;
  }

  void _choose(String version) =>
      Navigator.of(context).pop((family: _family, version: version));

  @override
  Widget build(BuildContext context) {
    final rusEfi = _family == EcuFamily.rusefi;
    return AlertDialog(
      title: const Text('Download a definition'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<EcuFamily>(
              segments: const [
                ButtonSegment(
                  value: EcuFamily.speeduino,
                  label: Text('Speeduino'),
                ),
                ButtonSegment(value: EcuFamily.rusefi, label: Text('rusEFI')),
              ],
              selected: {_family},
              showSelectedIcon: false,
              onSelectionChanged: (family) =>
                  setState(() => _family = family.single),
            ),
            const SizedBox(height: 16),
            if (rusEfi) _rusEfiBuild(context) else _speeduinoRelease(context),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (rusEfi)
          FilledButton(
            onPressed: _signatureProblem == null
                ? () => _choose(_signature.text.trim())
                : null,
            child: const Text('Download'),
          ),
      ],
    );
  }

  Widget _speeduinoRelease(BuildContext context) {
    final theme = Theme.of(context);
    final have = {
      for (final entry
          in ref.watch(definitionEntriesProvider).value ??
              const <DefinitionEntry>[])
        ?entry.signature,
    };

    return FutureBuilder<List<String>>(
      future: _speeduinoVersions,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${snapshot.error}', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _versions = null),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          );
        }
        final versions = snapshot.data;
        if (versions == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (versions.isEmpty) {
          return const Text('speeduino.com lists no versions.');
        }
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final version in versions)
                ListTile(
                  title: Text(version),
                  subtitle: Text(_describe(version, have)),
                  onTap: () => _choose(version),
                ),
            ],
          ),
        );
      },
    );
  }

  /// What choosing [version] gets: the signature an ECU on it reports, and
  /// whether FoxTune has that already.
  static String _describe(String version, Set<String> have) {
    if (version == 'master') {
      return 'The development build as it stands - its signature moves on '
          'with it';
    }
    final signature = 'speeduino ${version.substring(0, 6)}';
    return have.contains(signature)
        ? 'For $signature - on this device already'
        : 'For $signature';
  }

  Widget _rusEfiBuild(BuildContext context) {
    final problem = _signatureProblem;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'rusEFI publishes a definition for every board and every build, so '
          'there is no list to choose from. Enter the signature your ECU '
          'reports, and FoxTune downloads the definition for that build.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _signature,
          autofocus: _signature.text.isEmpty,
          decoration: InputDecoration(
            labelText: 'Signature',
            hintText: 'rusEFI master.2026.09.21.uaefi.419928595',
            errorText: problem == null || problem.isEmpty ? null : problem,
            errorMaxLines: 2,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (signature) {
            if (_signatureProblem == null) _choose(signature.trim());
          },
        ),
      ],
    );
  }
}
