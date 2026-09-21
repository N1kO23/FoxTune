import 'dart:math' as math;
import 'dart:typed_data';

import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/testing.dart';

import '../curve_view.dart';
import '../setting_view.dart';
import '../table_view.dart';
import '../tune_state.dart';
import '../value_resolver.dart';

/// How much air the engine actually swallows, as a volumetric efficiency.
///
/// This is the engine, not the tune: the ECU's VE table is the tuner's *guess*
/// at this, and the whole point of the simulation is that the difference shows
/// up in the exhaust.
typedef AirflowModel = double Function(double rpm, double map);

/// A running engine whose mixture answers to the tune in the ECU's pages.
///
/// The plain [EngineSimulation] makes up an AFR from the throttle position,
/// which is fine for watching gauges move and useless for anything that reads
/// the exhaust. This one closes the loop:
///
/// 1. the VE table in the ECU's own pages decides how much fuel is injected;
/// 2. the engine's real airflow decides how much it needed;
/// 3. the wideband reports the difference, through a sensor lag;
/// 4. closed-loop correction trims the fuel, which changes 1.
///
/// Which means a VE table edited in FoxTune changes what the simulated engine
/// runs at, warmup and afterstart enrichment come off the tune's own curves,
/// and autotuning can be exercised end to end without an engine.
///
/// Fuelling is deliberately defined so that a VE table equal to the engine's
/// true airflow produces exactly the AFR target: that is what "a correct VE
/// table" means to a tuner, and it is the relationship autotuning is trying to
/// reach.
class TunedEngineSimulation extends EngineSimulation {
  TunedEngineSimulation({
    required this.definition,
    required this.pages,
    super.cycle,
    AirflowModel? airflow,
    this.sensorLag = const Duration(milliseconds: 250),
  }) : airflow = airflow ?? defaultAirflow {
    final expected = definition.constants.pageSizes;
    if (pages.length != expected.length) {
      throw ArgumentError('The ECU holds ${pages.length} pages but the '
          'definition declares ${expected.length}.');
    }
    _mirror = TuneState.fromPages(definition, pages);
    _resolver = TuneValueResolver(_mirror);
  }

  /// The definition describing the pages.
  final IniDocument definition;

  /// The ECU's own page memory, read on every sample and written by seeding.
  final List<Uint8List> pages;

  /// The engine's true airflow.
  final AirflowModel airflow;

  /// How long the wideband takes to catch up with a change in mixture.
  ///
  /// Real sensors lag by the time it takes exhaust to reach them plus their
  /// own response. Without it a simulated engine would let a tuner trust
  /// readings taken mid-transition, which is exactly the mistake the settling
  /// filter exists to prevent.
  final Duration sensorLag;

  late final TuneState _mirror;
  late final TuneValueResolver _resolver;

  double _egoCorrection = 100;
  double _egoTimer = 0;
  double _measuredAfr = 14.7;
  double _accelEnrich = 1;
  double _lastSeconds = 0;

  EngineConditions? _lastConditions;
  _Derived? _lastDerived;

  /// A plausible naturally-aspirated airflow curve.
  ///
  /// Peaks in the middle of the rev range and falls away either side, a little
  /// better at high load. Nothing here is a specific engine; it just has to be
  /// smooth, believable and different from any VE table a tuner would type in.
  static double defaultAirflow(double rpm, double map) {
    final speed = math.exp(-math.pow((rpm - 4000) / 2600, 2).toDouble());
    final load = 0.72 + 0.28 * (map / 100).clamp(0.0, 1.2);
    return (58 + 46 * speed) * load;
  }

  /// Resolves a tune constant from the ECU's pages, as of the last sample.
  ///
  /// The realtime block needs this: several channels scale by an expression
  /// over a configuration constant, so they cannot be written without it.
  double? resolve(String name) => _resolver.resolve(name);

