import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';

import '../app_settings/app_settings.dart';
import '../app_settings/colour_picker.dart';
import '../app_settings/map_colours.dart' show hexOf;
import 'bar_gauge.dart';
import 'dashboard_editor.dart' show confirm;
import 'gauge_appearance.dart';
import 'gauge_status.dart';
import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';
import 'meter_gauge.dart';
import 'sample_history.dart';
import 'stat_tile.dart';
import 'time_graph.dart';

/// Every kind of gauge, in the order their settings are shown.
const allGaugeKinds = [
  GaugeStyle.dial,
  GaugeStyle.bar,
  GaugeStyle.digital,
  GaugeStyle.graph,
  GaugeStyle.lamp,
];

/// Edits a [GaugeAppearance]: the settings of the gauges in [kinds], and
/// their colours.
///
/// Given [inherited] - the default a gauge's own look sits over - it edits
/// one gauge's look: every setting can also be left at Default, which
/// follows [inherited]. Without it, it edits the default itself, over
/// [GaugeAppearance.builtIn]; a setting put back to the built-in value is
/// cleared rather than kept, so the default stays empty until it differs.
class GaugeAppearanceEditor extends StatelessWidget {
  const GaugeAppearanceEditor({
    super.key,
    required this.value,
    required this.onChanged,
    required this.kinds,
    this.inherited,
  });

  final GaugeAppearance value;
  final ValueChanged<GaugeAppearance> onChanged;
  final List<GaugeStyle> kinds;
  final GaugeAppearance? inherited;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ownLook = inherited != null;
    // What a setting left unset shows.
    final base = (inherited ?? const GaugeAppearance()).over(
      GaugeAppearance.builtIn,
    );

    Widget choice<T extends Object>(
      String title,
      Map<T, String> choices,
      T? Function(GaugeAppearance look) read,
      GaugeAppearance Function(GaugeAppearance look, T? to) write,
    ) => _ChoiceRow<T>(
      title: title,
      choices: choices,
      own: read(value),
      fallback: read(base)!,
      followsDefault: ownLook,
      onChanged: (to) => onChanged(
        write(
          value,
          !ownLook && to == read(GaugeAppearance.builtIn) ? null : to,
        ),
      ),
    );

    Widget colour(
      String title,
      Color? Function(GaugeAppearance look) read,
      GaugeAppearance Function(GaugeAppearance look, Color? to) write, {
      required Color themed,
    }) => _ColourRow(
      title: title,
      own: read(value),
      inherited: inherited == null ? null : read(inherited!),
      themed: themed,
      followsDefault: ownLook,
      onChanged: (to) => onChanged(write(value, to)),
    );

    Map<T, String> labelled<T extends Enum>(
      List<T> values,
      String Function(T value) label,
    ) => {for (final value in values) value: label(value)};

    Map<bool, String> onOff(String on, String off) => {true: on, false: off};

    final thickness = labelled(Thickness.values, (t) => t.label);
    final alarms = labelled(AlarmMarks.values, (a) => a.label);

