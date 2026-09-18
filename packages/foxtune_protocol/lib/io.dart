/// Transports that depend on `dart:io`.
///
/// Kept out of the main library so the core codec stays usable anywhere,
/// including targets without `dart:io`.
library;

export 'src/socket_link.dart';
