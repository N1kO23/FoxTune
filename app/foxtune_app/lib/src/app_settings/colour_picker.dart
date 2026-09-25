import 'package:flutter/material.dart';

import 'map_colours.dart';

/// Paints light and dark checks over [rect]: what shows through a colour
/// that is partly transparent.
void paintCheckerboard(Canvas canvas, Rect rect, {double square = 6}) {
  canvas.drawRect(rect, Paint()..color = const Color(0xFFFFFFFF));
  final dark = Paint()..color = const Color(0xFFCCCCCC);
  for (var y = 0; y * square < rect.height; y++) {
    for (var x = 0; x * square < rect.width; x++) {
      if ((x + y).isOdd) {
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left + x * square,
            rect.top + y * square,
            square,
            square,
          ).intersect(rect),
          dark,
        );
      }
    }
  }
}

/// A slider's track, painted with the colours it leads through - checked
/// behind, for a track that fades out.
class GradientTrackShape extends RoundedRectSliderTrackShape {
  const GradientTrackShape(this.colours, {this.checkered = false});

  final List<Color> colours;
  final bool checkered;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas
      ..save()
      ..clipRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      );
    if (checkered) paintCheckerboard(canvas, rect, square: rect.height / 2);
    canvas
      ..drawRect(
        rect,
        Paint()..shader = LinearGradient(colors: colours).createShader(rect),
      )
      ..restore();
  }
}

/// Chooses a colour: its hue, saturation, brightness and opacity, each on a
/// slider painted with where it leads; the colour written out in hex; and a
/// few colours to start from.
class ColourPicker extends StatefulWidget {
  const ColourPicker({
    super.key,
    required this.colour,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Color colour;

  /// Called as a slider moves.
  final ValueChanged<Color> onChanged;

  /// Called once a change is complete: a slider let go, a hex colour
  /// entered, a colour picked.
  final ValueChanged<Color> onChangeEnd;

  /// The colours offered to start from: the brand's pink, a spread of hues,
  /// and white, grey and black.
  static const swatches = [
    Color(0xFFFF2E6E),
    Color(0xFFE53935),
    Color(0xFFFB8C00),
    Color(0xFFFDD835),
    Color(0xFF43A047),
    Color(0xFF00897B),
    Color(0xFF1E88E5),
    Color(0xFF3949AB),
    Color(0xFF8E24AA),
    Color(0xFFFFFFFF),
    Color(0xFF808080),
    Color(0xFF000000),
  ];

  @override
  State<ColourPicker> createState() => _ColourPickerState();
}

class _ColourPickerState extends State<ColourPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.colour);
  late final _hex = TextEditingController(text: hexOf(widget.colour));
  String? _hexProblem;

  @override
  void didUpdateWidget(ColourPicker old) {
    super.didUpdateWidget(old);
    // Taken up only when it is another colour altogether - another stop
    // chosen. Otherwise kept as it is: a grey has no hue of its own, and
    // reading one back from it would lose the hue being set.
    if (widget.colour != _hsv.toColor()) {
      _hsv = HSVColor.fromColor(widget.colour);
      _hex.text = hexOf(widget.colour);
      _hexProblem = null;
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor hsv, {required bool done}) {
    setState(() {
      _hsv = hsv;
      _hex.text = hexOf(hsv.toColor());
      _hexProblem = null;
    });
    done ? widget.onChangeEnd(hsv.toColor()) : widget.onChanged(hsv.toColor());
  }

  void _enterHex(String text) {
    final colour = colorFromHex(text);
    if (colour == null) {
      setState(() => _hexProblem = 'Not a colour: #RRGGBB or #RRGGBBAA');
      return;
    }
    _set(HSVColor.fromColor(colour), done: true);
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required List<Color> track,
    required HSVColor Function(double value) apply,
    required String reading,
    bool checkered = false,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              trackShape: GradientTrackShape(track, checkered: checkered),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
              thumbColor: Colors.white,
              overlayColor: theme.colorScheme.onSurface.withValues(alpha: 0.12),
            ),
            child: Slider(
              value: value,
              max: max,
              semanticFormatterCallback: (_) => reading,
              onChanged: (v) => _set(apply(v), done: false),
              onChangeEnd: (v) => _set(apply(v), done: true),
            ),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text(
            reading,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hsv = _hsv;
    final opaque = hsv.withAlpha(1).toColor();
    String percent(double value) => '${(value * 100).round()}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _slider(
          label: 'Hue',
          value: hsv.hue,
          max: 360,
          track: [
            for (var hue = 0.0; hue <= 360; hue += 60)
              HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
          ],
          apply: hsv.withHue,
          reading: '${hsv.hue.round()}°',
        ),
        _slider(
          label: 'Saturation',
          value: hsv.saturation,
          max: 1,
          track: [
            hsv.withAlpha(1).withSaturation(0).toColor(),
            hsv.withAlpha(1).withSaturation(1).toColor(),
          ],
          apply: hsv.withSaturation,
          reading: percent(hsv.saturation),
        ),
        _slider(
          label: 'Brightness',
          value: hsv.value,
          max: 1,
          track: [
            const Color(0xFF000000),
            hsv.withAlpha(1).withValue(1).toColor(),
          ],
          apply: hsv.withValue,
          reading: percent(hsv.value),
        ),
        _slider(
          label: 'Opacity',
          value: hsv.alpha,
          max: 1,
          track: [opaque.withValues(alpha: 0), opaque],
          checkered: true,
          apply: hsv.withAlpha,
          reading: percent(hsv.alpha),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: _hex,
                decoration: InputDecoration(
                  labelText: 'Hex',
                  errorText: _hexProblem,
                  errorMaxLines: 2,
                  isDense: true,
                ),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                onSubmitted: _enterHex,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final swatch in ColourPicker.swatches)
                    _Swatch(
                      colour: swatch,
                      // Its hue, at the opacity already set.
                      onTap: () => _set(
                        HSVColor.fromColor(swatch.withValues(alpha: hsv.alpha)),
                        done: true,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.colour, required this.onTap});

  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: hexOf(colour),
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: colour,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
      ),
    ),
  );
}
