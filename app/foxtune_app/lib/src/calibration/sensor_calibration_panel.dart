import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

import '../app_settings/app_settings.dart';
import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../tune/tune_controller.dart';
import 'calibration_curve.dart';

/// The Speeduino release a signature names - `202501` for
/// `speeduino 202501` or `speeduino 202504-dev` - or `null` for one that
/// names none.
int? speeduinoRelease(String signature) {
  final match = RegExp(r'^speeduino\s+(\d{6})')
      .firstMatch(signature.trim().toLowerCase());
  return match == null ? null : int.parse(match.group(1)!);
}

/// Speeduino's number for its O2 calibration table.
const _o2Table = 2;

/// Makes one of the definition's sensor calibrations and sends it to the
/// ECU: Speeduino's coolant and air temperature tables, and its O2 table.
///
/// TunerStudio makes these with wizards of its own. The definition says only
/// what they can be made from - the thermistors and sensor formulas it
/// offers, in `[ReferenceTables]` - so the panel is built from that, and the
/// table from what the tuner picks.
///
/// Sending is for a Speeduino in write mode, confirmed first: the ECU saves
/// a calibration the moment it arrives, with no burn to hold it back. It is
/// then checked against the CRC-32 the ECU keeps of what it saved - the same
/// checksum that lets the panel say which of its choices the ECU has now.
class SensorCalibrationPanel extends ConsumerStatefulWidget {
  const SensorCalibrationPanel({
    super.key,
    required this.reference,
    required this.connection,
  });

  final IniReferenceTable reference;
  final EcuConnected connection;

  @override
  ConsumerState<SensorCalibrationPanel> createState() =>
      _SensorCalibrationPanelState();
}

