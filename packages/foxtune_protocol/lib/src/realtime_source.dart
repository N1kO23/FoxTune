import 'realtime_decoder.dart';

/// Live data from an ECU: samples as they are read, and how reading them is
/// going.
///
/// [RealtimeMonitor] polls on the isolate it runs on; `EcuWorker` polls on an
/// isolate of its own and hands the samples over - the same either way to
/// whatever listens.
abstract interface class RealtimeSource {
  /// Decoded samples, newest last.
  Stream<RealtimeSnapshot> get snapshots;

  /// Poll failures. Subscribing is optional; errors are not fatal on their
  /// own - but a [RealtimeLinkLost] means polling has stopped for good.
  Stream<Object> get errors;

  /// The newest sample, or `null` before the first.
  RealtimeSnapshot? get latest;

  /// The time between polls asked for.
  Duration get interval;

  /// Whether polling is active.
  bool get isRunning;

  /// Total successful polls since [start].
  int get pollCount;

  /// Achieved poll rate, averaged over the last second: what the link
  /// actually sustained, which on a slow connection is well below the rate
  /// asked for.
  double get measuredHz;

  /// Begins polling. Does nothing if already running.
  void start();

  /// Stops polling. Safe to call when not running.
  Future<void> stop();

  /// Stops polling and releases the streams.
  Future<void> dispose();
}
