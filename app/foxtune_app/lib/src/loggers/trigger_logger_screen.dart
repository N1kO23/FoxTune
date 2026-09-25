import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'trigger_logger_controller.dart';

/// The ECU's tooth and composite loggers: what it sees of the trigger wheel.
///
/// A tooth log is the time from each tooth to the next, drawn as bars, so a
/// missing-tooth gap stands out as the tall one and a noisy input as a
/// ragged row. A composite log is every edge on the trigger inputs, drawn as
/// traces, which shows where the cam falls against the crank.
class TriggerLoggerScreen extends ConsumerWidget {
  const TriggerLoggerScreen({super.key, required this.connection});

  final EcuConnected connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final loggers = triggerLoggersOf(connection.definition);
    if (loggers.isEmpty) {
      return const _Message(
        text: 'This definition declares no tooth or composite loggers.',
      );
    }
    final state = ref.watch(triggerLoggerProvider);
    final controller = ref.read(triggerLoggerProvider.notifier);
    final selected = state.selected.clamp(0, loggers.length - 1);
    final latest = state.latest;

    final status = switch (state) {
      TriggerLoggerState(error: final error?) => Text(
        '$error',
        style: theme.textTheme.bodySmall?.copyWith(
          color: StatusPalette.critical,
        ),
      ),
      TriggerLoggerState(running: true, captures: 0) => Text(
        'Waiting for the ECU to fill a capture...',
        style: theme.textTheme.bodySmall,
      ),
      TriggerLoggerState(running: true, :final captures) => Text(
        'Capture $captures, read at ${_clock(latest!.captured)}',
        style: theme.textTheme.bodySmall,
      ),
      _ when latest != null => Text(
        'Stopped. Showing the capture read at ${_clock(latest.captured)}.',
        style: theme.textTheme.bodySmall,
      ),
      _ => const SizedBox.shrink(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // As wide as its longest name at most, and no wider than a
              // phone has room for.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: DropdownButton<int>(
                  value: selected,
                  isExpanded: true,
                  onChanged: state.running || state.busy
                      ? null
                      : (i) {
                          if (i != null) controller.select(i);
                        },
                  items: [
                    for (var i = 0; i < loggers.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          loggers[i].label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              if (state.running)
                FilledButton.icon(
                  onPressed: state.busy ? null : controller.stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                )
              else
                FilledButton.icon(
                  onPressed: state.busy ? null : controller.start,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              OutlinedButton.icon(
                onPressed: latest == null || latest.isEmpty
                    ? null
                    : () => _save(context, ref, latest),
                icon: const Icon(Icons.save_alt),
                label: const Text('Save CSV'),
              ),
              status,
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: switch (latest) {
              null => _Message(
                text: state.running
                    ? 'The ECU sends a capture once it has filled one, or '
                          'after a few seconds with whatever it has.'
                    : 'Start a logger with the engine cranking or running '
                          'to see what the ECU makes of the trigger wheel. '
                          'It runs until stopped, and stops when you leave '
                          'this tab.',
              ),
              TriggerLog(isEmpty: true) => const _Message(
                text:
                    'Nothing in this capture: no trigger edges reached the '
                    'ECU. Is the engine turning, and the trigger wired?',
              ),
              TriggerLog(logger: IniLogger(kind: IniLoggerKind.tooth)) =>
                ToothLogChart(toothTimes: latest.toothTimes),
              _ => CompositeLogChart(log: latest),
            },
          ),
        ),
      ],
    );
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    TriggerLog log,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final stamp = log.captured
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    try {
      final saved = await ref
          .read(fileSavingProvider)
          .saveText(
            dialogTitle: 'Save the capture',
            fileName: '${log.logger.id}-$stamp.csv',
            extension: 'csv',
            text: log.toCsv(),
          );
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $saved')));
      }
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: StatusPalette.critical,
          content: Text('Could not save the capture: $error'),
        ),
      );
    }
  }

  static String _clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}

/// Formats milliseconds for a label.
String _ms(double ms) => ms >= 100
    ? '${ms.toStringAsFixed(0)} ms'
    : ms >= 10
    ? '${ms.toStringAsFixed(1)} ms'
    : '${ms.toStringAsFixed(2)} ms';

/// The time from each tooth to the next, as bars.
///
/// A tooth markedly longer than is typical - over one and a half times - is
/// picked out: on a missing-tooth wheel that is the gap, which should come
/// round once a turn and nowhere else.
class ToothLogChart extends StatelessWidget {
  const ToothLogChart({super.key, required this.toothTimes});

  /// In milliseconds.
  final List<double> toothTimes;

