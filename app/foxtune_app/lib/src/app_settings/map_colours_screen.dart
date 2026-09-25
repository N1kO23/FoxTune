import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/dashboard_editor.dart' show confirm;
import '../window/window_app_bar.dart';
import 'app_settings.dart';
import 'colour_picker.dart';
import 'map_colours.dart';

/// Where the colours of the maps are chosen: a gradient of as many colours as
/// wanted, from the presets FoxTune has or ones saved here.
///
/// Every change shows at once on the sample, and is saved as it is made - a
/// drag once it is let go.
class MapColoursScreen extends ConsumerStatefulWidget {
  const MapColoursScreen({super.key});

  /// Opens it over [context].
  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const MapColoursScreen()));

  @override
  ConsumerState<MapColoursScreen> createState() => _MapColoursScreenState();
}

/// A colour of the gradient being edited, known by [id] however it moves.
class _Stop {
  _Stop(this.id, this.position, this.color);

  final int id;
  double position;
  Color color;
}

class _MapColoursScreenState extends ConsumerState<MapColoursScreen> {
  /// What a gradient is called once it has been changed, until saved.
  static const edited = 'Custom';

  late String _name;
  late List<_Stop> _stops;
  late int _selected;
  var _nextId = 0;

  @override
  void initState() {
    super.initState();
    _load(ref.read(appSettingsProvider).mapGradient);
  }

  void _load(MapGradient gradient) {
    _name = gradient.name;
    _stops = [
      for (final stop in gradient.stops)
        _Stop(_nextId++, stop.position, stop.color),
    ];
    _selected = _stops.first.id;
  }

  MapGradient get _draft {
    final sorted = [..._stops]
      ..sort((a, b) => a.position.compareTo(b.position));
    return MapGradient(_name, [
      for (final stop in sorted) GradientStop(stop.position, stop.color),
    ]);
  }

  _Stop get _selectedStop => _stops.firstWhere((s) => s.id == _selected);

  void _save() => ref
      .read(appSettingsProvider.notifier)
      .update((s) => s.copyWith(mapGradient: _draft));

  /// Changes the gradient - shown at once, and saved unless it is [done]
  /// later, as a drag is.
  void _edit(VoidCallback change, {bool done = true}) {
    setState(() {
      change();
      _name = edited;
    });
    if (done) _save();
  }

  void _choose(MapGradient gradient) {
    setState(() => _load(gradient));
    _save();
  }

  void _add(double position) => _edit(() {
    final stop = _Stop(_nextId++, position, _draft.colorAt(position));
    _stops.add(stop);
    _selected = stop.id;
  });

  void _removeSelected() => _edit(() {
    _stops.removeWhere((s) => s.id == _selected);
    _selected = _stops.first.id;
  });

  void _reverse() => _edit(() {
    for (final stop in _stops) {
      stop.position = 1 - stop.position;
    }
  });

