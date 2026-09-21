import 'dart:math' as math;

/// What the driver and the engine are doing at one instant.
///
/// Separated from the channel map so a model that reads the tune can reuse the
/// driving profile - the throttle, revs and temperatures - and work out the
/// fuelling for itself instead of repeating the drive cycle.
class EngineConditions {
  const EngineConditions({
    required this.seconds,
    required this.phase,
    required this.throttle,
    required this.throttleRate,
    required this.rpm,
    required this.map,
    required this.coolant,
    required this.iat,
    required this.battery,
    required this.cranking,
    required this.overrun,
  });

  /// Seconds since the simulation began.
  final double seconds;

  /// Position within the drive cycle, from 0 to 1.
  final double phase;

  /// Throttle position, as a percentage.
  final double throttle;

  /// How fast the throttle is moving, in percent per second.
  ///
  /// What acceleration enrichment keys off, and what a tuning filter uses to
  /// throw the resulting mixture reading away.
  final double throttleRate;

  /// Engine speed.
  final double rpm;

  /// Manifold absolute pressure, in kPa.
  final double map;

  /// Coolant temperature, in degrees Celsius.
  final double coolant;

  /// Intake air temperature, in degrees Celsius.
  final double iat;

  /// Battery voltage.
  final double battery;

  /// Whether the starter is still turning the engine.
  final bool cranking;

  /// Whether the throttle is shut with the engine still turning fast.
  final bool overrun;
}

/// A crude but plausible running engine, for driving a UI without hardware.
///
/// This is not a physical model. It exists so gauges move, the live table
/// cursor travels across cells, and warning thresholds are actually reached -
/// which is what UI work needs and a static block of filler bytes cannot give.
///
/// The cycle is deliberate: idle, a pull to high load, a cruise, then a
/// closed-throttle overrun. That sweep visits the corners of a VE table and
/// crosses the coolant and RPM alarm thresholds.
///
/// Fuelling here is canned. For a model where the mixture actually answers to
/// the VE table in the ECU's pages, see `TunedEngineSimulation` in
/// `package:foxtune_tune/simulation.dart`.
class EngineSimulation {
  EngineSimulation({this.cycle = const Duration(seconds: 24)});

  /// How long one idle-pull-cruise-overrun cycle takes.
  final Duration cycle;

  final _startedAt = DateTime.now();

  /// Seconds since the simulation began.
  double get elapsedSeconds =>
      DateTime.now().difference(_startedAt).inMilliseconds / 1000;

  /// The drive cycle at the current instant.
  EngineConditions conditions() => conditionsAt(elapsedSeconds);

  /// The drive cycle [t] seconds after the simulation began.
  ///
  /// A pure function of time, so a rate of change - revs per second, say -
  /// can be read off it by looking a moment back, without keeping history.
  EngineConditions conditionsAt(double t) {
    final seconds = cycle.inSeconds;
    final phase = (t % seconds) / seconds;

    // Throttle profile across the cycle, and how fast it is moving. The rate
    // is taken from the profile rather than from a remembered previous
    // sample, so it is the same whether this is called once or ten times.
    final double throttle;
    final double throttleRate;
    if (phase < 0.25) {
      throttle = 0; // idle
      throttleRate = 0;
    } else if (phase < 0.45) {
      throttle = ((phase - 0.25) / 0.20) * 100; // pull
      throttleRate = 100 / (0.20 * seconds);
    } else if (phase < 0.75) {
      throttle = 35 + 10 * math.sin(t * 1.5); // cruise
      throttleRate = 10 * 1.5 * math.cos(t * 1.5);
    } else {
      throttle = 0; // overrun
      throttleRate = phase < 0.76 ? -100 / (0.01 * seconds) : 0;
    }

    final rpm = _rpmFor(phase, throttle, t);
    final closedThrottle = throttle < 2;
    // Manifold pressure tracks throttle: near-vacuum closed, near-baro open.
    final map =
        closedThrottle ? 32 + 3 * math.sin(t * 2) : 35 + throttle * 0.62;

    // Coolant warms up once and then holds, briefly overshooting so the
    // warning threshold is actually exercised.
    final warmup = math.min(t / 70, 1.0);
    final coolant = 20 + warmup * 82 + 6 * math.sin(t * 0.25) * warmup;
    final load = map / 100;

    return EngineConditions(
      seconds: t,
      phase: phase,
      throttle: throttle,
      throttleRate: throttleRate,
      rpm: rpm,
      map: map,
      coolant: coolant,
      iat: 24 + 6 * load + math.sin(t * 0.4),
      battery: 13.9 - 0.5 * load,
      cranking: t < 1.2,
      overrun: closedThrottle && rpm > 1500,
    );
  }