  /// Writes a coherent base tune into the ECU's pages.
  ///
  /// A fresh simulator holds filler bytes, which are not a tune: the axis bins
  /// are not even monotonic, so interpolating a table over them means nothing.
  /// This lays down axes, a VE table taken from the engine itself, a flat
  /// mixture target, an ignition map and the enrichment curves - enough that
  /// the simulated engine runs and a tuner has something to work on.
  ///
  /// [errorPercent] offsets the VE table from the engine's real airflow, so
  /// the tune starts wrong by a known amount. That is what makes autotuning
  /// worth watching: at zero there would be nothing to correct.
  void seedTune({double errorPercent = -8, double targetAfr = 14.7}) {
    _sync();
    _seedConstants();

    final config = definition.veAnalyze;
    final veId = config?.table ?? 'veTable1Tbl';
    final targetId = config?.targetTable ?? 'afrTable1Tbl';
    final measuresLambda = config?.measuresLambda ?? false;

    _seedTable(
        veId, (rpm, load) => airflow(rpm, load) * (1 + errorPercent / 100));
    _seedTable(
      targetId,
      (rpm, load) => measuresLambda ? targetAfr / _stoich : targetAfr,
    );
    // A believable spark map: more advance with revs, less under load.
    _seedTable('sparkTbl', (rpm, load) => 12 + rpm / 320 - load * 0.12);

    // Cold enrichment, tapering to nothing once warm.
    _seedCurve('warmup_curve', -40, 100,
        (clt) => clt >= 80 ? 100 : 100 + (80 - clt) * 0.75);
    _seedCurve('afterstart_enrichment_curve', -40, 100,
        (clt) => clt >= 80 ? 5 : 5 + (80 - clt) * 0.3);
    _seedCurve('afterstart_enrichment_time', -40, 100,
        (clt) => clt >= 80 ? 3 : 3 + (80 - clt) * 0.12);
    // Acceleration enrichment against how fast the throttle is moving.
    _seedCurve('time_accel_tpsdot_curve', 0, 400, (rate) => rate * 0.25);

    _flush();
  }

  /// Settings the simulation itself reads, and that scaling depends on.
  void _seedConstants() {
    const values = <String, double>{
      'stoich': 14.7,
      'reqFuel': 9.0,
      'injOpen': 1.0,
      'egoTemp': 60,
      'egoCount': 15,
      'egoLimit': 15,
      'egoRPM': 1200,
      'egoTPSMax': 90,
      'aseTaperTime': 2,
      'dfcoRPM': 1500,
      'dfcoTPSThresh': 2,
      'nCylinders': 4,
    };
    for (final entry in values.entries) {
      SettingView.of(_mirror, entry.key, resolver: _resolver)
          ?.setValue(entry.value);
    }

    // Chosen by label rather than by index: another firmware may order its
    // options differently, and picking the wrong one here would silently
    // change what the simulated ECU is doing.
    _seedOption('algorithm', 'map');
    _seedOption('egoType', 'wide');
    _seedOption('egoAlgorithm', 'simple');
    _resolver.invalidate();
  }

  void _seedOption(String constant, String label) {
    final setting = SettingView.of(_mirror, constant, resolver: _resolver);
    if (setting == null || !setting.isEnumerated) return;

    final options = [for (final o in setting.options) o.toLowerCase()];
    // An exact match first: "MAP" and "IMAP/EMAP" both contain "map", and
    // picking the wrong one changes what the load axis means.
    var index = options.indexOf(label);
    if (index < 0) index = options.indexWhere((o) => o.contains(label));
    if (index >= 0) setting.setOptionIndex(index);
  }