  static const longRatio = 1.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sorted = [...toothTimes]..sort();
    final typical = sorted[sorted.length ~/ 2];
    final longest = sorted.last;
    final long = toothTimes.where((t) => t > typical * longRatio).length;
    final small = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('${toothTimes.length} teeth'),
            Text('Typical ${_ms(typical)}'),
            Text('Shortest ${_ms(sorted.first)}'),
            Text(
              'Longest ${_ms(longest)}'
              '${typical > 0 ? ' (${(longest / typical).toStringAsFixed(1)} x typical)' : ''}',
            ),
            Text(
              '$long long',
              style: TextStyle(color: long > 0 ? scheme.tertiary : null),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Semantics(
            label:
                'Tooth times: ${toothTimes.length} teeth, typically '
                '${_ms(typical)}, longest ${_ms(longest)}',
            child: CustomPaint(
              size: Size.infinite,
              painter: _ToothPainter(
                times: toothTimes,
                typical: typical,
                bar: scheme.primary,
                long: scheme.tertiary,
                grid: scheme.outlineVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Tooth 1', style: small),
            Text('Tooth ${toothTimes.length}', style: small),
          ],
        ),
      ],
    );
  }
}

class _ToothPainter extends CustomPainter {
  _ToothPainter({
    required this.times,
    required this.typical,
    required this.bar,
    required this.long,
    required this.grid,
  });

  final List<double> times;
  final double typical;
  final Color bar;
  final Color long;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    if (times.isEmpty) return;
    final top = times.reduce(math.max) * 1.08;
    if (top <= 0) return;
    final width = size.width / times.length;
    final gap = width > 4 ? 1.0 : 0.0;
    final normal = Paint()..color = bar;
    final picked = Paint()..color = long;

    for (var i = 0; i < times.length; i++) {
      final height = size.height * times[i] / top;
      canvas.drawRect(
        Rect.fromLTWH(
          i * width + gap / 2,
          size.height - height,
          math.max(width - gap, 0.5),
          height,
        ),
        times[i] > typical * ToothLogChart.longRatio ? picked : normal,
      );
    }

    // The typical tooth, as a rule across.
    final y = size.height * (1 - typical / top);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = grid
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ToothPainter old) =>
      !identical(old.times, times) ||
      old.bar != bar ||
      old.long != long ||
      old.grid != grid;
}

/// Every edge of a composite log, as one trace per input.
///
/// Only the inputs that change are drawn: a composite record has room for
/// more inputs than a given trigger uses.
class CompositeLogChart extends StatelessWidget {
  const CompositeLogChart({super.key, required this.log});

  final TriggerLog log;

  static const _laneHeight = 44.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lanes = log.changingFlags;
    final times = log.times ?? const <double>[];
    if (lanes.isEmpty || times.isEmpty) {
      return const _Message(text: 'No input changed during this capture.');
    }
    final total = times.last;
    final small = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${log.records.length} edges over ${_ms(total)}'),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: Semantics(
              label:
                  'Composite log: ${[for (final l in lanes) l.label].join(', ')}'
                  ' over ${_ms(total)}',
              child: SizedBox(
                height: lanes.length * _laneHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Column(
                        children: [
                          for (final lane in lanes)
                            SizedBox(
                              height: _laneHeight,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  lane.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: CustomPaint(
                        painter: _TracePainter(
                          log: log,
                          lanes: lanes,
                          times: times,
                          trace: scheme.primary,
                          grid: scheme.outlineVariant,
                          laneHeight: _laneHeight,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 96),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('0 ms', style: small),
              Text(_ms(total), style: small),
            ],
          ),
        ),
      ],
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter({
    required this.log,
    required this.lanes,
    required this.times,
    required this.trace,
    required this.grid,
    required this.laneHeight,
  });

  final TriggerLog log;
  final List<IniLoggerField> lanes;
  final List<double> times;
  final Color trace;
  final Color grid;
  final double laneHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final total = times.last;
    double x(double t) => total <= 0 ? 0 : size.width * t / total;
    final line = Paint()
      ..color = trace
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rule = Paint()
      ..color = grid
      ..strokeWidth = 1;

    for (var lane = 0; lane < lanes.length; lane++) {
      final top = lane * laneHeight;
      final high = top + 8;
      final low = top + laneHeight - 10;
      canvas.drawLine(
        Offset(0, top + laneHeight - 1),
        Offset(size.width, top + laneHeight - 1),
        rule,
      );

      final name = lanes[lane].name;
      final records = log.records;
      var level = records.first.isSet(name);
      final path = Path()..moveTo(0, level ? high : low);
      for (var i = 1; i < records.length; i++) {
        final now = records[i].isSet(name);
        if (now == level) continue;
        final at = x(times[i]);
        path
          ..lineTo(at, level ? high : low)
          ..lineTo(at, now ? high : low);
        level = now;
      }
      path.lineTo(size.width, level ? high : low);
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      !identical(old.log, log) || old.trace != trace || old.grid != grid;
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