  /// Channel values in engineering units at the current instant.
  Map<String, double> sample() => sampleAt(conditions());

  /// Channel values for [now].
  Map<String, double> sampleAt(EngineConditions now) {
    final t = now.seconds;
    final load = now.map / 100;
    final ego = 100 + 4 * math.sin(t * 1.1);
    final warmup = now.coolant < 70 ? 100 + (70 - now.coolant) * 0.8 : 100.0;

    return {
      ...housekeeping(now),
      'rpm': now.rpm,
      'map': now.map,
      'tps': now.throttle,
      // Temperatures go on the wire offset by 40 so they can be negative in a
      // single unsigned byte. The definition derives `coolant` and `iat` from
      // these by expression, so emitting the raw channels is what the ECU
      // actually does - and it exercises that derivation.
      'coolantRaw': now.coolant + 40,
      'iatRaw': now.iat + 40,
      'batteryVoltage': now.battery,
      // Rich under load, lean on overrun, closed-loop wobble at cruise.
      'afr': now.overrun
          ? 18.5
          : (now.throttle > 70 ? 12.4 : 14.7 + 0.5 * math.sin(t * 3)),
      'advance': now.overrun ? 30 : (14 + now.rpm / 400 - load * 9),
      'VE1': 42 + load * 48,
      'veCurr': 42 + load * 48,
      'pulseWidth': now.overrun ? 0 : (1.2 + load * 7.5),
      'dwell': 3.1,
      // Transmitted by the ECU, and several computed channels divide by it -
      // dutyCycle reads as unavailable if it is left at zero.
      'nSquirts': 2,
      'egoCorrection': ego,
      'warmupEnrich': warmup,
      // The product of every correction applied, as the firmware reports it.
      'gammaEnrich': warmup * ego / 100,
      'afrTarget': 14.7,
      'dutyCycle': now.overrun ? 0 : math.min(95, load * now.rpm / 90),
      'fuelLoad': now.map,
      'ignLoad': now.map,
    };
  }

  /// Channels any running ECU reports whatever its tune: its clock, its own
  /// health, rates of change, and the corrections that sit at 100% on an
  /// engine at sea level with the battery charging.
  ///
  /// Without these a gauge for, say, loop rate reads whatever happens to be in
  /// that part of the block - and a real ECU never sends filler.
  Map<String, double> housekeeping(EngineConditions now) {
    final t = now.seconds;
    // Rates of change, taken over the last tenth of a second.
    const step = 0.1;
    final before = conditionsAt(math.max(0, t - step));
    final span = t - before.seconds;
    double rate(double current, double previous) =>
        span <= 0 ? 0 : (current - previous) / span;

    return {
      'secl': (t.floor() % 256).toDouble(),
      // A busy main loop runs slower at high revs, where interrupts eat it.
      'loopsPerSecond': 3200 - now.rpm * 0.12 + 40 * math.sin(t * 0.7),
      'freeRAM': 1438,
      'baro': 101,
      'syncLossCounter': 0,
      'batCorrection': 100,
      'airCorrection': 100,
      'baroCorrection': 100,
      'accelEnrich': 100,
      'ASECurr': 100,
      'TPSdot': now.throttleRate,
      'rpmDOT': rate(now.rpm, before.rpm),
      'MAPdot': rate(now.map, before.map),
      'tpsADC': 28 + now.throttle * 1.9,
      'dwellActual': 3.1,
    };
  }

  /// Boolean status flags at the current instant.
  Map<String, bool> flags() => flagsAt(conditions());

  /// Boolean status flags for [now].
  Map<String, bool> flagsAt(EngineConditions now) => {
        'crank': now.cranking,
        'running': now.rpm > 300,
        'ase': now.seconds < 12,
        'warmup': now.coolant < 70,
        'DFCOOn': now.overrun,
        'sync': now.rpm > 200,
      };

  double _rpmFor(double phase, double throttle, double t) {
    if (t < 1.2) return 220 + 60 * math.sin(t * 18); // cranking
    if (phase < 0.25) return 850 + 45 * math.sin(t * 4); // idle hunt
    if (phase < 0.45) {
      // Pull to redline - crosses the warning and danger thresholds.
      return 900 + ((phase - 0.25) / 0.20) * 6400;
    }
    if (phase < 0.75) return 3200 + 400 * math.sin(t * 0.8); // cruise
    // Overrun back down to idle.
    return math.max(850, 3200 - ((phase - 0.75) / 0.25) * 2400);
  }
}