  /// Lays down ascending axes and fills a table from [value].
  void _seedTable(String id, double Function(double rpm, double load) value) {
    final table = definition.tableNamed(id);
    if (table == null) return;
    final view = TableView.of(_mirror, table, resolver: _resolver);
    if (view == null) return;

    _seedAxis(view.columns, 500, 7000, view.xBounds, view.setXAt);
    _seedAxis(view.rows, 20, 100, view.yBounds, view.setYAt);

    for (var r = 0; r < view.rows; r++) {
      for (var c = 0; c < view.columns; c++) {
        final rpm = view.xAt(c);
        final load = view.yAt(r);
        if (rpm == null || load == null) continue;
        view.setValueAt(r, c, value(rpm, load));
      }
    }
  }

  void _seedCurve(
      String id, double from, double to, double Function(double) value) {
    final curve = definition.curveNamed(id);
    if (curve == null) return;
    final view = CurveView.of(_mirror, curve, resolver: _resolver);
    if (view == null) return;

    _seedAxis(view.length, from, to, view.xBounds, view.setXAt);
    for (var i = 0; i < view.length; i++) {
      final x = view.xAt(i);
      if (x != null) view.setYAt(i, value(x));
    }
  }

  /// Spreads [count] bins evenly between [from] and [to].
  static void _seedAxis(
    int count,
    double from,
    double to,
    ({double? low, double? high}) bounds,
    void Function(int index, double value) set,
  ) {
    if (count <= 0) return;
    final low = math.max(from, bounds.low ?? from);
    final high = math.min(to, bounds.high ?? to);
    final span = high - low;
    for (var i = 0; i < count; i++) {
      set(i, count == 1 ? low : low + span * i / (count - 1));
    }
  }

  /// Hands the edited pages back to the ECU; the mirror is a copy.
  void _flush() {
    for (var i = 0; i < pages.length; i++) {
      pages[i].setAll(0, _mirror.page(i + 1));
    }
    _resolver.invalidate();
  }

  @override
  Map<String, double> sampleAt(EngineConditions now) {
    final derived = _derive(now);

    return {
      ...housekeeping(now),
      'rpm': now.rpm,
      'map': now.map,
      'tps': now.throttle,
      'coolantRaw': now.coolant + 40,
      'iatRaw': now.iat + 40,
      'batteryVoltage': now.battery,
      'afr': derived.measuredAfr,
      'afrTarget': derived.targetAfr,
      'advance': derived.advance,
      'VE1': derived.tuneVe,
      'veCurr': derived.tuneVe,
      // Each correction as the firmware reports it, and their product - the
      // firmware's "gamma enrichment", which is what the fuel equation used.
      'accelEnrich': derived.accelEnrich * 100,
      'ASECurr': derived.asePercent,
      // Fuel cut zeroes it, as the firmware does.
      'gammaEnrich': derived.fuelCut
          ? 0
          : derived.warmupPercent *
              derived.asePercent *
              derived.accelEnrich *
              derived.egoCorrection /
              1e4,
      'pulseWidth': derived.pulseWidth,
      'dwell': 3.1,
      'nSquirts': 2,
      'egoCorrection': derived.egoCorrection,
      'dutyCycle': derived.dutyCycle,
      'fuelLoad': derived.fuelLoad,
      'ignLoad': derived.ignLoad,
      'warmupEnrich': derived.warmupPercent,
    };
  }

  @override
  Map<String, bool> flagsAt(EngineConditions now) {
    final derived = _derive(now);
    return {
      'crank': now.cranking,
      'running': now.rpm > 300,
      'ase': derived.aseActive,
      'warmup': derived.warmupPercent > 101,
      'DFCOOn': derived.fuelCut,
      'sync': now.rpm > 200,
      // The flag a tuning filter watches for, so a reading taken during a
      // throttle stab is thrown away rather than believed.
      'tpsaccaen': derived.accelEnrich > 1.01,
    };
  }

  /// Copies the ECU's current pages into the mirror the tables read from.
  ///
  /// Done every sample rather than on a change notification: the pages are
  /// written from another code path entirely, and a simulation that kept
  /// running on a stale VE table would be worse than no simulation.
  void _sync() {
    for (var i = 0; i < pages.length; i++) {
      _mirror.setPage(i + 1, pages[i]);
    }
    _resolver.invalidate();
  }