  /// Asks for a name, and keeps the gradient as a preset under it.
  Future<void> _saveAsPreset() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: _name == edited ? '' : _name),
    );
    if (name == null || !mounted) return;
    if (builtInGradients.any((g) => g.name == name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"$name" is a built-in preset. Choose another.'),
        ),
      );
      return;
    }
    final saved = ref.read(appSettingsProvider).savedGradients;
    final existing = saved.any((g) => g.name == name);
    if (existing &&
        !await confirm(
          context,
          title: 'Replace "$name"?',
          message: 'A preset of that name is saved already.',
          action: 'Replace',
        )) {
      return;
    }
    setState(() => _name = name);
    final gradient = _draft;
    ref
        .read(appSettingsProvider.notifier)
        .update(
          (s) => s.copyWith(
            mapGradient: gradient,
            savedGradients: [
              for (final g in s.savedGradients)
                if (g.name != name) g,
              gradient,
            ],
          ),
        );
  }

  Future<void> _delete(MapGradient preset) async {
    if (!await confirm(
      context,
      title: 'Delete "${preset.name}"?',
      message: 'The saved preset is removed. The maps keep their colours.',
      action: 'Delete',
    )) {
      return;
    }
    ref
        .read(appSettingsProvider.notifier)
        .update(
          (s) => s.copyWith(
            savedGradients: [
              for (final g in s.savedGradients)
                if (g.name != preset.name) g,
            ],
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    final saved = ref.watch(
      appSettingsProvider.select((s) => s.savedGradients),
    );
    final stop = _selectedStop;

    return Scaffold(
      appBar: const WindowAppBar(title: Text('Map colours')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    "How the tables are shaded, from each one's lowest value "
                    'to its highest: on the grid, on the 3D surface, and in '
                    "autotune's coverage. The numbers on it turn black or "
                    'white wherever that reads better.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: SampleMap(gradient: draft),
                ),
                _Heading(draft.name),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: _GradientEditor(
                    gradient: draft,
                    stops: _stops,
                    selected: _selected,
                    onAdd: _add,
                    onSelect: (id) => setState(() => _selected = id),
                    onMove: (id, position) => _edit(
                      () => _stops.firstWhere((s) => s.id == id).position =
                          position,
                      done: false,
                    ),
                    onMoveEnd: _save,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Text(
                    'Tap the gradient to add a colour; drag one to move it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: ColourPicker(
                    colour: stop.color,
                    onChanged: (colour) =>
                        _edit(() => stop.color = colour, done: false),
                    onChangeEnd: (colour) => _edit(() => stop.color = colour),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _stops.length > 2 ? _removeSelected : null,
                        icon: const Icon(Icons.remove_circle_outline),
                        label: const Text('Remove colour'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _reverse,
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('Reverse'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _saveAsPreset,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save as preset'),
                      ),
                    ],
                  ),
                ),
                const _Heading('Presets'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in builtInGradients)
                        _PresetTile(
                          preset: preset,
                          inUse: preset.sameColoursAs(draft),
                          onTap: () => _choose(preset),
                        ),
                    ],
                  ),
                ),
                if (saved.isNotEmpty) ...[
                  const _Heading('Saved'),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in saved)
                          _PresetTile(
                            preset: preset,
                            inUse: preset.sameColoursAs(draft),
                            onTap: () => _choose(preset),
                            onDelete: () => _delete(preset),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// A map of made-up values, shaded with [gradient] - the way to judge one,
/// numbers and all, before a table is open.
class SampleMap extends StatelessWidget {
  const SampleMap({super.key, required this.gradient});

  final MapGradient gradient;

  static const rows = 6;
  static const columns = 12;

  /// A volumetric efficiency table's usual shape: rising with speed, and
  /// more steeply with load.
  static double valueAt(int row, int column) =>
      35 + 60 * (column / (columns - 1)) * (0.45 + 0.55 * row / (rows - 1));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colours = MapColours(gradient);
    final low = valueAt(0, 0);
    final high = valueAt(rows - 1, columns - 1);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        children: [
          // Highest load at the top, as the grid draws it.
          for (var row = rows - 1; row >= 0; row--)
            Row(
              children: [
                for (var column = 0; column < columns; column++)
                  Builder(
                    builder: (context) {
                      final value = valueAt(row, column);
                      final background = colours.on(
                        scheme.surfaceContainerLowest,
                        (value - low) / (high - low),
                      );
                      return Container(
                        width: 44,
                        height: 26,
                        margin: const EdgeInsets.all(1),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: background,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          value.toStringAsFixed(0),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: readableOn(background, scheme.onSurface),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A gradient drawn as a bar, over checks where it is transparent.
class GradientPreview extends StatelessWidget {
  const GradientPreview({
    super.key,
    required this.gradient,
    this.width,
    this.height = 20,
  });

  final MapGradient gradient;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: CustomPaint(painter: _GradientPainter(gradient)),
    ),
  );
}

class _GradientPainter extends CustomPainter {
  _GradientPainter(this.gradient);

  final MapGradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    paintCheckerboard(canvas, rect, square: size.height / 3);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [for (final stop in gradient.stops) stop.color],
          stops: [for (final stop in gradient.stops) stop.position],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GradientPainter old) => old.gradient != gradient;
}

/// The gradient being edited, with a handle under each of its colours.
class _GradientEditor extends StatelessWidget {
  const _GradientEditor({
    required this.gradient,
    required this.stops,
    required this.selected,
    required this.onAdd,
    required this.onSelect,
    required this.onMove,
    required this.onMoveEnd,
  });

  final MapGradient gradient;
  final List<_Stop> stops;
  final int selected;
  final ValueChanged<double> onAdd;
  final ValueChanged<int> onSelect;
  final void Function(int id, double position) onMove;
  final VoidCallback onMoveEnd;

  static const barHeight = 36.0;
  static const handleSize = 24.0;
  static const gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Half a handle spare at each end, so the outermost can be centred on
        // either end of the bar.
        const inset = handleSize / 2;
        final track = constraints.maxWidth - 2 * inset;
        double positionAt(double x) => (x / track).clamp(0.0, 1.0);

        return SizedBox(
          height: barHeight + gap + handleSize,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: inset,
                right: inset,
                top: 0,
                height: barHeight,
                child: Semantics(
                  label: 'Gradient',
                  hint: 'Tap to add a colour',
                  child: GestureDetector(
                    onTapUp: (details) =>
                        onAdd(positionAt(details.localPosition.dx)),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: scheme.outlineVariant),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CustomPaint(
                          painter: _GradientPainter(gradient),
                          size: Size(track, barHeight),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              for (final stop in stops)
                Positioned(
                  left: stop.position * track,
                  top: barHeight + gap,
                  child: GestureDetector(
                    onTap: () => onSelect(stop.id),
                    onHorizontalDragStart: (_) => onSelect(stop.id),
                    onHorizontalDragUpdate: (details) => onMove(
                      stop.id,
                      (stop.position + details.delta.dx / track).clamp(
                        0.0,
                        1.0,
                      ),
                    ),
                    onHorizontalDragEnd: (_) => onMoveEnd(),
                    child: _Handle(
                      color: stop.color,
                      selected: stop.id == selected,
                      label: 'Colour at ${(stop.position * 100).round()}%',
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Where a colour sits on the gradient, and what it is.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.color,
    required this.selected,
    required this.label,
  });

  final Color color;
  final bool selected;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = _GradientEditor.handleSize;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _HandlePainter(
            color: color,
            ring: selected ? scheme.primary : scheme.outline,
            ringWidth: selected ? 3 : 1.5,
          ),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  _HandlePainter({
    required this.color,
    required this.ring,
    required this.ringWidth,
  });

  final Color color;
  final Color ring;
  final double ringWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final circle = Offset.zero & size;
    canvas
      ..save()
      ..clipPath(Path()..addOval(circle));
    paintCheckerboard(canvas, circle, square: size.width / 4);
    canvas
      ..drawRect(circle, Paint()..color = color)
      ..restore()
      ..drawOval(
        circle.deflate(ringWidth / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = ringWidth
          ..color = ring,
      );
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color || old.ring != ring || old.ringWidth != ringWidth;
}

/// A preset to choose, marked while it is the one in use - and, where it was
/// saved here rather than built in, with a way to delete it.
class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.inUse,
    required this.onTap,
    this.onDelete,
  });

  final MapGradient preset;
  final bool inUse;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 160,
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: inUse ? scheme.primary : scheme.outlineVariant,
            width: inUse ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: GradientPreview(gradient: preset, height: 18),
                ),
                SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      if (inUse) ...[
                        Icon(Icons.check, size: 16, color: scheme.primary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          preset.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (onDelete != null)
                        IconButton(
                          tooltip: 'Delete ${preset.name}',
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          onPressed: onDelete,
                          icon: const Icon(Icons.delete_outline),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks what to call a preset.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Save as preset'),
    content: TextField(
      controller: _name,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Name'),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty ? null : _submit,
        child: const Text('Save'),
      ),
    ],
  );
}
