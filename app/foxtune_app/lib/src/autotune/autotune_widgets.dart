import 'package:flutter/material.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// A labelled count in a status strip.
class AutotuneStat extends StatelessWidget {
  const AutotuneStat({super.key, required this.label, required this.value});

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

/// The limits a session runs under.
class AutotuneLimitsDialog extends StatefulWidget {
  const AutotuneLimitsDialog({super.key, required this.settings});

  final AutotuneSettings settings;

  /// Asks for new limits, starting from [current]; `null` if cancelled.
  static Future<AutotuneSettings?> show(
    BuildContext context,
    AutotuneSettings current,
  ) => showDialog<AutotuneSettings>(
    context: context,
    builder: (_) => AutotuneLimitsDialog(settings: current),
  );

  @override
  State<AutotuneLimitsDialog> createState() => _AutotuneLimitsDialogState();
}

class _AutotuneLimitsDialogState extends State<AutotuneLimitsDialog> {
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