  double get _stoich => _resolver.resolve('stoich') ?? 14.7;

  double _constant(String name, double fallback) =>
      _resolver.resolve(name) ?? fallback;

  /// The label of a bitfield setting, for options this reads by name.
  String? _option(String name) {
    final located = _mirror.locate(name);
    final field = located?.field;
    if (located == null || field is! IniBitsField) return null;
    final raw = _mirror.readBits(located.page, field);
    return raw == null ? null : field.labelFor(raw);
  }

  _Derived _derive(EngineConditions now) {
    // FakeSpeeduino asks for the sample and the flags of the same instant;
    // the physics must advance once, not twice.
    if (identical(_lastConditions, now)) return _lastDerived!;

    final dt = (now.seconds - _lastSeconds).clamp(0.0, 0.25);
    _lastSeconds = now.seconds;
    _sync();

    final stoich = _stoich;
    final config = definition.veAnalyze;

    // The load axis is whatever the tune says it is; running throttle-based
    // load and reporting MAP would put the live cursor in the wrong cell.
    final loadSource = _option('algorithm')?.toLowerCase() ?? 'map';
    final fuelLoad = loadSource == 'tps' ? now.throttle : now.map;
    final ignLoad = fuelLoad;

    final veView = _viewOf(config?.table ?? 'veTable1Tbl');
    final tuneVe = veView?.interpolatedAt(now.rpm, fuelLoad) ?? 50;

    final targetView = _viewOf(config?.targetTable ?? 'afrTable1Tbl');
    final rawTarget = targetView?.interpolatedAt(now.rpm, fuelLoad);
    final targetAfr = rawTarget == null
        ? stoich
        : ((config?.measuresLambda ?? false) ? rawTarget * stoich : rawTarget);

    final warmupPercent = _curveAt('warmup_curve', now.coolant) ?? 100;
    final aseTaper = _constant('aseTaperTime', 0);
    final aseDuration =
        _curveAt('afterstart_enrichment_time', now.coolant) ?? 0;
    final aseActive = !now.cranking && now.seconds < aseDuration + aseTaper;
    final asePercent = aseActive
        ? (_curveAt('afterstart_enrichment_curve', now.coolant) ?? 0) + 100
        : 100.0;

    // Acceleration enrichment fires on throttle movement and decays away.
    final taeRate = _curveAt('time_accel_tpsdot_curve', now.throttleRate) ?? 0;
    if (now.throttleRate > 30 && taeRate > 0) {
      _accelEnrich = 1 + taeRate / 100;
    } else if (dt > 0) {
      _accelEnrich = 1 + (_accelEnrich - 1) * math.exp(-dt / 0.35);
      if (_accelEnrich < 1.001) _accelEnrich = 1;
    }

    final fuelCut = now.overrun && now.rpm > _constant('dfcoRPM', 1500);

    final fuelFactor = (tuneVe / 100) *
        (warmupPercent / 100) *
        (asePercent / 100) *
        _accelEnrich *
        (_egoCorrection / 100);
    final airFactor = airflow(now.rpm, now.map) / 100;

    // A VE table equal to the engine's airflow, with no corrections, lands
    // exactly on target. Everything else is read off that.
    final instantAfr = fuelCut || fuelFactor <= 0
        ? _leanPeg
        : (targetAfr * airFactor / fuelFactor).clamp(_richPeg, _leanPeg);

    if (dt > 0) {
      final alpha = 1 - math.exp(-dt / (sensorLag.inMilliseconds / 1000));
      _measuredAfr += (instantAfr - _measuredAfr) * alpha;
    } else {
      _measuredAfr = instantAfr;
    }

    _stepClosedLoop(now, dt, targetAfr, aseActive, fuelCut);

    final reqFuel = _constant('reqFuel', 8);
    final injOpen = _constant('injOpen', 1);
    final pulseWidth =
        fuelCut ? 0.0 : reqFuel * fuelFactor * (now.map / 100) + injOpen;

    final advance = _viewOf('sparkTbl')?.interpolatedAt(now.rpm, ignLoad) ?? 15;

    final derived = _Derived(
      tuneVe: tuneVe,
      measuredAfr: _measuredAfr,
      egoCorrection: _egoCorrection,
      pulseWidth: pulseWidth,
      dutyCycle: (pulseWidth * 2 * now.rpm / 1200).clamp(0, 100),
      advance: advance,
      warmupPercent: warmupPercent,
      asePercent: asePercent,
      targetAfr: targetAfr,
      aseActive: aseActive,
      accelEnrich: _accelEnrich,
      fuelCut: fuelCut,
      fuelLoad: fuelLoad,
      ignLoad: ignLoad,
    );

    _lastConditions = now;
    _lastDerived = derived;
    return derived;
  }

