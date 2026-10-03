import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/dashboard_controller.dart';
import '../tune/tune_controller.dart';

/// What the autotuning screen shows.
class AutotuneSession {
  const AutotuneSession({
    required this.settings,
    this.armed = false,
    this.tuner,
    this.last,
    this.blockedReason,
    this.sendToEcu = false,
    this.sendProblem,
  });

  /// The limits a session would run, or is running, under.
  final AutotuneSettings settings;

  /// Whether samples are being collected.
  final bool armed;

  /// The running analyser, while armed.
  final VeAutotuner? tuner;

  /// What became of the most recent sample.
  final AutotuneOutcome? last;

  /// Why arming was refused, if it was.
  final String? blockedReason;

  /// Whether corrections go to the ECU's RAM as they are made.
  ///
  /// Off, the ECU runs a correction only once it is burned, and the cells it
  /// touches wait until then. Resets on every disconnect, as write mode does.
  final bool sendToEcu;

  /// Why sending stopped, if it did.
  final String? sendProblem;

  /// Samples used so far this session.
  int get accepted => tuner?.acceptedSamples ?? 0;

  /// Samples discarded so far this session.
  int get rejected => tuner?.rejectedSamples ?? 0;

  /// Cells whose value autotuning has changed.
  int get moved => tuner?.movedCells ?? 0;

  /// Cells holding any data at all.
  int get covered => tuner?.cells.length ?? 0;

  AutotuneSession copyWith({
    AutotuneSettings? settings,
    bool? armed,
    VeAutotuner? tuner,
    AutotuneOutcome? last,
    String? blockedReason,
    bool? sendToEcu,
    String? sendProblem,
    bool clearTuner = false,
    bool clearBlocked = false,
    bool clearSendProblem = false,
  }) => AutotuneSession(
    settings: settings ?? this.settings,
    armed: armed ?? this.armed,
    tuner: clearTuner ? null : (tuner ?? this.tuner),
    last: last ?? this.last,
    blockedReason: clearBlocked ? null : (blockedReason ?? this.blockedReason),
    sendToEcu: sendToEcu ?? this.sendToEcu,
    sendProblem: clearSendProblem ? null : (sendProblem ?? this.sendProblem),
  );
}

/// The autotuning session.
final autotuneProvider = NotifierProvider<AutotuneController, AutotuneSession>(
  AutotuneController.new,
);

class AutotuneController extends Notifier<AutotuneSession> {
  /// The session, held here rather than read back out of Riverpod.
  ///
  /// Reading `state` flushes this provider, and flushing walks its ancestors
  /// and rebuilds any that are stale. That is fine from a button press and
  /// wrong from inside a realtime notification: applying a correction marks
  /// the tune edited, which makes the realtime feed stale, so reading the
  /// session back asks Riverpod to rebuild a provider that is still part-way
  /// through notifying us - and it asserts. Writing `state` does not flush, so
  /// the session is kept here and pushed out.
  ///
  /// The notifier instance outlives `build`, so this survives a rebuild that
  /// would otherwise discard a session mid-run.
  AutotuneSession _session = const AutotuneSession(
    settings: AutotuneSettings(),
  );

  DateTime _lastPublished = DateTime.fromMillisecondsSinceEpoch(0);

  /// How often the status strip refreshes while nothing is changing.
  ///
  /// Samples arrive at about 30 Hz. Publishing every one of them would rebuild
  /// the whole grid that often for a counter that ticks. A cell moving, or the
  /// reason for waiting changing, is published straight away regardless -
  /// those are the two things a tuner is watching for.
  static const _publishInterval = Duration(milliseconds: 200);

  @override
  AutotuneSession build() {
    // Deliberately not watching the tune: applying a correction changes it,
    // and a rebuild here would discard the session that made the change.
    ref.listen(realtimeProvider, (previous, next) {
      // The feed hands the last sample over again as it rebuilds - which an
      // applied correction can cause - and one reading must not be corrected
      // for twice.
      final snapshot = next.value;
      if (snapshot != null && !identical(snapshot, previous?.value)) {
        _consume(snapshot);
      }
    });

    ref.listen(connectionProvider, (previous, next) {
      if (next is EcuConnected) return;
      disarm();
      _pending.clear();
      if (_session.sendToEcu) _emit(_session.copyWith(sendToEcu: false));
    });

    return _session;
  }

  /// Publishes [next] without reading the current state back.
  void _emit(AutotuneSession next) {
    _session = next;
    state = next;
  }

