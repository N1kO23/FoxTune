/// Tune state, table and curve math, tune files and datalogging.
///
/// Tune state is held as raw page byte buffers with typed views projected over
/// them via the `.ini` model. Keeping bytes as the source of truth makes round
/// trips to the ECU and to `.msq` lossless by construction.
///
/// Writing is guarded: see [WritePermission] for the conditions a session must
/// satisfy, and [TuneWriter] for the write-verify-burn sequence.
///
/// Pure Dart.
library;

export 'src/log_recorder.dart';
export 'src/msl_writer.dart';
export 'src/msq_codec.dart';
export 'src/table_file.dart';
export 'src/table_view.dart';
export 'src/tune_state.dart';
export 'src/tune_writer.dart';
export 'src/value_resolver.dart';
export 'src/write_guard.dart';
