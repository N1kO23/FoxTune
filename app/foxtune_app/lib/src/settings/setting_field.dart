import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

/// One row of a generated settings dialog: a label and its control.
///
/// The control is chosen from the constant's own declaration - a bitfield
/// becomes a drop-down of its option labels, a scalar a numeric entry with its
/// units and bounds - so nothing about a particular setting is hard-coded here.
class SettingFieldTile extends StatelessWidget {
  const SettingFieldTile({
    super.key,
    required this.label,
    required this.setting,
    required this.enabled,
    required this.onChanged,
    this.readOnly = false,
  });

  /// Text shown beside the control, from the dialog rather than the constant.
  final String label;

  /// The setting being edited.
  final SettingView setting;

  /// Whether the definition's condition and the session's permission allow
  /// editing.
  final bool enabled;

  /// Called after a change lands, so the tune can be marked edited.
  final VoidCallback onChanged;

  /// Whether the definition declared this as display-only.
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editable = enabled && !readOnly;

    final control = readOnly
        ? _ReadOnlyValue(setting: setting)
        : setting.isEnumerated
        ? _EnumControl(
            setting: setting,
            enabled: editable,
            onChanged: onChanged,
          )
        : _NumericControl(
            setting: setting,
            enabled: editable,
            onChanged: onChanged,
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SettingLabel(
              label: label,
              setting: setting,
              enabled: enabled,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 186,
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodyMedium ?? const TextStyle(),
              child: control,
            ),
          ),
        ],
      ),
    );
  }
}

/// A setting's label, with whatever the definition says about it attached.
class SettingLabel extends StatelessWidget {
  const SettingLabel({
    super.key,
    required this.label,
    required this.setting,
    required this.enabled,
  });

  final String label;
  final SettingView setting;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = !enabled;

    return Row(
      children: [
        Flexible(
          child: Text(
            label.isEmpty ? setting.name : label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
            ),
          ),
        ),
        if (setting.help case final help?) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: help,
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 12),
            child: Icon(
              Icons.help_outline,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (setting.requiresPowerCycle) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: 'Takes effect after the ECU is power-cycled.',
            child: Icon(
              Icons.power_settings_new,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
        if (setting.isHostSide) ...[
          const SizedBox(width: 6),
          Tooltip(
            // Worth saying plainly: a tuner who changes one of these and then
            // burns would otherwise expect it to have gone to the ECU.
            message: 'Stored on this computer, not on the ECU.',
            child: Icon(
              Icons.laptop_mac,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _ReadOnlyValue extends StatelessWidget {
  const _ReadOnlyValue({required this.setting});

  final SettingView setting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = setting.displayText;
    return Text(
      text == null ? '--' : '$text ${setting.units}'.trim(),
      style: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _EnumControl extends StatelessWidget {
  const _EnumControl({
    required this.setting,
    required this.enabled,
    required this.onChanged,
  });

  final SettingView setting;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final options = setting.options;
    final selected = setting.optionIndex;

    return DropdownButtonFormField<int>(
      initialValue:
          selected != null && selected >= 0 && selected < options.length
          ? selected
          : null,
      isDense: true,
      isExpanded: true,
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      items: [
        for (var i = 0; i < options.length; i++)
          DropdownMenuItem(
            value: i,
            child: Text(options[i], overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled
          ? (value) {
              if (value == null) return;
              setting.setOptionIndex(value);
              onChanged();
            }
          : null,
    );
  }
}

/// A numeric entry that commits on submit or when focus leaves.
///
/// Committing on every keystroke would fight the tuner: typing "1" on the way
/// to "120" would write 1, which on some settings is a value the ECU acts on
/// immediately.
class _NumericControl extends StatefulWidget {
  const _NumericControl({
    required this.setting,
    required this.enabled,
    required this.onChanged,
  });

  final SettingView setting;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  State<_NumericControl> createState() => _NumericControlState();
}

class _NumericControlState extends State<_NumericControl> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.setting.displayText ?? '',
  );
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final typed = double.tryParse(_controller.text.trim());
    // Writing a value that is already stored would mark the page as changed
    // for nothing, and tabbing through a dialog would ask for a burn.
    if (typed != null && typed != widget.setting.value) {
      widget.setting.setValue(typed);
      widget.onChanged();
    }
    // Whether the entry was accepted, clamped or rejected, the field now
    // shows what is actually stored rather than what was typed.
    _syncFromSetting();
  }

  void _syncFromSetting() {
    final text = widget.setting.displayText ?? '';
    if (_controller.text != text) _controller.text = text;
  }

  @override
  Widget build(BuildContext context) {
    // The stored value can change from elsewhere - another setting's scale,
    // a re-read from the ECU - so the field follows it while not being typed
    // into.
    if (!_focus.hasFocus) _syncFromSetting();

    final bounds = _boundsLabel();

    return TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      textAlign: TextAlign.end,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))],
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 10,
        ),
        suffixText: widget.setting.units.isEmpty ? null : widget.setting.units,
        helperText: bounds,
        helperMaxLines: 1,
      ),
      onSubmitted: (_) => _commit(),
    );
  }

  String? _boundsLabel() {
    final low = widget.setting.low;
    final high = widget.setting.high;
    if (low == null || high == null) return null;
    final decimals = widget.setting.decimals;
    return '${low.toStringAsFixed(decimals)} '
        'to ${high.toStringAsFixed(decimals)}';
  }
}

/// A setting the definition asked to be shown as a slider.
class SettingSliderTile extends StatelessWidget {
  const SettingSliderTile({
    super.key,
    required this.label,
    required this.setting,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final SettingView setting;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final low = setting.low;
    final high = setting.high;
    final value = setting.value;

    // Without declared bounds there is nothing to slide between, so the
    // ordinary numeric entry is the honest fallback.
    if (low == null || high == null || high <= low || value == null) {
      return SettingFieldTile(
        label: label,
        setting: setting,
        enabled: enabled,
        onChanged: onChanged,
      );
    }

    final divisions = ((high - low) / setting.step).round();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SettingLabel(
                  label: label,
                  setting: setting,
                  enabled: enabled,
                ),
              ),
              Text(
                '${setting.displayText ?? '--'} ${setting.units}'.trim(),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          Slider(
            value: value.clamp(low, high),
            min: low,
            max: high,
            divisions: divisions > 0 && divisions <= 1000 ? divisions : null,
            onChanged: enabled
                ? (next) {
                    setting.setValue(next);
                    onChanged();
                  }
                : null,
          ),
        ],
      ),
    );
  }
}
