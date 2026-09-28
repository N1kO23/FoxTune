import 'package:foxtune_ini/foxtune_ini.dart';

import '../table_view.dart';

/// What a mixture reading or target is expressed in.
enum MixtureUnits {
  /// 1.0 is stoichiometric, whatever the fuel.
  lambda,

  /// Mass of air per mass of fuel - 14.7 is stoichiometric for petrol.
  afr,
}

/// Whether [config]'s measurement and [target]'s values are lambda or an
/// air-fuel ratio.
///
/// The target table's units decide where they say. rusEFI switches both the
/// table and the measured channel between the two with one display setting,
/// and calls the channel `veAnalyzeAfrLambda1` either way, so the channel's
/// name - all Speeduino's definition offers - is only the fallback.
///
/// The correction itself does not depend on this: measurement and target are
/// always in the same units, so their ratio is the same either way. What does
/// is anything judged against a fixed lambda range, such as whether a reading
/// is plausible at all.
MixtureUnits mixtureUnitsOf(IniVeAnalyze config, TableView? target) {
  final units = target?.zUnits.toLowerCase() ?? '';
  if (units.contains('lambda')) return MixtureUnits.lambda;
  if (units.contains('afr')) return MixtureUnits.afr;
  return config.measuresLambda ? MixtureUnits.lambda : MixtureUnits.afr;
}
