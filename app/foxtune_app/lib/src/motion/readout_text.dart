import 'dart:async';

import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Text stating a live reading: shown as it is - or, with calm readouts on,
/// changed at most once each tick of [ReadoutClock], so a number arriving 200
/// times a second can still be read.
///
/// A change after a quiet spell shows at once; only one following close on
/// another waits for the next tick, and then the newest shows. Whatever the
/// reading means - an alarm colour, a badge - is for the caller to show from
/// the reading itself, never held back.
///
/// Calm, a readout also skips most of the text layout a changing number costs,
/// which on a busy dashboard is much of what drawing a frame does.
class ReadoutText extends StatefulWidget {
  const ReadoutText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  State<ReadoutText> createState() => _ReadoutTextState();
}

class _ReadoutTextState extends State<ReadoutText> {
  late String _shown = widget.text;

  /// The tick [_shown] last changed on.
  int _changedAt = -1;

  ReadoutClock? _clock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final calm = Motion.of(context).calmReadouts;
    if (calm && _clock == null) {
      _clock = ReadoutClock.instance..addListener(_onTick);
    } else if (!calm && _clock != null) {
      _clock!.removeListener(_onTick);
      _clock = null;
      _shown = widget.text;
    }
  }

  @override
  void didUpdateWidget(ReadoutText old) {
    super.didUpdateWidget(old);
    final clock = _clock;
    if (clock == null) {
      _shown = widget.text;
    } else if (widget.text != _shown && clock.tick != _changedAt) {
      _shown = widget.text;
      _changedAt = clock.tick;
    }
  }

  void _onTick() {
    final clock = _clock;
    if (clock == null || widget.text == _shown) return;
    setState(() {
      _shown = widget.text;
      _changedAt = clock.tick;
    });
  }

  @override
  void dispose() {
    _clock?.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    _shown,
    style: widget.style,
    maxLines: widget.maxLines,
    overflow: widget.overflow,
    textAlign: widget.textAlign,
  );
}

/// Ticks every [period] for [ReadoutText]s, all together - one timer for a
/// whole dashboard - and only while one is listening.
class ReadoutClock extends ChangeNotifier {
  ReadoutClock._();

  static final instance = ReadoutClock._();

  static const period = Duration(milliseconds: 100);

  Timer? _timer;

  /// How many ticks have passed.
  int get tick => _tick;
  var _tick = 0;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _timer ??= Timer.periodic(period, (_) {
      _tick++;
      notifyListeners();
    });
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Whether the clock is running.
  @visibleForTesting
  bool get running => _timer != null;
}
