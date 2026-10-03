import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import '../logging/log_files.dart';
import '../tune/burn_actions.dart';
import '../tune/msq_actions.dart';
import '../tune/offline_tune.dart';
import '../tune/table_grid.dart';
import '../tune/tune_controller.dart';
import '../window/window_app_bar.dart';
import 'autotune_controller.dart';
import 'autotune_widgets.dart';

/// Works out what replaying [log] would do to [tune].
typedef LogReplayRunner = Future<LogReplayResult> Function(
  TuneState tune,
  String log,
  AutotuneSettings settings,
);

/// Runs a replay's analysis away from the UI.
///
/// A half-hour log takes about a second on a desktop, and several on a phone:
/// long enough to freeze the screen if run on it.
final logReplayRunnerProvider = Provider<LogReplayRunner>(
  (ref) => _replayInBackground,
);

Future<LogReplayResult> _replayInBackground(
  TuneState tune,
  String log,
  AutotuneSettings settings,
) => Isolate.run(
  () =>
      LogReplay.analyse(tune: tune, log: MslLog.parse(log), settings: settings),
);

/// Replays a recorded log into the VE table.
///
/// Opened from the Autotune tab, against the loaded tune - the connected
/// ECU's, or a file being edited with no ECU at all. Either way the log is
/// worked through on a copy and what it would change is shown first: nothing
/// is corrected until Apply, which is then an ordinary edit - burned or not as
/// the tuner decides, or for a file, saved or not.
class LogReplayScreen extends ConsumerStatefulWidget {
  const LogReplayScreen({super.key});

  /// Opens a replay into the loaded tune.
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const LogReplayScreen()));

  @override
  ConsumerState<LogReplayScreen> createState() => _LogReplayScreenState();
}

class _LogReplayScreenState extends ConsumerState<LogReplayScreen> {
  late AutotuneSettings _settings = ref.read(autotuneProvider).settings;

  String? _logName;
  String? _logText;

  /// The tune as analysed, for showing what the replay changes.
  TuneState? _before;
  LogReplayResult? _result;

  /// Why the log could not be read at all.
  String? _problem;

  bool _busy = false;
  bool _applied = false;

  /// Which analysis is the latest, so a slow one cannot land over it.
  int _run = 0;

  CellSelection _selection = const CellSelection.single(0, 0);
  bool _showCoverage = false;

  TuneState? get _tune => ref.read(tuneProvider).value;

