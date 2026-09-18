import 'dart:math' as math;

/// A crude but plausible running engine, for driving a UI without hardware.
///
/// This is not a physical model. It exists so gauges move, the live table
/// cursor travels across cells, and warning thresholds are actually reached -
/// which is what UI work needs and a static block of filler bytes cannot give.
///
/// The cycle is deliberate: idle, a pull to high load, a cruise, then a
/// closed-throttle overrun. That sweep visits the corners of a VE table and
/// crosses the coolant and RPM alarm thresholds.
class EngineSimulation {
  EngineSimulation({this.cycle = const Duration(seconds: 24)});

  /// How long one idle-pull-cruise-overrun cycle takes.
  final Duration cycle;

  final _startedAt = DateTime.now();

  /// Seconds since the simulation began.
  double get elapsedSeconds =>
      DateTime.now().difference(_startedAt).inMilliseconds / 1000;

  /// Channel values in engineering units at the current instant.
  Map<String, double> sample() {
    final t = elapsedSeconds;
    final phase = (t % cycle.inSeconds) / cycle.inSeconds;

    // Throttle profile across the cycle.
    final double throttle;
    if (phase < 0.25) {
      throttle = 0; // idle
    } else if (phase < 0.45) {
      throttle = ((phase - 0.25) / 0.20) * 100; // pull
    } else if (phase < 0.75) {
      throttle = 35 + 10 * math.sin(t * 1.5); // cruise
    } else {
      throttle = 0; // overrun
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
    final onOverrun = closedThrottle && rpm > 1500;

    final iat = 24 + 6 * load + math.sin(t * 0.4);

    return {
      'rpm': rpm,
      'map': map,
      'tps': throttle,
      // Temperatures go on the wire offset by 40 so they can be negative in a
      // single unsigned byte. The definition derives `coolant` and `iat` from
      // these by expression, so emitting the raw channels is what the ECU
      // actually does - and it exercises that derivation.
      'coolantRaw': coolant + 40,
      'iatRaw': iat + 40,
      'batteryVoltage': 13.9 - 0.5 * load,
      // Rich under load, lean on overrun, closed-loop wobble at cruise.
      'afr': onOverrun
          ? 18.5
          : (throttle > 70 ? 12.4 : 14.7 + 0.5 * math.sin(t * 3)),
      'advance': onOverrun ? 30 : (14 + rpm / 400 - load * 9),
      'VE1': 42 + load * 48,
      'pulseWidth': onOverrun ? 0 : (1.2 + load * 7.5),
      'dwell': 3.1,
      // Transmitted by the ECU, and several computed channels divide by it -
      // dutyCycle reads as unavailable if it is left at zero.
      'nSquirts': 2,
      'egoCorrection': 100 + 4 * math.sin(t * 1.1),
      'dutyCycle': onOverrun ? 0 : math.min(95, load * rpm / 90),
      'fuelLoad': map,
      'ignLoad': map,
    };
  }

  /// Boolean status flags at the current instant.
  Map<String, bool> flags() {
    final t = elapsedSeconds;
    final values = sample();
    final rpm = values['rpm']!;

    return {
      // A short crank at the very start of the first cycle only.
      'crank': t < 1.2,
      'running': rpm > 300,
      'ase': t < 12,
      'warmup': (values['coolantRaw']! - 40) < 70,
      'DFCOOn': values['tps']! < 2 && rpm > 1500,
      'sync': rpm > 200,
    };
  }

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
