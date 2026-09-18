import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

import '../dashboard/gauge_status.dart';
import 'connection_state.dart';

/// The platform's serial transport.
final transportProvider = Provider<EcuTransport>((ref) {
  return EcuTransport.forPlatform();
});

/// Temperature scale the definition is parsed for.
///
/// This selects a branch in the ECU definition, not just a label: the
/// Celsius and Fahrenheit builds compute `coolant` and `iat` with different
/// expressions, so the gauges' ranges and thresholds are derived from the same
/// choice. See [TemperatureUnit].
final temperatureUnitProvider = StateProvider<TemperatureUnit>(
  (ref) => TemperatureUnit.celsius,
);

/// The bundled ECU definition.
///
/// Parsing ~6000 lines takes long enough to be worth keeping off the build
/// path, so this is a future the UI awaits once.
final definitionProvider = FutureProvider<IniDocument>((ref) async {
  final source = await rootBundle.loadString('assets/speeduino.ini');
  final unit = ref.watch(temperatureUnitProvider);
  return IniParser(defined: unit.iniSymbols).parse(source);
});

/// Serial ports currently attached.
final portsProvider = FutureProvider<List<EcuPort>>((ref) async {
  return ref.watch(transportProvider).listPorts();
});

/// Drives connect / disconnect and owns the live link.
final connectionProvider =
    NotifierProvider<ConnectionController, EcuConnectionState>(
      ConnectionController.new,
    );

class ConnectionController extends Notifier<EcuConnectionState> {
  EcuLink? _link;
  EcuClient? _client;

  @override
  EcuConnectionState build() {
    ref.onDispose(_teardown);
    return const EcuDisconnected();
  }

  /// The client for the live connection, or `null` when disconnected.
  EcuClient? get client => _client;

  /// Connects over TCP to an ESP-based WiFi bridge at `host:port`.
  Future<void> connectToNetwork(String address) {
    const transport = TcpEcuTransport();
    return connect(transport.portFor(address), transport: transport);
  }

  Future<void> connect(EcuPort port, {EcuTransport? transport}) async {
    if (state is EcuConnecting) return;
    await _teardown();
    state = EcuConnecting(port);

    try {
      final EcuTransport resolved = transport ?? ref.read(transportProvider);
      final link = await resolved.open(port);
      _link = link;

      final client = EcuClient(link);
      _client = client;

      final identification = await client.identify();

      // The definition may still be parsing; connecting should not block on it,
      // but the comparison needs it.
      final definition = await ref.read(definitionProvider.future);
      final expected = definition.identity.signature;
      final status = expected == null
          ? SignatureStatus.unknown
          : definition.matchesSignature(identification.signature)
          ? SignatureStatus.matched
          : SignatureStatus.mismatched;

      state = EcuConnected(
        port: port,
        identification: identification,
        signatureStatus: status,
        expectedSignature: expected,
        definition: definition,
      );
    } on Object catch (error) {
      await _teardown();
      state = EcuConnectionFailed(_describe(error), port: port);
    }
  }

  Future<void> disconnect() async {
    await _teardown();
    state = const EcuDisconnected();
  }

  Future<void> _teardown() async {
    final client = _client;
    final link = _link;
    _client = null;
    _link = null;
    await client?.close();
    await link?.close();
  }

  static String _describe(Object error) => switch (error) {
    EcuTransportException(:final message) => message,
    EcuProtocolException(response: SerialResponse.timeout) =>
      'The ECU did not respond. Check the baud rate and that the '
          'firmware is running, not the bootloader.',
    EcuProtocolException(:final message) => message,
    _ => error.toString(),
  };
}