    final children = <Widget>[];
    for (final kind in kinds) {
      switch (kind) {
        case GaugeStyle.dial:
          children.addAll([
            const _Heading('Dials'),
            choice(
              'Face',
              labelled(DialFace.values, (f) => f.label),
              (l) => l.dial.face,
              (l, to) => l.copyWith(dial: l.dial.copyWith(face: to)),
            ),
            choice(
              'Sweep',
              {for (final sweep in dialSweeps) sweep: '$sweep°'},
              (l) => l.dial.sweep,
              (l, to) => l.copyWith(dial: l.dial.copyWith(sweep: to)),
            ),
            choice(
              'Thickness',
              thickness,
              (l) => l.dial.thickness,
              (l, to) => l.copyWith(dial: l.dial.copyWith(thickness: to)),
            ),
            choice(
              'Scale',
              labelled(ScaleMarks.values, (s) => s.label),
              (l) => l.dial.scale,
              (l, to) => l.copyWith(dial: l.dial.copyWith(scale: to)),
            ),
            choice(
              'Alarm points',
              alarms,
              (l) => l.dial.alarms,
              (l, to) => l.copyWith(dial: l.dial.copyWith(alarms: to)),
            ),
          ]);
        case GaugeStyle.bar:
          children.addAll([
            const _Heading('Bars'),
            choice(
              'Direction',
              labelled(BarOrientation.values, (o) => o.label),
              (l) => l.bar.orientation,
              (l, to) => l.copyWith(bar: l.bar.copyWith(orientation: to)),
            ),
            choice(
              'Thickness',
              thickness,
              (l) => l.bar.thickness,
              (l, to) => l.copyWith(bar: l.bar.copyWith(thickness: to)),
            ),
            choice(
              'Fill',
              onOff('Blocks', 'Solid'),
              (l) => l.bar.segmented,
              (l, to) => l.copyWith(bar: l.bar.copyWith(segmented: to)),
            ),
            choice(
              'Alarm points',
              alarms,
              (l) => l.bar.alarms,
              (l, to) => l.copyWith(bar: l.bar.copyWith(alarms: to)),
            ),
          ]);
        case GaugeStyle.digital:
          children.addAll([
            const _Heading('Digital readouts'),
            choice(
              'Card',
              onOff('Shown', 'Hidden'),
              (l) => l.readout.framed,
              (l, to) => l.copyWith(readout: l.readout.copyWith(framed: to)),
            ),
            choice(
              'Range bar',
              onOff('Shown', 'Hidden'),
              (l) => l.readout.magnitudeBar,
              (l, to) =>
                  l.copyWith(readout: l.readout.copyWith(magnitudeBar: to)),
            ),
            choice(
              'Number',
              labelled(ValueSize.values, (s) => s.label),
              (l) => l.readout.valueSize,
              (l, to) => l.copyWith(readout: l.readout.copyWith(valueSize: to)),
            ),
          ]);
        case GaugeStyle.graph:
          children.addAll([
            const _Heading('Time graphs'),
            choice(
              'Line',
              thickness,
              (l) => l.graph.thickness,
              (l, to) => l.copyWith(graph: l.graph.copyWith(thickness: to)),
            ),
            choice(
              'Shading',
              onOff('Under the line', 'None'),
              (l) => l.graph.fill,
              (l, to) => l.copyWith(graph: l.graph.copyWith(fill: to)),
            ),
            choice(
              'Alarm points',
              alarms,
              (l) => l.graph.alarms,
              (l, to) => l.copyWith(graph: l.graph.copyWith(alarms: to)),
            ),
          ]);
        case GaugeStyle.lamp:
          children.addAll([
            const _Heading('Lamps'),
            choice(
              'Shape',
              labelled(LampShape.values, (s) => s.label),
              (l) => l.lamp.shape,
              (l, to) => l.copyWith(lamp: l.lamp.copyWith(shape: to)),
            ),
            colour(
              'Lit colour',
              (l) => l.lamp.onColour,
              (l, to) => l.copyWith(lamp: l.lamp.copyWith(onColour: to)),
              themed: StatusPalette.good,
            ),
          ]);
      }
    }

