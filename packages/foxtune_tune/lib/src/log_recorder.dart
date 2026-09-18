import 'dart:async';
import 'dart:io';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import 'msl_writer.dart';

/// Records realtime samples to a `.msl` file.
///
/// Rows are appended as they arrive rather than buffered to the end, so a log
/// survives the app being killed, the battery being disconnected, or the engine
/// doing something that ends the session abruptly - which is exactly when the
/// log matters most.
class LogRecorder {
  LogRecorder({required this.definition, this.constantResolver});

  final IniDocument definition;

  /// Supplies values the realtime block does not carry, for gating conditions.
  final double? Function(String name)? constantResolver;

  IOSink? _sink;
  MslLogWriter? _writer;
  Stopwatch? _clock;
  StreamSubscription<RealtimeSnapshot>? _subscription;
  int _rows = 0;
  File? _file;

  /// Whether recording is in progress.
  bool get isRecording => _sink != null;

  /// Rows written so far.
  int get rowCount => _rows;

  /// The file being written, or `null` when not recording.
  File? get file => _file;

  /// Channels excluded from the log, and therefore absent from it.
  List<String> get droppedChannels => _writer?.dropped ?? const [];

  /// Begins recording to [file], using [probe] to decide the columns.
  ///
  /// A probe sample is required because the column set depends on what the ECU
  /// actually reports: starting without one would produce a header full of
  /// columns that stay blank.
  Future<void> start(File file, {required RealtimeSnapshot probe}) async {
    if (isRecording) {
      throw StateError('Already recording to ${_file?.path}');
    }

    final writer = MslLogWriter.forDefinition(
      definition,
      probe: probe,
      constantResolver: constantResolver,
    );
    await file.parent.create(recursive: true);
    // Held open for the life of the recording and closed by stop(); the
    // analyzer cannot see across that hand-off.
    // ignore: close_sinks
    final sink = file.openWrite();
    sink.write(writer.header());

    _writer = writer;
    _sink = sink;
    _file = file;
    _rows = 0;
    _clock = Stopwatch()..start();
  }

  /// Appends [snapshot] as a row. Ignored when not recording.
  void add(RealtimeSnapshot snapshot) {
    final sink = _sink;
    final writer = _writer;
    final clock = _clock;
    if (sink == null || writer == null || clock == null) return;

    sink.write(writer.row(snapshot, clock.elapsed));
    _rows++;
  }

  /// Records every sample from [snapshots] until [stop].
  void listenTo(Stream<RealtimeSnapshot> snapshots) {
    _subscription?.cancel();
    _subscription = snapshots.listen(add);
  }

  /// Finishes the log and closes the file.
  Future<File?> stop() async {
    final sink = _sink;
    final file = _file;
    await _subscription?.cancel();
    _subscription = null;
    _sink = null;
    _writer = null;
    _clock?.stop();
    _clock = null;

    if (sink == null) return null;
    await sink.flush();
    await sink.close();
    return file;
  }
}