class _SensorCalibrationPanelState
    extends ConsumerState<SensorCalibrationPanel> {
  IniReferenceTable get _reference => widget.reference;

  /// Whether this is made from a thermistor, rather than from a formula.
  bool get _isThermistor =>
      _reference.thermistors.isNotEmpty &&
      _reference.generatorOf('thermGenerator') != null;

  bool get _isSpeeduino =>
      widget.connection.identification.family == EcuFamily.speeduino;

  late int _target = _reference.targets.firstOrNull?.id ?? 0;

  /// Whatever was last chosen or typed, until [_ecuChoice] may replace it.
  bool _touched = false;

  // A thermistor: a preset by name, or [_ownValues] once one is typed in.
  static const _ownValues = '';
  String _thermistor = _ownValues;
  final _bias = TextEditingController();
  final _temperatures = List.generate(3, (_) => TextEditingController());
  final _resistances = List.generate(3, (_) => TextEditingController());

  /// The scale the temperature fields were filled in.
  late TemperatureUnit _fieldUnit;

  // A formula: an index into the definition's solutions.
  int? _solution;
  final _linear = List.generate(4, (_) => TextEditingController());

  /// The CRC-32 the ECU keeps of each table, as read; and which of the
  /// choices here it matches, if any.
  final _ecuCrc = <int, int>{};
  final _ecuChoice = <int, String?>{};
  final _checking = <int>{};

  bool _sending = false;
  ({bool ok, String text})? _result;

  // The table as last made, and what it was made from: remade only when
  // that changes, not on every live sample the screen rebuilds for.
  String? _madeFrom;
  ({SensorCalibration? table, String? problem}) _made = (
    table: null,
    problem: null,
  );
  int? _madeCrc;
  ({SensorCalibration table, TemperatureUnit unit, List<double> values})?
  _curve;

  List<IniCalibrationSolution> get _solutions => [
    for (final s in _reference.solutions)
      if (s.label.trim().isNotEmpty) s,
  ];

  @override
  void initState() {
    super.initState();
    _fieldUnit = ref.read(temperatureUnitProvider);
    if (_isThermistor) {
      _chooseThermistor(_reference.thermistors.first.name);
    } else {
      final first = _solutions.indexWhere(_usable);
      if (first >= 0) _chooseSolution(first);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _readEcu(_target));
  }

  @override
  void dispose() {
    for (final c in [_bias, ..._temperatures, ..._resistances, ..._linear]) {
      c.dispose();
    }
    super.dispose();
  }

  // --- Choosing -------------------------------------------------------------

  void _chooseThermistor(String name) {
    final thermistor = _reference.thermistors.firstWhere((t) => t.name == name);
    _thermistor = name;
    _bias.text = _number(thermistor.biasOhms);
    for (var i = 0; i < 3; i++) {
      final point = thermistor.points[i];
      _temperatures[i].text = _number(
        _fieldUnit.fromCelsius(point.celsius),
        places: 1,
      );
      _resistances[i].text = _number(point.ohms);
    }
  }

  void _chooseSolution(int index) {
    _solution = index;
    final solution = _solutions[index];
    final line = solution.generator == null
        ? null
        : _reference.generatorOf(solution.generator!);
    if (line != null && line.type == 'linearGenerator') {
      final values = [line.xLow, line.yLow, line.xHigh, line.yHigh];
      for (var i = 0; i < 4; i++) {
        _linear[i].text = values[i] == null ? '' : _number(values[i]!);
      }
    }
  }

  bool _usable(IniCalibrationSolution solution) {
    if (solution.generator == 'linearGenerator') {
      return _reference.generatorOf('linearGenerator') != null;
    }
    final expression = solution.expression;
    return expression != null && SensorCalibration.canUse(expression);
  }

  // --- Making ---------------------------------------------------------------

  ({SensorCalibration? table, String? problem}) _make() {
    double? read(TextEditingController c) =>
        double.tryParse(c.text.trim().replaceAll(',', '.'));
    try {
      if (_isThermistor) {
        final bias = read(_bias);
        final temperatures = _temperatures.map(read).toList();
        final resistances = _resistances.map(read).toList();
        if (bias == null ||
            temperatures.contains(null) ||
            resistances.contains(null)) {
          return (
            table: null,
            problem: 'Fill in the bias resistor and all three points.',
          );
        }
        if (bias <= 0) {
          return (table: null, problem: 'The bias resistor must be above 0.');
        }
        final curve = ThermistorCurve.fit([
          for (var i = 0; i < 3; i++)
            (celsius: _toCelsius(temperatures[i]!), ohms: resistances[i]!),
        ]);
        return (
          table: SensorCalibration.thermistor(
            _reference,
            target: _target,
            biasOhms: bias,
            curve: curve,
          ),
          problem: null,
        );
      }

      final index = _solution;
      if (index == null) {
        return (table: null, problem: 'Choose a sensor.');
      }
      final solution = _solutions[index];
      if (solution.generator == 'linearGenerator') {
        final values = _linear.map(read).toList();
        if (values.contains(null)) {
          return (table: null, problem: 'Fill in both points.');
        }
        return (
          table: SensorCalibration.linear(
            _reference,
            target: _target,
            voltsLow: values[0]!,
            valueLow: values[1]!,
            voltsHigh: values[2]!,
            valueHigh: values[3]!,
          ),
          problem: null,
        );
      }
      if (!_usable(solution)) {
        return (
          table: null,
          problem:
              'FoxTune cannot make this one yet: it loads the sensor\'s '
              'table from an .inc file.',
        );
      }
      return (
        table: SensorCalibration.formula(
          _reference,
          target: _target,
          expression: solution.expression!,
        ),
        problem: null,
      );
    } on ArgumentError catch (error) {
      return (table: null, problem: '${error.message}');
    }
  }

  /// Every choice the panel offers, made for [target], by name - to tell
  /// which one the ECU has.
  Map<String, SensorCalibration> _presets(int target) {
    final presets = <String, SensorCalibration>{};
    if (_isThermistor) {
      for (final thermistor in _reference.thermistors) {
        try {
          presets[thermistor.name] = SensorCalibration.thermistor(
            _reference,
            target: target,
            biasOhms: thermistor.biasOhms,
            curve: ThermistorCurve.fit(thermistor.points),
          );
        } on ArgumentError {
          continue;
        }
      }
      return presets;
    }
    final line = _reference.generatorOf('linearGenerator');
    for (final solution in _solutions) {
      if (!_usable(solution)) continue;
      if (solution.generator == 'linearGenerator') {
        if (line?.xLow case final xLow?) {
          presets[solution.label] = SensorCalibration.linear(
            _reference,
            target: target,
            voltsLow: xLow,
            valueLow: line!.yLow ?? 0,
            voltsHigh: line.xHigh ?? 5,
            valueHigh: line.yHigh ?? 0,
          );
        }
        continue;
      }
      presets[solution.label] = SensorCalibration.formula(
        _reference,
        target: target,
        expression: solution.expression!,
      );
    }
    return presets;
  }

  // --- Talking to the ECU ---------------------------------------------------

  /// Whether the ECU's checksum of [target] can be believed.
  ///
  /// Speeduino before 202501 worked out its O2 table's checksum with state it
  /// shared with the serial link, which every reply reset.
  bool _checksumTrusted(int target) =>
      target != _o2Table ||
      (speeduinoRelease(widget.connection.identification.signature) ?? 0) >=
          202501;

  Future<void> _readEcu(int target) async {
    final client = ref.read(connectionProvider.notifier).client;
    if (!_isSpeeduino || client == null || !_checksumTrusted(target)) return;
    setState(() => _checking.add(target));
    try {
      final crc = await client.sensorTableCrc(target);
      if (!mounted) return;
      final match = _presets(target).entries
          .where((e) => e.value.crc == crc)
          .map((e) => e.key)
          .firstOrNull;
      setState(() {
        _ecuCrc[target] = crc;
        _ecuChoice[target] = match;
        // Start from what the ECU has, until the tuner picks something.
        if (!_touched && match != null && target == _target) {
          if (_isThermistor) {
            _chooseThermistor(match);
          } else {
            _chooseSolution(_solutions.indexWhere((s) => s.label == match));
          }
        }
      });
    } on Object {
      // Nothing is lost: the panel just cannot say what is there now.
    } finally {
      if (mounted) setState(() => _checking.remove(target));
    }
  }

  Future<void> _send(SensorCalibration table) async {
    final target = _reference.targets.firstWhere((t) => t.id == table.target);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _SendDialog(what: target.label),
    );
    if (confirmed != true || !mounted) return;
    final client = ref.read(connectionProvider.notifier).client;
    if (client == null) return;

    setState(() {
      _sending = true;
      _result = null;
    });
    ({bool ok, String text}) result;
    try {
      await client.writeSensorTable(
        table.target,
        table.encode(),
        chunkSize:
            widget.connection.definition?.referenceTables?.blockingFactor ??
            256,
      );
      if (!_checksumTrusted(table.target)) {
        result = (
          ok: true,
          text:
              'Sent. This firmware keeps no usable checksum of this table, '
              'so it could not be checked.',
        );
      } else {
        final crc = await client.sensorTableCrc(table.target);
        _ecuCrc[table.target] = crc;
        final matches = crc == table.crc;
        _ecuChoice[table.target] = matches ? _choiceLabel() : null;
        result = matches
            ? (
                ok: true,
                text:
                    'Sent and saved: the ECU\'s checksum of what it saved '
                    'matches.',
              )
            : (
                ok: false,
                text:
                    'The ECU\'s checksum of what it saved does not match what '
                    'was sent. Send it again.',
              );
      }
    } on Object catch (error) {
      result = (ok: false, text: 'Not sent: $error');
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
      _result = result;
    });
  }

  /// What the table being made is called, if it is one of the choices.
  String? _choiceLabel() => _isThermistor
      ? (_thermistor == _ownValues ? null : _thermistor)
      : (_solution == null ? null : _solutions[_solution!].label);

  void _remake() {
    final from = [
      _target,
      _thermistor,
      _solution,
      for (final c in [_bias, ..._temperatures, ..._resistances, ..._linear])
        c.text,
    ].join('\u0001');
    if (from == _madeFrom) return;
    _madeFrom = from;
    _made = _make();
    _madeCrc = _made.table?.crc;
  }

  /// [table]'s values in the scale FoxTune shows, kept while neither
  /// changes so the curve is not redrawn for nothing.
  List<double> _curveValues(SensorCalibration table, TemperatureUnit unit) {
    final curve = _curve;
    if (curve != null && identical(curve.table, table) && curve.unit == unit) {
      return curve.values;
    }
    final values = [for (final v in table.values) _shown(v, unit)];
    _curve = (table: table, unit: unit, values: values);
    return values;
  }

  // --- Units ----------------------------------------------------------------

  double _toCelsius(double value) =>
      _fieldUnit == TemperatureUnit.celsius ? value : (value - 32) / 1.8;

  /// A value as sent - degrees Fahrenheit, for a temperature table - in the
  /// scale the rest of FoxTune shows.
  double _shown(double value, TemperatureUnit unit) =>
      _isThermistor && unit == TemperatureUnit.celsius
      ? (value - 32) / 1.8
      : value;

  String _units(TemperatureUnit unit) => _isThermistor
      ? unit.symbol
      : _reference.generatorOf('linearGenerator')?.yUnits ?? '';

  static String _number(double value, {int places = 3}) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    var text = value.toStringAsFixed(places);
    while (text.endsWith('0')) {
      text = text.substring(0, text.length - 1);
    }
    return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
  }

  // --- Building -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = ref.watch(temperatureUnitProvider);
    final permission = ref.watch(writePermissionProvider);
    _remake();
    final made = _made;
    final table = made.table;

    final String? cannotSend = !_isSpeeduino
        ? 'FoxTune sends sensor calibrations only to a Speeduino: another '
              'ECU lays the command out differently, and it has not been '
              'tried.'
        : !permission.allowed
        ? permission.reason ?? 'Writing is not allowed.'
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(_title(_reference.label), style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          _isThermistor
              ? 'Makes the table the ECU turns this sensor\'s reading into a '
                    'temperature with, from three points of the sensor\'s '
                    'resistance, and sends it.'
              : 'Makes the table the ECU turns the O2 sensor\'s voltage into '
                    'an air-fuel ratio with, from the sensor\'s own formula, '
                    'and sends it.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        if (_reference.targets.length > 1) ...[
          _Labelled(
            label: 'Sensor',
            child: DropdownButtonFormField<int>(
              key: ValueKey(('target', _target)),
              initialValue: _target,
              isExpanded: true,
              decoration: _fieldDecoration(),
              items: [
                for (final target in _reference.targets)
                  DropdownMenuItem(
                    value: target.id,
                    child: Text(target.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _sending
                  ? null
                  : (id) {
                      if (id == null || id == _target) return;
                      setState(() {
                        _target = id;
                        _result = null;
                      });
                      if (!_ecuCrc.containsKey(id)) _readEcu(id);
                    },
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (_isThermistor) ..._thermistorFields() else ..._formulaFields(),
        const SizedBox(height: 16),
        if (table != null) ...[
          CalibrationCurve(
            values: _curveValues(table, unit),
            fallbacks: table.fallbacks,
            units: _units(unit),
          ),
          const SizedBox(height: 8),
          if (_fallbackNote(table, unit) case final note?)
            Text(note, style: theme.textTheme.bodySmall),
        ] else if (made.problem case final problem?)
          Text(
            problem,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: StatusPalette.critical,
            ),
          ),
        const SizedBox(height: 16),
        _OnEcu(
          text: _onEcuText(),
          matches: _madeCrc != null && _ecuCrc[_target] == _madeCrc,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: table == null || cannotSend != null || _sending
                  ? null
                  : () => _send(table),
              icon: _sending
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload),
              label: Text(_sending ? 'Sending...' : 'Send to ECU'),
            ),
            if (cannotSend != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 15),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(cannotSend, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
          ],
        ),
        if (_result case final result?) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                result.ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 18,
                color: result.ok ? StatusPalette.good : StatusPalette.critical,
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(result.text)),
            ],
          ),
        ],
        if (_reference.helpUrl case final url?) ...[
          const SizedBox(height: 16),
          SelectableText(
            url,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _thermistorFields() {
    final degrees = _fieldUnit.symbol;
    void edited() => setState(() {
      _touched = true;
      _thermistor = _ownValues;
      _result = null;
    });

    return [
      _Labelled(
        label: 'Thermistor',
        child: DropdownButtonFormField<String>(
          key: ValueKey(('thermistor', _thermistor)),
          initialValue: _thermistor,
          isExpanded: true,
          decoration: _fieldDecoration(),
          items: [
            for (final thermistor in _reference.thermistors)
              DropdownMenuItem(
                value: thermistor.name,
                child: Text(thermistor.name, overflow: TextOverflow.ellipsis),
              ),
            const DropdownMenuItem(
              value: _ownValues,
              child: Text('My own values'),
            ),
          ],
          onChanged: _sending
              ? null
              : (name) => setState(() {
                  _touched = true;
                  _result = null;
                  if (name == null || name == _ownValues) {
                    _thermistor = _ownValues;
                  } else {
                    _chooseThermistor(name);
                  }
                }),
        ),
      ),
      const SizedBox(height: 10),
      _Labelled(
        label: 'Bias resistor',
        child: _NumberField(
          controller: _bias,
          suffix: 'Ω',
          enabled: !_sending,
          onChanged: edited,
        ),
      ),
      for (var i = 0; i < 3; i++) ...[
        const SizedBox(height: 10),
        _Labelled(
          label: 'Point ${i + 1}',
          child: Row(
            children: [
              Expanded(
                child: _NumberField(
                  controller: _temperatures[i],
                  suffix: degrees,
                  enabled: !_sending,
                  onChanged: edited,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _NumberField(
                  controller: _resistances[i],
                  suffix: 'Ω',
                  enabled: !_sending,
                  onChanged: edited,
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  List<Widget> _formulaFields() {
    final solutions = _solutions;
    final index = _solution;
    final linear =
        index != null && solutions[index].generator == 'linearGenerator';
    final line = _reference.generatorOf('linearGenerator');
    void edited() => setState(() {
      _touched = true;
      _result = null;
    });

    return [
      _Labelled(
        label: _reference.solutionsLabel ?? 'Sensor',
        child: DropdownButtonFormField<int>(
          key: ValueKey(('solution', index)),
          initialValue: index,
          isExpanded: true,
          decoration: _fieldDecoration(),
          items: [
            for (var i = 0; i < solutions.length; i++)
              DropdownMenuItem(
                value: i,
                enabled: _usable(solutions[i]),
                child: Text(
                  _usable(solutions[i])
                      ? solutions[i].label
                      : '${solutions[i].label} (needs an .inc file)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _sending
              ? null
              : (i) => setState(() {
                  if (i == null) return;
                  _touched = true;
                  _result = null;
                  _chooseSolution(i);
                }),
        ),
      ),
      if (linear)
        for (final (row, name) in const [(0, 'Low point'), (2, 'High point')])
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: _Labelled(
              label: name,
              child: Row(
                children: [
                  Expanded(
                    child: _NumberField(
                      controller: _linear[row],
                      suffix: 'V',
                      enabled: !_sending,
                      onChanged: edited,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _NumberField(
                      controller: _linear[row + 1],
                      suffix: line?.yUnits ?? '',
                      enabled: !_sending,
                      onChanged: edited,
                    ),
                  ),
                ],
              ),
            ),
          ),
    ];
  }

  String? _fallbackNote(SensorCalibration table, TemperatureUnit unit) {
    if (table.fallbacks.isEmpty) return null;
    final limits = _reference.limits[table.target];
    final units = _units(unit);
    String shown(double v) => '${_number(_shown(v, unit), places: 1)} $units';
    final steps = table.fallbacks.length;
    if (limits == null) {
      return '$steps of ${table.values.length} steps could not be worked out, '
          'and read 0.';
    }
    return '$steps of ${table.values.length} steps fall outside '
        '${shown(limits.min)} to ${shown(limits.max)}, and read '
        '${shown(limits.fallback)} instead: what the ECU takes an open or '
        'shorted sensor to be.';
  }

  String? _onEcuText() {
    if (!_isSpeeduino) return null;
    if (!_checksumTrusted(_target)) {
      return 'This firmware keeps no usable checksum of its O2 table, so '
          'which one it has cannot be told.';
    }
    if (_checking.contains(_target)) return 'Checking what the ECU has...';
    final crc = _ecuCrc[_target];
    if (crc == null) return null;
    final choice = _ecuChoice[_target];
    if (crc == _madeCrc) {
      return choice == null
          ? 'On the ECU now: the table shown here.'
          : 'On the ECU now: $choice, as shown here.';
    }
    return choice == null
        ? 'On the ECU now: a table none of these choices makes - made '
              'elsewhere, or from values typed in.'
        : 'On the ECU now: $choice.';
  }

  static InputDecoration _fieldDecoration() => const InputDecoration(
    border: OutlineInputBorder(),
    isDense: true,
    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
  );

  /// "Calibrate Thermistor Tables." without its trailing dots.
  static String _title(String label) =>
      label.trim().replaceFirst(RegExp(r'\.+$'), '');
}

/// A field with its label beside it, or above it where a phone has no room
/// for both.
class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < 480
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              child,
            ],
          )
        : Row(
            children: [
              SizedBox(width: 130, child: Text(label)),
              const SizedBox(width: 8),
              Expanded(child: child),
            ],
          ),
  );
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.suffix,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String suffix;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    keyboardType: const TextInputType.numberWithOptions(
      signed: true,
      decimal: true,
    ),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.,]'))],
    decoration: InputDecoration(
      border: const OutlineInputBorder(),
      isDense: true,
      suffixText: suffix,
    ),
    onChanged: (_) => onChanged(),
  );
}

/// What the ECU has now, where that can be told.
class _OnEcu extends StatelessWidget {
  const _OnEcu({required this.text, required this.matches});

  final String? text;

  /// Whether it is what the panel would send.
  final bool matches;

  @override
  Widget build(BuildContext context) {
    final text = this.text;
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          matches ? Icons.check : Icons.memory,
          size: 16,
          color: matches ? StatusPalette.good : theme.colorScheme.outline,
        ),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}

/// Confirmation before a calibration goes to the ECU, where it is saved at
/// once.
class _SendDialog extends StatelessWidget {
  const _SendDialog({required this.what});

  /// The sensor, as the definition names it.
  final String what;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: Icon(Icons.warning_amber_rounded, color: StatusPalette.warning),
    title: Text('Send the calibration for the $what?'),
    content: const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'The ECU saves it the moment it arrives: there is no burn step, '
          'and nothing to undo it with but sending another.',
        ),
        SizedBox(height: 12),
        Text('Do this with the engine off: the ECU stops to save it.'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Send'),
      ),
    ],
  );
}
