/// Transports that depend on `dart:io`, and the worker that runs a connection
/// on an isolate of its own.
///
/// Kept out of the main library so the core codec stays usable anywhere,
/// including targets without `dart:io`.
library;

export 'src/socket_link.dart';
export 'src/worker/ecu_worker.dart';
