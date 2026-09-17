/// Tune state, table and curve math, and `.msq` import/export.
///
/// Tune state is held as raw page byte buffers with typed views projected over
/// them via the `.ini` model. Keeping bytes as the source of truth makes round
/// trips to the ECU and to `.msq` lossless by construction.
///
/// Pure Dart.
library;

// Tune model lands in M4.
