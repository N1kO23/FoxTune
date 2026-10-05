import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_protocol/io.dart' show BlockSink, BlockSinkFactory;

import 'msl_writer.dart';
import 'tune_state.dart';
import 'value_resolver.dart';

/// Records realtime samples to a `.msl` file.
///
/// Rows are appended as they arrive rather than buffered to the end, so a log
/// survives the app being killed, the battery being disconnected, or the engine
/// doing something that ends the session abruptly - which is exactly when the
/// log matters most.
class LogRecorder {
  LogRecorder({
    required this.definition,
    this.constantResolver,
    this.spacing = Duration.zero,
  });

  final IniDocument definition;

  /// Supplies values the realtime block does not carry, for gating conditions.
  final double? Function(String name)? constantResolver;

  /// The time between rows, at least: samples coming faster are logged on
  /// that beat and the rest passed over. Zero logs every sample.
  ///
  /// rusEFI can report 200 times a second, with a thousand columns a row -
  /// over a megabyte of log a second. Most sessions need far less.
  final Duration spacing;

  IOSink? _sink;
  MslLogWriter? _writer;

  /// When the first row was sampled: the zero of the log's `Time` column.
  DateTime? _first;

  /// When the next row is due, where rows are spaced.
  DateTime? _due;
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
    _first = null;
    _due = null;
  }

  /// Appends [snapshot] as a row - unless it comes before the next row is
  /// due, with rows [spacing]d. Ignored when not recording.
  ///
  /// A row's time is when its sample was taken, not when it was written: a
  /// busy moment that delays samples on their way here bunches them up, but
  /// their times stay as the ECU's readings were.
  void add(RealtimeSnapshot snapshot) {
    final sink = _sink;
    final writer = _writer;
    if (sink == null || writer == null) return;
    // A sample read in parts would log blanks for the channels left unread:
    // a log has the whole block polled, and keeps only whole samples.
    if (snapshot.coverage != null) return;

    final at = snapshot.timestamp;
    final due = _due;
    if (due != null && at.isBefore(due)) return;
    if (spacing > Duration.zero) {
      // On a steady beat, so jitter in when samples come does not slow the
      // rows - picked up again from here where samples come slower than it.
      final next = (due ?? at).add(spacing);
      _due = next.isAfter(at) ? next : at.add(spacing);
    }

    final first = _first ??= at;
    sink.write(writer.row(snapshot, at.difference(first)));
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
    _first = null;
    _due = null;

    if (sink == null) return null;
    await sink.flush();
    await sink.close();
    return file;
  }
}

/// Writes an MSL datalog on an `EcuWorker`'s isolate, where samples are read:
/// the log keeps pace with the ECU however busy the UI is, and none of its
/// formatting - a thousand numbers a row for rusEFI - lands on the UI's
/// isolate.
///
/// Sent to that isolate, so it carries what the log needs as data: the
/// definition; the [tune], for the computed channels and conditions that
/// depend on settings - as it was when logging began; the file; a [probe]
/// block deciding the columns; and the [spacing] between rows. See
/// [LogRecorder].
class MslSinkFactory implements BlockSinkFactory {
  const MslSinkFactory({
    required this.definition,
    required this.path,
    required this.probe,
    this.tune,
    this.spacing = Duration.zero,
  });

  final IniDocument definition;
  final String path;

  /// A block read before logging began, which decides what the log carries:
  /// see [LogRecorder.start].
  final Uint8List probe;

  final TuneState? tune;
  final Duration spacing;

  @override
  Future<BlockSink> open() async {
    final tune = this.tune;
    final resolve = tune == null ? null : TuneValueResolver(tune).resolve;
    final decoder = RealtimeDecoder(
      definition.outputChannels,
      constantResolver: resolve,
    );
    final recorder = LogRecorder(
      definition: definition,
      constantResolver: resolve,
      spacing: spacing,
    );
    await recorder.start(File(path), probe: decoder.decode(probe));
    return _MslSink(recorder, decoder);
  }
}

class _MslSink implements BlockSink {
  _MslSink(this._recorder, this._decoder);

  final LogRecorder _recorder;
  final RealtimeDecoder _decoder;

  @override
  void add(Uint8List block, DateTime timestamp) =>
      _recorder.add(_decoder.decode(block, timestamp: timestamp));

  @override
  int get count => _recorder.rowCount;

  @override
  Future<void> close() async {
    await _recorder.stop();
  }
}
