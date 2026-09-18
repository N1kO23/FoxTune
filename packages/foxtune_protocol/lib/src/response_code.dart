/// Result codes returned by the Speeduino new-generation serial protocol.
///
/// The firmware prefixes every response payload with one of these bytes.
enum SerialResponse {
  /// Command accepted; payload follows.
  ok(0x00),

  /// An EEPROM burn completed successfully.
  burnOk(0x04),

  /// The firmware's own 400 ms inter-byte timeout elapsed mid-command.
  timeout(0x80),

  /// CRC-32 over the received frame did not match.
  crcError(0x82),

  /// The firmware does not recognise the command byte.
  unknownCommand(0x83),

  /// A page, offset or length fell outside the firmware's bounds.
  /// The firmware does not expect a retry for this.
  rangeError(0x84),

  /// The firmware is busy. Unlike the other errors this one is transient:
  /// the caller is expected to wait and reissue the same command.
  busy(0x85);

  const SerialResponse(this.code);

  /// The on-the-wire byte value.
  final int code;

  /// Whether this response indicates success.
  bool get isOk => this == SerialResponse.ok || this == SerialResponse.burnOk;

  /// Whether reissuing the same command is the correct response.
  bool get isRetryable => this == SerialResponse.busy;

  /// Maps a raw byte to its [SerialResponse], or `null` if unrecognised.
  static SerialResponse? fromByte(int byte) {
    for (final value in SerialResponse.values) {
      if (value.code == byte) return value;
    }
    return null;
  }
}

/// Thrown when the ECU returns a non-OK [SerialResponse], or replies in a way
/// the codec cannot interpret.
class EcuProtocolException implements Exception {
  EcuProtocolException(this.message, {this.response});

  /// Human-readable description of what went wrong.
  final String message;

  /// The code the ECU returned, when the failure came from a decoded response.
  final SerialResponse? response;

  @override
  String toString() => response == null
      ? 'EcuProtocolException: $message'
      : 'EcuProtocolException: $message (${response!.name})';
}
