import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_protocol/foxtune_protocol.dart';
import 'package:foxtune_transport/foxtune_transport.dart';

/// How a connected ECU's signature compares with the loaded definition.
enum SignatureStatus {
  /// The ECU reports exactly what the definition expects.
  matched,

  /// The ECU answered, but with a different signature.
  ///
  /// Reading is still possible, but page offsets are not trustworthy, so
  /// writing must stay disabled.
  mismatched,

  /// No definition was loaded, so there is nothing to compare against.
  unknown,
}

/// The connection lifecycle.
sealed class EcuConnectionState {
  const EcuConnectionState();
}

class EcuDisconnected extends EcuConnectionState {
  const EcuDisconnected();
}

class EcuConnecting extends EcuConnectionState {
  const EcuConnecting(this.port);
  final EcuPort port;
}

class EcuConnected extends EcuConnectionState {
  const EcuConnected({
    required this.port,
    required this.identification,
    required this.signatureStatus,
    required this.expectedSignature,
    this.definition,
  });

  final EcuPort port;
  final EcuIdentification identification;
  final SignatureStatus signatureStatus;

  /// What the loaded definition expected, for showing alongside a mismatch.
  final String? expectedSignature;

  final IniDocument? definition;

  /// Whether the loaded definition is confirmed to describe this ECU.
  ///
  /// A precondition for writing, but not the whole of it: write mode must also
  /// be switched on deliberately. Use `writePermissionProvider` for the real
  /// answer - this getter only says the page layout can be trusted.
  bool get definitionMatches => signatureStatus == SignatureStatus.matched;
}

class EcuConnectionFailed extends EcuConnectionState {
  const EcuConnectionFailed(this.message, {this.port});
  final String message;
  final EcuPort? port;
}

/// The connection was working, and then it stopped.
///
/// Distinct from [EcuConnectionFailed], which is a connection that never came
/// up: here a session was under way, so there may be unburned edits to rescue
/// and the right next step is reconnecting to the same ECU rather than
/// choosing a port again. A pulled OTG cable in the car is the usual cause.
class EcuConnectionLost extends EcuConnectionState {
  const EcuConnectionLost(this.reason, {required this.port});

  /// Why, fit to show a user.
  final String reason;

  /// The port that was connected.
  final EcuPort port;
}