    // A lamp has no reading, alarms or scale to colour.
    final readings = kinds.any((k) => k != GaugeStyle.lamp);
    GaugeAppearance paint(GaugeAppearance l, GaugeColours colours) =>
        l.copyWith(colours: colours);
    children.addAll([
      const _Heading('Colours'),
      Text(
        'A colour left to the theme follows it, light or dark. One chosen '
        'here is used in both. Whatever the colours, an alarm still shows '
        'its icon and word.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      if (readings) ...[
        colour(
          'Normal reading',
          (l) => l.colours.normal,
          (l, to) => paint(l, l.colours.copyWith(normal: to)),
          themed: scheme.onSurface,
        ),
        colour(
          'Warning',
          (l) => l.colours.warning,
          (l, to) => paint(l, l.colours.copyWith(warning: to)),
          themed: StatusPalette.warning,
        ),
        colour(
          'Danger',
          (l) => l.colours.danger,
          (l, to) => paint(l, l.colours.copyWith(danger: to)),
          themed: StatusPalette.critical,
        ),
        colour(
          'Unfilled track',
          (l) => l.colours.track,
          (l, to) => paint(l, l.colours.copyWith(track: to)),
          themed: scheme.surfaceContainerHighest,
        ),
      ],
      colour(
        'Background',
        (l) => l.colours.background,
        (l, to) => paint(l, l.colours.copyWith(background: to)),
        themed: scheme.surfaceContainerLow,
      ),
      colour(
        'Text',
        (l) => l.colours.text,
        (l, to) => paint(l, l.colours.copyWith(text: to)),
        themed: scheme.onSurface,
      ),
      if (readings)
        for (final caution in _cautions(value.over(base).colours, scheme))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  StatusPalette.iconFor(GaugeStatus.warning),
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(caution, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
    ]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// What is worth pointing out about [colours]: states hard to tell apart.
  static List<String> _cautions(GaugeColours colours, ColorScheme scheme) {
    final normal = colours.normal ?? scheme.onSurface;
    final warning = colours.warningColour;
    final danger = colours.dangerColour;
    return [
      if (_close(warning, normal))
        'The warning colour is close to the normal one: a warning will not '
            'stand out by its colour.',
      if (_close(danger, normal))
        'The danger colour is close to the normal one: danger will not stand '
            'out by its colour.',
      if (_close(warning, danger))
        'The warning and danger colours are close: they will be told apart '
            'by their words alone.',
    ];
  }

  static bool _close(Color a, Color b) {
    final dr = a.r - b.r;
    final dg = a.g - b.g;
    final db = a.b - b.b;
    return dr * dr + dg * dg + db * db < 0.04;
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// One setting, chosen from a few [choices].
class _ChoiceRow<T extends Object> extends StatelessWidget {
  const _ChoiceRow({
    required this.title,
    required this.choices,
    required this.own,
    required this.fallback,
    required this.followsDefault,
    required this.onChanged,
  });

  final String title;
  final Map<T, String> choices;

  /// What is set; `null` where nothing is.
  final T? own;

  /// What it is where nothing is set.
  final T fallback;

  /// Whether, left unset, it follows a default - and can be put back to it.
  final bool followsDefault;

  /// Called with the choice made; `null` for Default.
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (followsDefault)
                ChoiceChip(
                  label: Text('Default (${choices[fallback]})'),
                  selected: own == null,
                  onSelected: (_) => onChanged(null),
                ),
              for (final MapEntry(key: value, value: label) in choices.entries)
                ChoiceChip(
                  label: Text(label),
                  selected: followsDefault
                      ? own == value
                      : (own ?? fallback) == value,
                  onSelected: (_) => onChanged(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One colour: the one set, or where it comes from - and a way to choose.
class _ColourRow extends StatelessWidget {
  const _ColourRow({
    required this.title,
    required this.own,
    required this.inherited,
    required this.themed,
    required this.followsDefault,
    required this.onChanged,
  });

  final String title;

  /// The colour set; `null` where none is.
  final Color? own;

  /// The default's colour, for a gauge's own look; `null` where the default
  /// leaves it to the theme.
  final Color? inherited;

  /// The theme's colour, where nothing sets one.
  final Color themed;

  final bool followsDefault;

  /// Called with the colour chosen; `null` to leave it to the default.
  final ValueChanged<Color?> onChanged;

  @override
  Widget build(BuildContext context) {
    final shown = own ?? inherited ?? themed;
    final source = inherited == null ? "the theme's" : hexOf(inherited!);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(switch (own) {
        final set? => hexOf(set),
        null when followsDefault => 'Default ($source)',
        null => "The theme's",
      }),
      trailing: _Swatch(colour: shown),
      onTap: () async {
        final picked = await showDialog<({Color? colour})>(
          context: context,
          builder: (_) => _ColourDialog(
            title: title,
            start: shown,
            resetLabel: own == null
                ? null
                : (followsDefault ? 'Use the default' : "Use the theme's"),
          ),
        );
        if (picked != null) onChanged(picked.colour);
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colour});

  final Color colour;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 28,
    child: ClipOval(
      child: CustomPaint(
        painter: _SwatchPainter(colour),
        foregroundPainter: _RingPainter(Theme.of(context).colorScheme.outline),
      ),
    ),
  );
}

/// A colour on light and dark checks, so a see-through one shows as such.
class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (colour.a < 1) paintCheckerboard(canvas, rect, square: size.width / 4);
    canvas.drawRect(rect, Paint()..color = colour);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.colour != colour;
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.colour);

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
    size.center(Offset.zero),
    size.shortestSide / 2 - 0.5,
    Paint()
      ..style = PaintingStyle.stroke
      ..color = colour,
  );

  @override
  bool shouldRepaint(_RingPainter old) => old.colour != colour;
}

/// Chooses a colour. Returns `(colour: ...)` to use it, `(colour: null)` to
/// give it back to the default, or nothing if cancelled.
class _ColourDialog extends StatefulWidget {
  const _ColourDialog({
    required this.title,
    required this.start,
    required this.resetLabel,
  });

  final String title;
  final Color start;

  /// The button that clears the colour, where there is one to clear.
  final String? resetLabel;

  @override
  State<_ColourDialog> createState() => _ColourDialogState();
}

class _ColourDialogState extends State<_ColourDialog> {
  late Color _colour = widget.start;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 96,
              height: 24,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CustomPaint(painter: _SwatchPainter(_colour)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ColourPicker(
            colour: _colour,
            onChanged: (colour) => setState(() => _colour = colour),
            onChangeEnd: (colour) => setState(() => _colour = colour),
          ),
        ],
      ),
    ),
    actions: [
      if (widget.resetLabel case final label?)
        TextButton(
          onPressed: () => Navigator.of(context).pop((colour: null)),
          child: Text(label),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop((colour: _colour)),
        child: const Text('Done'),
      ),
    ],
  );
}

