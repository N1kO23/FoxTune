import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart' show EcuFamily;
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/gauge_status.dart';
import '../tune/burn_actions.dart';
import '../tune/table_grid.dart';
import '../tune/tune_controller.dart';
import 'autotune_controller.dart';
import 'autotune_widgets.dart';
import 'log_replay_screen.dart';

/// VE autotuning.
///
/// Compares what the engine actually ran against the target table and moves
/// the VE cells that are wrong. Corrections land in the loaded tune as they
/// are earned; **nothing reaches the ECU until Burn**, which is the same gate
/// every other edit passes through.
class AutotuneScreen extends ConsumerWidget {
  const AutotuneScreen({super.key, required this.connection});

  final EcuConnected connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tuneAsync = ref.watch(tuneProvider);
    final session = ref.watch(autotuneProvider);

    return tuneAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => _Message(text: '$error'),
      data: (tune) {
        if (tune == null) return const _Message(text: 'No tune loaded.');
        // Another firmware's definition may describe autotuning too, but its
        // filters, channels and sensor settings have only been checked for
        // Speeduino and rusEFI. Offering it unchecked would mean correcting a
        // fuel table on trust.
        if (connection.identification.family == EcuFamily.other) {
          return const _Message(
            text:
                'Autotune is not yet available for this ECU. It has been '
                'built and checked against Speeduino and rusEFI.',
          );
        }
        if (connection.definition?.veAnalyze == null) {
          return const _Message(
            text: 'This definition does not describe VE autotuning.',
          );
        }

        return Column(
          children: [
            _Toolbar(tune: tune, session: session),
            const Divider(height: 1),
            _StatusStrip(session: session, canSend: _canSend(tune)),
            if (session.blockedReason case final reason?)
              _Blocked(reason: reason),
            if (session.sendProblem case final problem?)
              _Blocked(reason: problem),
            const Divider(height: 1),
            Expanded(
              child: _Body(tune: tune, session: session),
            ),
          ],
        );
      },
    );
  }
}

/// Whether corrections to [tune]'s VE table can go to the ECU's RAM as they
/// are made: whether the definition declares a write for its page.
bool _canSend(TuneState tune) {
  final definition = tune.definition;
  final page = definition.tableNamed(definition.veAnalyze!.table)?.page;
  return page != null && TuneController.writesPage(definition, page);
}

/// Autotuning for a file opened with no ECU: replaying a log into it.
///
/// Live autotuning needs an engine running on the tune; a log of one that
/// already ran is the next best thing, and the only one without an ECU.
class OfflineAutotunePane extends ConsumerWidget {
  const OfflineAutotunePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tune = ref.watch(tuneProvider).value;
    if (tune == null) return const _Message(text: 'No tune loaded.');
    // As live: checked for these two firmwares only.
    final signature = tune.definition.identity.signature ?? '';
    if (EcuFamily.of(signature) == EcuFamily.other) {
      return const _Message(
        text:
            'Autotune is not yet available for this firmware. It has been '
            'built and checked against Speeduino and rusEFI.',
      );
    }
    if (tune.definition.veAnalyze == null) {
      return const _Message(
        text: 'This definition does not describe VE autotuning.',
      );
    }

    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Live autotuning needs a running engine. With no ECU, a log '
                'of one can correct this tune instead.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => LogReplayScreen.open(context),
                icon: const Icon(Icons.replay),
                label: const Text('Replay a log'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.tune, required this.session});

  final TuneState tune;
  final AutotuneSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final permission = ref.watch(writePermissionProvider);
    final writeMode = ref.watch(writeModeProvider);
    final controller = ref.read(autotuneProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: writeMode,
                onChanged: (v) => ref.read(writeModeProvider.notifier).set(v),
              ),
              const SizedBox(width: 4),
              Text('Write mode', style: theme.textTheme.labelLarge),
            ],
          ),
          if (_canSend(tune))
            Tooltip(
              message:
                  'Write each correction to the ECU\'s RAM as it is made, so '
                  'the engine runs it straight away and tuning carries on. '
                  'Nothing is burned: burn to keep them, or they are gone '
                  'when the ECU is switched off.',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: session.sendToEcu,
                    onChanged: permission.allowed || session.sendToEcu
                        ? controller.setSendToEcu
                        : null,
                  ),
                  const SizedBox(width: 4),
                  Text('Send to ECU', style: theme.textTheme.labelLarge),
                ],
              ),
            ),
          FilledButton.icon(
            onPressed: session.armed ? controller.disarm : controller.arm,
            icon: Icon(session.armed ? Icons.stop : Icons.play_arrow),
            label: Text(session.armed ? 'Stop' : 'Start autotune'),
          ),
          // A replay reads the same table a live session is writing; one at
          // a time.
          TextButton.icon(
            onPressed: session.armed
                ? null
                : () => LogReplayScreen.open(context),
            icon: const Icon(Icons.replay),
            label: const Text('Replay log'),
          ),
          TextButton.icon(
            onPressed: session.tuner == null ? null : controller.resetSession,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset session'),
          ),
          TextButton.icon(
            onPressed: () => _editSettings(context, ref, session.settings),
            icon: const Icon(Icons.tune),
            label: const Text('Limits'),
          ),
          if (tune.isDirty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_note, size: 16, color: StatusPalette.warning),
                const SizedBox(width: 4),
                Text(
                  '${tune.dirtyPages.length} page(s) changed',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: StatusPalette.warning,
                  ),
                ),
              ],
            ),
          FilledButton.icon(
            onPressed: permission.allowed && tune.isDirty
                ? () => BurnActions.confirmAndBurn(context, ref, tune)
                : null,
            icon: const Icon(Icons.save),
            label: const Text('Burn to ECU'),
          ),
        ],
      ),
    );
  }

  Future<void> _editSettings(
    BuildContext context,
    WidgetRef ref,
    AutotuneSettings current,
  ) async {
    final updated = await AutotuneLimitsDialog.show(context, current);
    if (updated != null) {
      ref.read(autotuneProvider.notifier).updateSettings(updated);
    }
  }
}

