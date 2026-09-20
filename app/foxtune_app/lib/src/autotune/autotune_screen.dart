import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/gauge_status.dart';
import '../tune/burn_actions.dart';
import '../tune/table_grid.dart';
import '../tune/tune_controller.dart';
import 'autotune_controller.dart';

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
        if (connection.definition?.veAnalyze == null) {
          return const _Message(
            text: 'This definition does not describe VE autotuning.',
          );
        }

        return Column(
          children: [
            _Toolbar(tune: tune, session: session),
            const Divider(height: 1),
            _StatusStrip(session: session),
            if (session.blockedReason case final reason?)
              _Blocked(reason: reason),
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
          FilledButton.icon(
            onPressed: session.armed ? controller.disarm : controller.arm,
            icon: Icon(session.armed ? Icons.stop : Icons.play_arrow),
            label: Text(session.armed ? 'Stop' : 'Start autotune'),
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
    final updated = await showDialog<AutotuneSettings>(
      context: context,
      builder: (_) => _LimitsDialog(settings: current),
    );
    if (updated != null) {
      ref.read(autotuneProvider.notifier).updateSettings(updated);
    }
  }
}

/// Whether data is being collected and, when it is not, what is stopping it.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.session});

  final AutotuneSession session;

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
              Text(status, style: theme.textTheme.labelLarge),
            ],
          ),
          _Stat(label: 'Used', value: '${session.accepted}'),
          _Stat(label: 'Skipped', value: '${session.rejected}'),
          _Stat(label: 'Cells with data', value: '${session.covered}'),
          _Stat(label: 'Cells changed', value: '${session.moved}'),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: theme.textTheme.labelSmall),
        Text(value, style: theme.textTheme.labelLarge),
      ],
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

    final live = ref.watch(realtimeProvider).valueOrNull;
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

/// The limits a session runs under.
class _LimitsDialog extends StatefulWidget {
  const _LimitsDialog({required this.settings});

  final AutotuneSettings settings;

  @override
  State<_LimitsDialog> createState() => _LimitsDialogState();
}

class _LimitsDialogState extends State<_LimitsDialog> {
  late final _step = TextEditingController(
    text: '${widget.settings.maxStepPercent}',
  );
  late final _total = TextEditingController(
    text: '${widget.settings.maxTotalPercent}',
  );
  late final _weight = TextEditingController(
    text: '${widget.settings.minWeight}',
  );
  late final _settling = TextEditingController(
    text: '${widget.settings.settlingTime.inMilliseconds}',
  );
  late final _lambdaMin = TextEditingController(
    text: '${widget.settings.lambdaMin}',
  );
  late final _lambdaMax = TextEditingController(
    text: '${widget.settings.lambdaMax}',
  );
  late final _custom = TextEditingController(
    text: widget.settings.customFilter,
  );

  @override
  void dispose() {
    for (final controller in [
      _step,
      _total,
      _weight,
      _settling,
      _lambdaMin,
      _lambdaMax,
      _custom,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Autotune limits'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _field(_step, 'Most one correction may move a cell', '%'),
            _field(_total, 'Most this session may move a cell', '%'),
            _field(_weight, 'Samples a cell needs before it moves', ''),
            _field(_settling, 'Settling time before a reading counts', 'ms'),
            _field(_lambdaMin, 'Lowest believable lambda', ''),
            _field(_lambdaMax, 'Highest believable lambda', ''),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: TextField(
                controller: _custom,
                decoration: const InputDecoration(
                  labelText: 'Extra filter expression',
                  helperText: 'Samples are skipped while this holds',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_build()),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _field(TextEditingController controller, String label, String units) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            suffixText: units.isEmpty ? null : units,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  AutotuneSettings _build() {
    double number(TextEditingController controller, double fallback) =>
        double.tryParse(controller.text.trim()) ?? fallback;

    final base = widget.settings;
    return base.copyWith(
      // Clamped rather than trusted: these are the limits on how far the fuel
      // table may move, so a mistyped entry must not widen them without bound.
      maxStepPercent: number(_step, base.maxStepPercent).clamp(0.1, 25),
      maxTotalPercent: number(_total, base.maxTotalPercent).clamp(1, 100),
      minWeight: number(_weight, base.minWeight).clamp(1, 1000),
      settlingTime: Duration(
        milliseconds: number(_settling, 500).clamp(0, 10000).round(),
      ),
      lambdaMin: number(_lambdaMin, base.lambdaMin).clamp(0.1, 1.0),
      lambdaMax: number(_lambdaMax, base.lambdaMax).clamp(1.0, 3.0),
      customFilter: _custom.text.trim(),
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
