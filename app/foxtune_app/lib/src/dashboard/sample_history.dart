import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../connection/connection_controller.dart';
import 'dashboard_controller.dart';

/// Recent realtime samples, for drawing a time graph.
///
/// A plain buffer that notifies painters directly, fed from the realtime feed
/// by a listener that only ever appends. It holds no Riverpod state and reads
/// none back: writing provider state from inside a realtime notification is
/// the re-entry that once crashed autotuning, and a buffer has no need for it.
///
/// What a graph draws from, it reads through [column]: one channel's readings
/// as plain numbers, decoded once as each sample arrives rather than on every
/// frame.
class SampleHistory extends ChangeNotifier {
  SampleHistory({
    this.span = const Duration(seconds: 120),
    this.spacing = Duration.zero,
  });

  /// The history the dashboard keeps: two minutes, at most fifty samples a
  /// second.
  ///
  /// Fifty a second is more than a graph can show - a lane is a few hundred
  /// pixels across, and two minutes of it is several thousand samples - and
  /// it bounds what is held however fast the ECU reports. Two minutes of
  /// rusEFI's 2 KB blocks at 200 a second would be some 50 MB; at fifty, a
  /// quarter of that. Logs and autotuning see every sample regardless.
  SampleHistory.forDashboard()
    : this(spacing: const Duration(milliseconds: 20));

  /// How far back samples are kept. Covers the longest graph window.
  final Duration span;

  /// The least time between two samples kept: one arriving sooner after the
  /// last kept is passed over.
  final Duration spacing;

  final _samples = ListQueue<RealtimeSnapshot>();
  final _columns = <String, SampleColumn>{};

  /// Samples oldest first.
  Iterable<RealtimeSnapshot> get samples => _samples;

  /// The newest sample, or `null` before the first arrives.
  RealtimeSnapshot? get latest => _samples.isEmpty ? null : _samples.last;

  /// Number of samples held.
  int get length => _samples.length;

  /// Samples taken at or after [start], oldest first.
  ///
  /// Found by bisection rather than by walking in from the oldest: the buffer
  /// holds two minutes, most graphs show a fraction of that, and every graph
  /// asks on every frame.
  Iterable<RealtimeSnapshot> since(DateTime start) {
    var low = 0;
    var high = _samples.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_samples.elementAt(middle).timestamp.isBefore(start)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final first = low;
    return Iterable.generate(
      _samples.length - first,
      (i) => _samples.elementAt(first + i),
    );
  }

  /// [channel]'s readings in every sample held, oldest first - kept up to date
  /// from here on.
  SampleColumn column(String channel) => _columns.putIfAbsent(channel, () {
    final column = SampleColumn._(channel);
    _samples.forEach(column._append);
    return column;
  });

  void add(RealtimeSnapshot sample) {
    // The feed can hand the same sample over twice as providers rebuild; a
    // repeated point would draw nothing wrong, but it is not a new reading.
    if (_samples.isNotEmpty) {
      final last = _samples.last;
      if (identical(last, sample)) return;
      if (spacing > Duration.zero &&
          sample.timestamp.difference(last.timestamp) < spacing) {
        return;
      }
    }
    _samples.addLast(sample);
    for (final column in _columns.values) {
      column._append(sample);
    }

    final oldest = sample.timestamp.subtract(span);
    var dropped = 0;
    while (_samples.isNotEmpty && _samples.first.timestamp.isBefore(oldest)) {
      _samples.removeFirst();
      dropped++;
    }
    if (dropped > 0) {
      for (final column in _columns.values) {
        column._dropOldest(dropped);
      }
    }
    notifyListeners();
  }

  /// Forgets everything, as when the connection changes.
  void clear() {
    if (_samples.isEmpty) return;
    _samples.clear();
    for (final column in _columns.values) {
      column._clear();
    }
    notifyListeners();
  }
}

/// One channel's readings in a [SampleHistory], as plain numbers in arrays,
/// oldest first: what a graph lane draws from on every frame, without going
/// back to the samples to decode them again.
class SampleColumn {
  SampleColumn._(this.channel);

  final String channel;

  // The readings held are those from [_start] up to [_end]: appending takes
  // the next slot, dropping the oldest moves [_start] on, and the arrays are
  // compacted or grown only when [_end] reaches the end of them.
  var _times = Float64List(256);
  var _values = Float64List(256);
  var _start = 0;
  var _end = 0;

  /// Number of readings held.
  int get length => _end - _start;

  /// When the [i]th reading was taken, in microseconds since the epoch.
  double timeAt(int i) => _times[_start + i];

  /// The [i]th reading, or `NaN` where its sample had none.
  double valueAt(int i) => _values[_start + i];

  /// The index of the first reading taken at or after [micros], or [length]
  /// if there is none.
  int indexAtOrAfter(double micros) {
    var low = _start;
    var high = _end;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_times[middle] < micros) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - _start;
  }

  void _append(RealtimeSnapshot sample) {
    if (_end == _times.length) {
      final held = length;
      final capacity = held * 2 > _times.length
          ? _times.length * 2
          : _times.length;
      final times = Float64List(capacity)..setRange(0, held, _times, _start);
      final values = Float64List(capacity)..setRange(0, held, _values, _start);
      _times = times;
      _values = values;
      _start = 0;
      _end = held;
    }
    _times[_end] = sample.timestamp.microsecondsSinceEpoch.toDouble();
    _values[_end] = sample[channel] ?? double.nan;
    _end++;
  }

  void _dropOldest(int count) {
    _start += count < length ? count : length;
    if (_start == _end) _start = _end = 0;
  }

  void _clear() => _start = _end = 0;
}

/// History for the connected ECU's realtime feed.
final sampleHistoryProvider = Provider<SampleHistory>((ref) {
  // A new connection starts a new history: a trace running on from the last
  // session into this one would be two engines drawn as one.
  ref.watch(connectionProvider);
  final history = SampleHistory.forDashboard();
  ref.listen<AsyncValue<RealtimeSnapshot>>(realtimeProvider, (previous, next) {
    final sample = next.value;
    if (sample != null) history.add(sample);
  }, fireImmediately: true);
  ref.onDispose(history.dispose);
  return history;
});
