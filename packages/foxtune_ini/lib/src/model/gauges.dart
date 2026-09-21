import '../data_type.dart';
import 'dialogs.dart';

/// A gauge from `[GaugeConfigurations]`: a channel and how to present it.
///
/// Every number here may be an expression rather than a literal, and the ones
/// that matter most are: the tachometer's range and its warning and danger
/// points are `{rpmhigh}`, `{rpmwarn}` and `{rpmdang}`, which are the values a
/// tuner sets in the Gauge Limits dialog. Keeping them as expressions until
/// they are shown is what makes the gauge follow those settings.
class IniGauge {
  const IniGauge({
    required this.name,
    required this.channel,
    required this.title,
    required this.units,
    required this.lo,
    required this.hi,
    this.titleExpression,
    this.unitsExpression,
    this.loDanger,
    this.loWarning,
    this.hiWarning,
    this.hiDanger,
    this.valueDigits = 0,
    this.labelDigits = 0,
    this.category = '',
  });

  /// Identifier a layout refers to it by, e.g. `tachometer`.
  final String name;

  /// Output channel it shows, e.g. `rpm`.
  final String channel;

  /// Heading, where the definition gives it as text.
  final String title;

  /// Heading as an expression, where the definition computes it instead.
  ///
  /// The auxiliary-input gauges take their titles from user-set aliases this
  /// way (`{ stringValue(AUXin00Alias) }`).
  final String? titleExpression;

  /// Units, where given as text.
  final String units;

  /// Units as an expression, e.g. `{ bitStringValue(idleUnits, iacAlgorithm) }`.
  final String? unitsExpression;

  /// Lower end of the scale.
  final IniScalarValue lo;

  /// Upper end of the scale.
  final IniScalarValue hi;

  /// At or below this the reading is dangerous.
  final IniScalarValue? loDanger;

  /// At or below this the reading is a warning.
  final IniScalarValue? loWarning;

  /// At or above this the reading is a warning.
  final IniScalarValue? hiWarning;

  /// At or above this the reading is dangerous.
  final IniScalarValue? hiDanger;

  /// Decimal places for the value.
  final int valueDigits;

  /// Decimal places for the scale labels.
  final int labelDigits;

  /// The `gaugeCategory` it was declared under, e.g. "Sensor inputs".
  final String category;

  /// A heading fit to show: the title, or the name when the title is computed.
  String get displayTitle => title.isNotEmpty ? title : name;

  @override
  String toString() => 'gauge $name -> $channel ("$title")';
}

/// The `[FrontPage]` section: TunerStudio's default dashboard.
class IniFrontPage {
  const IniFrontPage({this.gauges = const [], this.indicators = const []});

  /// Gauge names in slot order, from `gauge1` upwards.
  final List<String> gauges;

  /// Status indicators in declaration order.
  final List<IniDialogIndicator> indicators;

  @override
  String toString() =>
      'frontPage (${gauges.length} gauges, ${indicators.length} indicators)';
}