/// Sample gauges of each of [kinds], drawn in [look] over the built-in one -
/// so a look can be judged before it is on the dashboard.
///
/// The samples are made up, not read from an ECU: one of them is in warning
/// and one in danger, so the alarm colours can be judged too.
class GaugePreview extends StatefulWidget {
  const GaugePreview({super.key, required this.kinds, required this.look});

  final List<GaugeStyle> kinds;
  final GaugeAppearance look;

  @override
  State<GaugePreview> createState() => _GaugePreviewState();
}

class _GaugePreviewState extends State<GaugePreview> {
  static const _rpm = GaugeSpec(
    channel: 'rpm',
    label: 'RPM',
    units: 'rpm',
    min: 0,
    max: 8000,
    warnAbove: 6000,
    dangerAbove: 7000,
  );
  static const _coolant = GaugeSpec(
    channel: 'coolant',
    label: 'Coolant',
    units: '°C',
    min: -40,
    max: 120,
    warnBelow: 20,
    warnAbove: 95,
    dangerAbove: 105,
  );
  static const _battery = GaugeSpec(
    channel: 'battery',
    label: 'Battery',
    units: 'V',
    min: 8,
    max: 16,
    decimals: 1,
    warnBelow: 12,
    dangerBelow: 11,
  );
  static const _boost = GaugeSpec(
    channel: 'boost',
    label: 'Boost',
    units: 'kPa',
    min: 0,
    max: 250,
    warnAbove: 200,
    dangerAbove: 230,
  );

  /// Where the made-up boost trace ends: in danger.
  static const _boostNow = 240.0;

  late final SampleHistory _history = _boostHistory();

