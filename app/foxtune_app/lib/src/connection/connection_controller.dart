import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

import '../dashboard/gauge_status.dart';
import '../definitions/definition_library.dart';
import '../storage/json_store.dart';
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
final temperatureUnitProvider = Provider<TemperatureUnit>(
  (ref) => TemperatureUnit.celsius,
);

/// The Speeduino definition FoxTune ships with.
///
/// Parsing ~6000 lines takes long enough to be worth keeping off the build
/// path, so this is a future the UI awaits once.
final definitionProvider = FutureProvider<IniDocument>((ref) async {
  final source = await rootBundle.loadString('assets/speeduino.ini');
  final unit = ref.watch(temperatureUnitProvider);
  return IniParser(defined: unit.iniSymbols).parse(source);
});

/// How a definition is downloaded. Replaced in tests.
final definitionFetcherProvider = Provider<DefinitionFetcher>(
  (ref) => fetchDefinitionOverHttp,
);

/// Where the connected ECU's definition is found.
final definitionLibraryProvider = Provider<DefinitionLibrary>((ref) {
  final unit = ref.watch(temperatureUnitProvider);
  return DefinitionLibrary(
    bundled: () => ref.read(definitionProvider.future),
    storage: () async {
      try {
        return await ref.read(appStorageDirectoryProvider.future);
      } on Object {
        // Without storage nothing is kept between sessions, but a definition
        // can still be found for this one.
        return null;
      }
    },
    fetch: ref.watch(definitionFetcherProvider),
    symbols: unit.iniSymbols,
  );
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

  /// What the last connection attempt went through, so a retry or reconnect
  /// uses the same route. A network ECU must be retried over TCP, not handed
  /// to the platform's USB transport as though its address were a device.
  EcuPort? _lastPort;
  EcuTransport? _lastTransport;

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

    final EcuTransport resolved = transport ?? ref.read(transportProvider);
    _lastPort = port;
    _lastTransport = resolved;

    try {
      final link = await resolved.open(port);
      _link = link;

      final client = EcuClient(link);
      _client = client;

      final identification = await client.identify();

      state = EcuConnecting(
        port,
        stage: 'Finding the definition for ${identification.signature}...',
      );
      final library = ref.read(definitionLibraryProvider);
      state = await _connected(
        port,
        identification,
        await library.find(identification),
        library,
      );
    } on Object catch (error) {
      await _teardown();
      state = EcuConnectionFailed(_describe(error), port: port);
    }
  }

  /// The connected state for what the definition lookup found.
  Future<EcuConnected> _connected(
    EcuPort port,
    EcuIdentification identification,
    DefinitionLookup lookup,
    DefinitionLibrary library,
  ) async {
    switch (lookup) {
      case DefinitionFound(:final definition, :final source):
        _client?.useDefinition(definition);
        return EcuConnected(
          port: port,
          identification: identification,
          signatureStatus: SignatureStatus.matched,
          expectedSignature: definition.identity.signature,
          definition: definition,
          definitionSource: source,
        );

      case DefinitionMissing(:final reason)
          when identification.family == EcuFamily.speeduino:
        // A Speeduino on another release still reads mostly right through the
        // shipped definition - enough to see what it is doing - but page
        // offsets may have moved, so writing stays off until the right
        // definition is chosen.
        final bundled = await library.bundled();
        _client?.useDefinition(bundled);
        return EcuConnected(
          port: port,
          identification: identification,
          signatureStatus: SignatureStatus.mismatched,
          expectedSignature: bundled.identity.signature,
          definition: bundled,
          definitionSource: DefinitionSource.bundled,
          definitionProblem: reason,
        );

      case DefinitionMissing(:final reason):
        // Nothing FoxTune has describes this ECU. Staying connected lets the
        // user choose the file without starting over.
        return EcuConnected(
          port: port,
          identification: identification,
          signatureStatus: SignatureStatus.unknown,
          expectedSignature: null,
          definitionProblem: reason,
        );
    }
  }

  /// Uses [source], a definition the user chose, for the connected ECU.
  ///
  /// Throws [DefinitionMismatchException] if it is for different firmware;
  /// the connection is left as it was.
  Future<void> adoptDefinition(String source) async {
    final current = state;
    if (current is! EcuConnected) return;
    final library = ref.read(definitionLibraryProvider);
    final definition = await library.adopt(
      source,
      signature: current.identification.signature,
    );
    state = await _connected(
      current.port,
      current.identification,
      DefinitionFound(definition, DefinitionSource.picked),
      library,
    );
  }

  /// Looks for the connected ECU's definition again - after going online,
  /// say.
  Future<void> retryDefinition() async {
    final current = state;
    if (current is! EcuConnected) return;
    final library = ref.read(definitionLibraryProvider);
    final lookup = await library.find(current.identification);
    if (state != current) return;
    state = await _connected(
      current.port,
      current.identification,
      lookup,
      library,
    );
  }

  /// Connects again to the ECU last tried, by the same route.
  Future<void> reconnect() async {
    final port = _lastPort;
    if (port == null) return;
    await connect(port, transport: _lastTransport);
  }

  /// Ends the session.
  ///
  /// Unburned edits are rescued by `unburnedEditsGuardProvider` as the
  /// connection changes, not here: the loaded tune depends on this
  /// controller, so reaching back into it from here is a circular dependency
  /// Riverpod refuses.
  Future<void> disconnect() async {
    await _teardown();
    state = const EcuDisconnected();
  }

  /// Ends a session that stopped working, without being asked to.
  ///
  /// Called when the ECU stops answering or its cable is unplugged. Leaving
  /// the app reporting "connected" over frozen gauges would be worse than
  /// saying so plainly.
  Future<void> connectionLost(String reason) async {
    final current = state;
    if (current is! EcuConnected) return;
    await _teardown();
    state = EcuConnectionLost(reason, port: current.port);
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