/// Whether data is being collected and, when it is not, what is stopping it.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.session, required this.canSend});

  final AutotuneSession session;

  /// Whether sending to the ECU is on offer, for saying how to get a waiting
  /// cell going again.
  final bool canSend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final last = session.last;

    final collecting = session.armed && (last?.accepted ?? false);
    final status = !session.armed
        ? 'Idle'
        : last == null
        ? 'Waiting for data'
        : last.description;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                collecting ? Icons.circle : Icons.circle_outlined,
                size: 10,
                color: collecting ? StatusPalette.good : scheme.outline,
              ),
              const SizedBox(width: 6),
              Flexible(child: Text(status, style: theme.textTheme.labelLarge)),
            ],
          ),
          // The engine is still running what the table held before the
          // correction, so that cell has nothing more to say until it runs
          // the new one.
          if (session.armed &&
              !session.sendToEcu &&
              last?.rejectedBy?.id == VeAutotuner.runningVeFilter.id)
            Text(
              canSend
                  ? 'Burn, or switch on Send to ECU, to go on tuning here.'
                  : 'Burn to go on tuning here.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: StatusPalette.warning,
              ),
            ),
          AutotuneStat(label: 'Used', value: '${session.accepted}'),
          AutotuneStat(label: 'Skipped', value: '${session.rejected}'),
          AutotuneStat(label: 'Cells with data', value: '${session.covered}'),
          AutotuneStat(label: 'Cells changed', value: '${session.moved}'),
        ],
      ),
    );
  }
}

class _Blocked extends StatelessWidget {
  const _Blocked({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: StatusPalette.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: StatusPalette.warning,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(reason, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// The VE table, shaded by how much data each cell holds.
class _Body extends ConsumerStatefulWidget {
  const _Body({required this.tune, required this.session});

  final TuneState tune;
  final AutotuneSession session;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  CellSelection _selection = const CellSelection.single(0, 0);
  bool _showCoverage = true;

  @override
  Widget build(BuildContext context) {
    final definition = widget.tune.definition;
    final table = definition.tableNamed(definition.veAnalyze!.table);
    if (table == null) {
      return const _Message(text: 'The VE table is missing from this tune.');
    }

    final view = TableView.of(
      widget.tune,
      table,
      resolver: ref.watch(tuneResolverProvider),
    );
    if (view == null) {
      return const _Message(text: 'The VE table could not be resolved.');
    }

    final live = watchWhileVisible(ref, context, realtimeProvider).value;
    double? channel(String? name) => name == null ? null : live?[name];
    final x = channel(table.xBins.channel);
    final y = channel(table.yBins.channel);

    final baseline = ref.watch(tuneBaselineProvider);
    final before = baseline == null ? null : TableView.of(baseline, table);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _showCoverage
                      ? 'Shading shows where data has been gathered.'
                      : 'Shading shows the table values.',
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
              view: view,
              selection: _selection,
              // Autotuning writes the cells; hand-editing them here as well
              // would race it for the same values.
              editable: false,
              cursor: x == null || y == null ? null : view.cellFor(x, y),
              preciseCursor: x == null || y == null
                  ? null
                  : view.preciseCellFor(x, y),
              changes: before == null ? const {} : view.changesAgainst(before),
              coverage: _showCoverage ? _coverage() : null,
              onSelectionChanged: (s) => setState(() => _selection = s),
              onEdit: (_) {},
            ),
          ),
        ),
      ],
    );
  }

  /// Per-cell data volume, scaled against the best-covered cell.
  ///
  /// Relative rather than absolute: what a tuner wants to see is which parts
  /// of the table still need driving, and that is a comparison between cells.
  Map<({int row, int column}), double> _coverage() {
    final cells = widget.session.tuner?.cells;
    if (cells == null || cells.isEmpty) return const {};

    var most = 0;
    for (final cell in cells.values) {
      if (cell.samples > most) most = cell.samples;
    }
    if (most == 0) return const {};

    return {
      for (final entry in cells.entries) entry.key: entry.value.samples / most,
    };
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
