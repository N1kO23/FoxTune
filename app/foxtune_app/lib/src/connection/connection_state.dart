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

  /// Whether writing to this ECU may be permitted.
  ///
  /// Only a confirmed signature match qualifies. Everything else - a mismatch,
  /// or no definition at all - means the page layout in hand may not describe
  /// the ECU on the wire.
  bool get writesPermitted => signatureStatus == SignatureStatus.matched;
}

class EcuConnectionFailed extends EcuConnectionState {
  const EcuConnectionFailed(this.message, {this.port});
  final String message;
  final EcuPort? port;
}
