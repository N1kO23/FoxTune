import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import 'gauge_catalog.dart';
import 'layout/dashboard_layout.dart';
import 'layout/layout_controller.dart';

/// Whether live data polling must read the whole block, rather than only the
/// parts read of late: while anything holds it - a log, which keeps every
/// channel; autotuning, which must not judge a sample on a channel left
/// unread.
final wholeBlockProvider = NotifierProvider<WholeBlockHolders, bool>(
  WholeBlockHolders.new,
);

class WholeBlockHolders extends Notifier<bool> {
  final _holders = <Object>{};

  @override
  bool build() => false;

  /// Polls the whole block until [holder] lets go.
  void hold(Object holder) {
    _holders.add(holder);
    state = true;
  }

  void release(Object holder) {
    _holders.remove(holder);
    state = _holders.isNotEmpty;
  }
}

/// Every channel the dashboard draws, on every page: polled whether read or
/// not, so a page switched to has its readings at once - and its graphs
/// their history.
final dashboardChannelsProvider = Provider<Set<String>>((ref) {
  final connection = ref.watch(connectionProvider);
  final definition = connection is EcuConnected ? connection.definition : null;
  final layout = ref.watch(dashboardLayoutProvider).value;
  if (definition == null || layout == null) return const {};
  return channelsDrawn(
    layout,
    GaugeCatalog(definition: definition, limits: layout.limits),
  );
});

/// The channels [layout] draws: each gauge's, each graph lane's, and what
/// each lamp's expression reads.
Set<String> channelsDrawn(DashboardLayout layout, GaugeCatalog catalog) => {
  for (final page in layout.pages)
    for (final item in page.items)
      if (item.style == GaugeStyle.lamp)
        ...?CompiledExpression.tryCompile(
          catalog.indicatorFor(item.indicator)?.expression ?? '',
        )?.references
      else
        for (final ref in item.gauges) ?catalog.specOf(ref)?.channel,
};
