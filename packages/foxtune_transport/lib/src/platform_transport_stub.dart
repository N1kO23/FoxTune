import 'ecu_transport.dart';

/// Fallback for targets without `dart:io`, such as Flutter web.
EcuTransport createPlatformTransport() => throw UnsupportedError(
      'Serial transport requires a platform with dart:io.',
    );