  /// Starts collecting, or records why it cannot.
  void arm() {
    final tune = ref.read(tuneProvider).value;
    if (tune == null) {
      _emit(_session.copyWith(blockedReason: 'No tune is loaded yet.'));
      return;
    }

    final result = VeAutotuner.create(
      tune: tune,
      permission: ref.read(writePermissionProvider),
      resolver: ref.read(tuneResolverProvider),
      settings: _session.settings,
    );

    final tuner = result.tuner;
    if (tuner == null) {
      _emit(
        _session.copyWith(
          armed: false,
          blockedReason: result.readiness.reason,
          clearTuner: true,
        ),
      );
      return;
    }

    _lastPublished = DateTime.fromMillisecondsSinceEpoch(0);
    _emit(_session.copyWith(armed: true, tuner: tuner, clearBlocked: true));
  }

  /// Stops collecting. Anything already applied stays applied.
  void disarm() {
    if (!_session.armed) return;
    _emit(_session.copyWith(armed: false));
  }

  /// Throws away the session's data and its record of what it changed.
  ///
  /// The table keeps the values autotuning gave it - undoing those is what
  /// re-reading the tune from the ECU is for.
  void resetSession() {
    _session.tuner?.reset();
    _emit(_session.copyWith(last: null));
  }

  /// Replaces the limits, restarting the session if one is running.
  void updateSettings(AutotuneSettings settings) {
    final wasArmed = _session.armed;
    _emit(
      _session.copyWith(settings: settings, armed: false, clearTuner: true),
    );
    if (wasArmed) arm();
  }

  /// Starts or stops sending corrections to the ECU's RAM as they are made.
  ///
  /// Starting sends the corrections this session has already made, so the
  /// cells waiting for them can go on collecting.
  void setSendToEcu(bool on) {
    _emit(_session.copyWith(sendToEcu: on, clearSendProblem: true));
    if (!on) {
      _pending.clear();
      return;
    }
    final tuner = _session.tuner;
    if (tuner == null) return;
    _send([
      for (final entry in tuner.cells.entries)
        if (entry.value.appliedPercent != 0) entry.key,
    ]);
  }

  /// Cells waiting to be sent, as byte ranges of their page.
  final _pending = <({int page, int offset, int length})>{};
  bool _sending = false;

  void _send(Iterable<({int row, int column})> cells) {
    final table = _session.tuner?.table;
    if (table == null) return;
    for (final cell in cells) {
      final at = table.storageOf(cell.row, cell.column);
      _pending.add((page: table.page, offset: at.offset, length: at.length));
    }
    if (_pending.isEmpty || _sending) return;
    _sending = true;
    // Once the realtime notification this may be called from has returned:
    // see [_session].
    Future.microtask(_flush);
  }

  /// Sends what is waiting, one range at a time, until none is left.
  ///
  /// Each range is read from the tune when it is sent, so a cell corrected
  /// twice while waiting goes once, with its latest value.
  Future<void> _flush() async {
    try {
      while (_pending.isNotEmpty && _session.sendToEcu && ref.mounted) {
        final next = _pending.first;
        _pending.remove(next);
        await ref
            .read(tuneProvider.notifier)
            .sendToEcu(next.page, offset: next.offset, length: next.length);
      }
    } on Object catch (error) {
      _pending.clear();
      if (ref.mounted) {
        _emit(
          _session.copyWith(
            sendToEcu: false,
            sendProblem:
                'Sending to the ECU stopped: $error. Corrections stay in the '
                'tune; burn to keep them.',
          ),
        );
      }
    } finally {
      _sending = false;
    }
  }

  void _consume(RealtimeSnapshot snapshot) {
    final session = _session;
    final tuner = session.tuner;
    if (!session.armed || tuner == null) return;

    // The sample's own timestamp drives the throttle rather than the wall
    // clock: it is the clock the data is on, and it stays meaningful when the
    // samples come from somewhere other than a live link.
    final at = snapshot.timestamp;
    final outcome = tuner.offer(snapshot.value, at);

    if (outcome.moved.isNotEmpty) {
      // The tune changed, so everything showing it has to hear about it.
      ref.read(tuneProvider.notifier).notifyEdited();
      if (session.sendToEcu) _send(outcome.moved);
      _publish(outcome, at);
      return;
    }

    if (outcome.description != session.last?.description) {
      _publish(outcome, at);
      return;
    }

    if (at.difference(_lastPublished) < _publishInterval) return;
    _publish(outcome, at);
  }

  void _publish(AutotuneOutcome outcome, DateTime at) {
    _lastPublished = at;
    _emit(_session.copyWith(last: outcome));
  }
}
