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
class SampleHistory extends ChangeNotifier {
  SampleHistory({this.span = const Duration(seconds: 120)});

  /// How far back samples are kept. Covers the longest graph window.
  final Duration span;

  final _samples = ListQueue<RealtimeSnapshot>();

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

  void add(RealtimeSnapshot sample) {
    // The feed can hand the same sample over twice as providers rebuild; a
    // repeated point would draw nothing wrong, but it is not a new reading.
    if (_samples.isNotEmpty && identical(_samples.last, sample)) return;
    _samples.addLast(sample);

    final oldest = sample.timestamp.subtract(span);
    while (_samples.isNotEmpty && _samples.first.timestamp.isBefore(oldest)) {
      _samples.removeFirst();
    }
    notifyListeners();
  }

  /// Forgets everything, as when the connection changes.
  void clear() {
    if (_samples.isEmpty) return;
    _samples.clear();
    notifyListeners();
  }
}

/// History for the connected ECU's realtime feed.
final sampleHistoryProvider = Provider<SampleHistory>((ref) {
  // A new connection starts a new history: a trace running on from the last
  // session into this one would be two engines drawn as one.
  ref.watch(connectionProvider);
  final history = SampleHistory();
  ref.listen<AsyncValue<RealtimeSnapshot>>(realtimeProvider, (previous, next) {
    final sample = next.value;
    if (sample != null) history.add(sample);
  }, fireImmediately: true);
  ref.onDispose(history.dispose);
  return history;
});