  /// What a wideband reads with no fuel at all, and with far too much.
  static const _leanPeg = 22.0;
  static const _richPeg = 9.0;

  /// Trims fuelling towards the target, the way the ECU's own loop does.
  void _stepClosedLoop(
    EngineConditions now,
    double dt,
    double targetAfr,
    bool aseActive,
    bool fuelCut,
  ) {
    final algorithm = _option('egoAlgorithm') ?? 'Simple';
    final sensor = _option('egoType') ?? 'Wide Band';
    final limit = _constant('egoLimit', 15);

    final active = !algorithm.toLowerCase().contains('no correct') &&
        !sensor.toLowerCase().contains('disabled') &&
        !now.cranking &&
        !aseActive &&
        !fuelCut &&
        now.coolant > _constant('egoTemp', 60) &&
        now.rpm > _constant('egoRPM', 1200) &&
        now.throttle < _constant('egoTPSMax', 95);

    if (!active) {
      // The firmware drops the trim rather than holding a stale one.
      _egoCorrection = 100;
      _egoTimer = 0;
      return;
    }

    // `egoCount` is a number of engine cycles between corrections, so how
    // often that comes round depends on how fast the engine is turning.
    _egoTimer += dt;
    final interval =
        now.rpm <= 0 ? 1.0 : _constant('egoCount', 15) / (now.rpm / 60);
    if (_egoTimer < interval) return;
    _egoTimer = 0;

    final error = _measuredAfr - targetAfr;
    if (error.abs() < 0.05) return;
    // Lean reads high, and needs more fuel.
    _egoCorrection =
        (_egoCorrection + (error > 0 ? 1 : -1)).clamp(100 - limit, 100 + limit);
  }

  TableView? _viewOf(String id) {
    final table = definition.tableNamed(id);
    if (table == null) return null;
    return TableView.of(_mirror, table, resolver: _resolver);
  }

  double? _curveAt(String id, double x) {
    final curve = definition.curveNamed(id);
    if (curve == null) return null;
    return CurveView.of(_mirror, curve, resolver: _resolver)?.valueAt(x);
  }
}

class _Derived {
  const _Derived({
    required this.tuneVe,
    required this.measuredAfr,
    required this.egoCorrection,
    required this.pulseWidth,
    required this.dutyCycle,
    required this.advance,
    required this.warmupPercent,
    required this.asePercent,
    required this.targetAfr,
    required this.aseActive,
    required this.accelEnrich,
    required this.fuelCut,
    required this.fuelLoad,
    required this.ignLoad,
  });

  final double tuneVe;
  final double measuredAfr;
  final double egoCorrection;
  final double pulseWidth;
  final double dutyCycle;
  final double advance;
  final double warmupPercent;
  final double asePercent;
  final double targetAfr;
  final bool aseActive;
  final double accelEnrich;
  final bool fuelCut;
  final double fuelLoad;
  final double ignLoad;
}