  @override
  Widget build(BuildContext context) {
    final tune = ref.watch(tuneProvider).value;
    final offline = ref.watch(editingOfflineProvider);

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Replay a log')),
      body: SafeArea(
        child: tune == null
            ? const _Message(
                text:
                    'The tune is no longer loaded. Connect, or open the '
                    'file again, to replay a log into it.',
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _toolbar(context, tune, offline: offline),
                  const Divider(height: 1),
                  _summary(context),
                  if (_problem ?? _result?.blockedReason case final reason?)
                    _Notice(text: reason, warning: true),
                  if (_applied)
                    _Notice(
                      text: offline
                          ? 'Applied to the tune. Save it to keep it.'
                          : 'Applied to the tune. Nothing reaches the ECU '
                                'until you burn.',
                    ),
                  const Divider(height: 1),
                  Expanded(child: _body(context, tune)),
                ],
              ),
      ),
    );
  }

  Widget _toolbar(
    BuildContext context,
    TuneState tune, {
    required bool offline,
  }) {
    final theme = Theme.of(context);
    final result = _result;
    final permission = ref.watch(editPermissionProvider);
    final canApply =
        !_busy &&
        !_applied &&
        result != null &&
        result.changes.isNotEmpty &&
        permission.allowed;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (offline)
            if (ref.watch(offlineTuneProvider) case final open?)
              Text('Tune: ${open.fileName}', style: theme.textTheme.labelLarge),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _chooseLog(context),
            icon: const Icon(Icons.folder_open),
            label: Text(_logName == null ? 'Choose a log' : 'Another log'),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => _editLimits(context),
            icon: const Icon(Icons.tune),
            label: const Text('Limits'),
          ),
          if (!offline)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: ref.watch(writeModeProvider),
                  onChanged: (v) => ref.read(writeModeProvider.notifier).set(v),
                ),
                const SizedBox(width: 4),
                Text('Write mode', style: theme.textTheme.labelLarge),
              ],
            ),
          FilledButton.icon(
            onPressed: canApply ? () => _apply(context) : null,
            icon: const Icon(Icons.check),
            label: const Text('Apply'),
          ),
          if (offline)
            FilledButton.icon(
              onPressed: () => MsqActions.save(context, ref, tune),
              icon: const Icon(Icons.save),
              label: const Text('Save .msq'),
            )
          else
            FilledButton.icon(
              onPressed: permission.allowed && tune.isDirty
                  ? () => BurnActions.confirmAndBurn(context, ref, tune)
                  : null,
              icon: const Icon(Icons.save),
              label: const Text('Burn to ECU'),
            ),
          if (!permission.allowed &&
              result != null &&
              result.changes.isNotEmpty)
            Text(
              permission.reason ?? 'Writing is not permitted.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: StatusPalette.warning,
              ),
            ),
        ],
      ),
    );
  }

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final result = _result;
    final skipped = result?.skipped.values.fold(0, (a, b) => a + b) ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            _busy
                ? 'Reading ${_logName ?? 'the log'}...'
                : _logName == null
                ? 'No log chosen'
                : 'Log: $_logName',
            style: theme.textTheme.labelLarge,
          ),
          if (result != null && !result.blocked) ...[
            AutotuneStat(label: 'Rows', value: '${result.rows}'),
            AutotuneStat(label: 'Used', value: '${result.used}'),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AutotuneStat(label: 'Skipped', value: '$skipped'),
                if (skipped > 0)
                  TextButton(
                    onPressed: () => _showSkipped(context, result),
                    child: const Text('Why?'),
                  ),
              ],
            ),
            AutotuneStat(
              label: _applied ? 'Cells changed' : 'Cells to change',
              value: '${result.changes.length}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(BuildContext context, TuneState tune) {
    final result = _result;
    if (_busy) return const Center(child: CircularProgressIndicator());
    if (_logName == null) {
      return const _Message(
        text:
            'Choose a recorded log to see what it would change in the VE '
            'table. Nothing changes until you apply it.',
      );
    }
    final preview = result?.preview;
    final before = _before;
    if (result == null || preview == null || before == null) {
      return const SizedBox.shrink();
    }

    final definition = tune.definition;
    final table = definition.tableNamed(definition.veAnalyze!.table);
    final shown = table == null ? null : TableView.of(preview, table);
    final was = table == null ? null : TableView.of(before, table);
    if (shown == null || was == null) {
      return const _Message(text: 'The VE table could not be resolved.');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  result.changes.isEmpty
                      ? 'Nothing to change: no cell gathered enough readings '
                            'that were off target.'
                      : _showCoverage
                      ? 'Shading shows where the log had data.'
                      : 'The table as the log would leave it, changed cells '
                            'marked.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() => _showCoverage = !_showCoverage),
                icon: const Icon(Icons.gradient, size: 18),
                label: Text(_showCoverage ? 'Show values' : 'Show coverage'),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: TableGrid(
              view: shown,
              selection: _selection,
              editable: false,
              changes: shown.changesAgainst(was),
              coverage: _showCoverage ? _coverage(result) : null,
              onSelectionChanged: (s) => setState(() => _selection = s),
              onEdit: (_) {},
            ),
          ),
        ),
      ],
    );
  }

  /// Per-cell data volume, scaled against the best-covered cell.
  static Map<({int row, int column}), double> _coverage(
    LogReplayResult result,
  ) {
    var most = 0;
    for (final cell in result.coverage.values) {
      if (cell.samples > most) most = cell.samples;
    }
    if (most == 0) return const {};
    return {
      for (final entry in result.coverage.entries)
        entry.key: entry.value.samples / most,
    };
  }

  Future<void> _chooseLog(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<_LogChoice>(
      context: context,
      showDragHandle: true,
      builder: (_) => const _LogPicker(),
    );
    if (choice == null || !mounted) return;

    PickedFile? picked;
    try {
      picked = switch (choice) {
        _RecordedLog(:final file) => PickedFile(
          name: file.path.split(RegExp(r'[/\\]')).last,
          bytes: await file.readAsBytes(),
        ),
        _LogFromFile() =>
          await ref
              .read(fileSavingProvider)
              .pickFile(
                dialogTitle: 'Log to replay',
                extensions: const ['msl'],
              ),
      };
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text(
            error is WrongFileTypeException
                ? error.message
                : 'Could not read the log: $error',
          ),
        ),
      );
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _logName = picked!.name;
      _logText = picked.text;
    });
    await _analyse();
  }

  Future<void> _analyse() async {
    final tune = _tune;
    final text = _logText;
    if (tune == null || text == null) return;

    final run = ++_run;
    final before = tune.copy();
    setState(() {
      _busy = true;
      _result = null;
      _problem = null;
      _applied = false;
    });

    LogReplayResult? result;
    String? problem;
    try {
      result = await ref.read(logReplayRunnerProvider)(before, text, _settings);
    } on FormatException catch (error) {
      problem = '$_logName: ${error.message}';
    } on Object catch (error) {
      problem = 'Could not replay $_logName: $error';
    }
    if (!mounted || run != _run) return;
    setState(() {
      _busy = false;
      _before = before;
      _result = result;
      _problem = problem;
    });
  }

  Future<void> _editLimits(BuildContext context) async {
    final updated = await AutotuneLimitsDialog.show(context, _settings);
    if (updated == null || !mounted) return;
    setState(() => _settings = updated);
    await _analyse();
  }

  void _apply(BuildContext context) {
    final tune = _tune;
    final result = _result;
    if (tune == null || result == null) return;

    if (!LogReplay.applyTo(tune, result)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The VE table changed after the log was read, so it has been '
            'read again against the table as it is now.',
          ),
        ),
      );
      _analyse();
      return;
    }
    ref.read(tuneProvider.notifier).notifyEdited();
    setState(() => _applied = true);
  }

  void _showSkipped(BuildContext context, LogReplayResult result) {
    final reasons = result.skipped.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Rows skipped',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final reason in reasons)
              ListTile(
                dense: true,
                title: Text(reason.key),
                trailing: Text('${reason.value}'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Where a log to replay comes from.
sealed class _LogChoice {
  const _LogChoice();
}

class _RecordedLog extends _LogChoice {
  const _RecordedLog(this.file);
  final File file;
}

class _LogFromFile extends _LogChoice {
  const _LogFromFile();
}

/// FoxTune's own recent logs, and a way to open any other.
class _LogPicker extends ConsumerWidget {
  const _LogPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(recentLogsProvider).value ?? const <File>[];

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Log to replay',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_open),
            title: const Text('Open a file...'),
            subtitle: const Text('A .msl log from FoxTune or TunerStudio'),
            onTap: () => Navigator.of(context).pop(const _LogFromFile()),
          ),
          for (final file in logs)
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(
                file.path.split(RegExp(r'[/\\]')).last,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(LogFiles.describe(file)),
              onTap: () => Navigator.of(context).pop(_RecordedLog(file)),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.warning = false});

  final String text;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = warning ? StatusPalette.warning : StatusPalette.good;
    return Container(
      width: double.infinity,
      color: colour.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warning ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 16,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