  /// Thirty seconds of boost, building in three pulls to [_boostNow].
  static SampleHistory _boostHistory() {
    final definition = IniParser().parse(
      '[OutputChannels]\n'
      'ochBlockSize = 2\n'
      'boost = scalar, U16, 0, "kPa", 1.000, 0.000\n',
    );
    final decoder = RealtimeDecoder(definition.outputChannels);
    final history = SampleHistory();
    final start = DateTime(2026);
    const samples = 300;
    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final kPa =
          100 + (_boostNow - 100) * (0.5 - 0.5 * math.cos(t * 5 * math.pi));
      final block = Uint8List(2);
      ByteData.sublistView(block).setUint16(0, kPa.round(), Endian.little);
      history.add(
        decoder.decode(
          block,
          timestamp: start.add(Duration(milliseconds: i * 100)),
        ),
      );
    }
    return history;
  }

  @override
  void dispose() {
    _history.dispose();
    super.dispose();
  }

  /// [child] laid out at its size on a phone-wide page, as the dashboard
  /// would, and shown at that size.
  Widget _placed(double width, double height, Widget child) => SizedBox(
    width: width,
    height: height,
    child: Padding(padding: const EdgeInsets.all(3), child: child),
  );

  @override
  Widget build(BuildContext context) {
    final look = widget.look.over(GaugeAppearance.builtIn);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final kind in widget.kinds)
            switch (kind) {
              GaugeStyle.dial => _placed(
                160,
                160,
                Center(
                  child: MeterGauge(spec: _rpm, value: 3500, look: look),
                ),
              ),
              GaugeStyle.bar => _placed(
                200,
                48,
                BarGauge(spec: _coolant, value: 98, look: look),
              ),
              GaugeStyle.digital => _placed(
                140,
                84,
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: 134,
                    child: StatTile(spec: _battery, value: 13.8, look: look),
                  ),
                ),
              ),
              GaugeStyle.graph => _placed(
                240,
                120,
                TimeGraph(
                  lanes: const [_boost],
                  history: _history,
                  window: const Duration(seconds: 30),
                  look: look,
                  readings: const {'boost': _boostNow},
                ),
              ),
              GaugeStyle.lamp => SizedBox(
                width: 120,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _placed(
                      120,
                      32,
                      FlagLamp(
                        label: 'Running',
                        on: true,
                        expand: true,
                        look: look,
                      ),
                    ),
                    _placed(
                      120,
                      32,
                      FlagLamp(
                        label: 'Fan',
                        on: false,
                        expand: true,
                        look: look,
                      ),
                    ),
                  ],
                ),
              ),
            },
        ],
      ),
    );
  }
}

/// Opens one gauge's look: its own settings, over the default.
Future<void> showAppearanceSheet(
  BuildContext context, {
  required String pageId,
  required String placementId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.8,
    maxChildSize: 0.95,
    builder: (context, scroll) => _AppearanceSheet(
      pageId: pageId,
      placementId: placementId,
      scroll: scroll,
    ),
  ),
);

/// One gauge's look.
///
/// Reads the gauge back from the layout on every build, so each change shows
/// at once - here and on the page behind - and is saved as it is made.
class _AppearanceSheet extends ConsumerWidget {
  const _AppearanceSheet({
    required this.pageId,
    required this.placementId,
    required this.scroll,
  });

  final String pageId;
  final String placementId;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final placement = ref
        .watch(dashboardLayoutProvider)
        .value
        ?.pageById(pageId)
        ?.items
        .where((i) => i.id == placementId)
        .firstOrNull;
    if (placement == null) return const SizedBox.shrink();
    final global = ref.watch(
      appSettingsProvider.select((s) => s.gaugeAppearance),
    );
    final kind = placement.style;
    final own = placement.appearance;
    final changes = own.changesFor(kind);

    void update(GaugeAppearance next) => ref
        .read(dashboardLayoutProvider.notifier)
        .replaceGauge(pageId, placement.copyWith(appearance: next));

    Future<void> makeDefault() async {
      if (!await confirm(
        context,
        title: 'Make this the default?',
        message:
            'Every ${kind.label.toLowerCase()} that follows the default look '
            "takes on this one's changes, on every page.",
        action: 'Make default',
      )) {
        return;
      }
      ref
          .read(appSettingsProvider.notifier)
          .update(
            (s) => s.copyWith(
              gaugeAppearance: own.only(kind).over(s.gaugeAppearance),
            ),
          );
      // Its changes are the default's now: it follows that again.
      update(own.without(kind));
    }

    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Text('Appearance', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          "What is set here is this gauge's own. What is left at Default "
          'follows the default look, in App settings - including when that '
          'changes.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        GaugePreview(kinds: [kind], look: own.over(global)),
        GaugeAppearanceEditor(
          value: own,
          inherited: global,
          kinds: [kind],
          onChanged: update,
        ),
        const Divider(height: 32),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: changes == 0 ? null : () => update(own.without(kind)),
              child: const Text('Reset to default'),
            ),
            OutlinedButton(
              onPressed: changes == 0 ? null : makeDefault,
              child: const Text('Make this the default'),
            ),
          ],
        ),
      ],
    );
  }
}
