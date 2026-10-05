import 'dart:math' as math;

/// A pretend engine, for showing off how live data moves without an ECU: the
/// FoxTune website's scripted drive - idle, a pull to redline, a
/// closed-throttle overrun, a cruise, and back to idle - over and over.
///
/// Illustration only. Nothing in it is meant to be a plausible tune; the
/// simulator in `foxtune_protocol` is the engine to test against.
typedef DemoEngine = ({
  double rpm,
  double map,
  double afr,
  double tps,

  /// Deceleration fuel cut: a closed throttle above idle.
  bool dfco,
});

/// [seconds, rpm, map kPa, afr, tps %], as on the website.
const _drive = <List<double>>[
  [0, 850, 33, 14.7, 2],
  [2.2, 880, 34, 14.6, 2],
  [3.0, 1600, 88, 13.1, 85],
  [6.0, 6550, 98, 12.6, 100],
  [6.6, 5200, 24, 19.5, 0],
  [8.6, 2900, 23, 19.8, 0],
  [9.6, 2600, 50, 14.7, 18],
  [12.8, 2950, 57, 14.7, 22],
  [14.4, 900, 34, 14.6, 2],
  [16, 850, 33, 14.7, 2],
];

/// How long the drive takes before it starts over.
final demoDriveLength = _drive.last.first;

/// The engine [seconds] into the drive.
DemoEngine demoDriveAt(double seconds) {
  final length = demoDriveLength;
  final t = ((seconds % length) + length) % length;
  var k = 0;
  while (k < _drive.length - 2 && t > _drive[k + 1][0]) {
    k++;
  }
  final a = _drive[k];
  final b = _drive[k + 1];
  final f = _smooth((t - a[0]) / (b[0] - a[0]));
  double mix(int n) => a[n] + (b[n] - a[n]) * f;

  final rpm = mix(1) + 14 * math.sin(seconds * 9.1);
  final tps = math.max(0.0, mix(4));
  return (
    rpm: rpm,
    map: mix(2) + 0.7 * math.sin(seconds * 6.7),
    afr: mix(3) + 0.08 * math.sin(seconds * 5.3),
    tps: tps,
    dfco: tps < 1 && rpm > 1500,
  );
}

double _smooth(double f) => f * f * (3 - 2 * f);
