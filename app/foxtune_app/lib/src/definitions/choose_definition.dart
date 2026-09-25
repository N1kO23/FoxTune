import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'definition_library.dart';

/// Shows [message], as a problem where [problem] says so.
void tellAboutDefinition(
  ScaffoldMessengerState messenger,
  String message, {
  bool problem = false,
}) => messenger.showSnackBar(
  SnackBar(
    content: Text(message),
    backgroundColor: problem ? StatusPalette.critical : null,
    duration: Duration(seconds: problem ? 8 : 4),
  ),
);

/// Asks the user for a definition file, under the dialog title [title].
///
/// Returns `null` if they cancelled - or if no file could be had, which is
/// said through [messenger] rather than shrugged off.
Future<PickedFile?> pickDefinitionFile(
  WidgetRef ref,
  ScaffoldMessengerState messenger, {
  required String title,
}) async {
  try {
    return await ref
        .read(fileSavingProvider)
        .pickFile(extensions: const ['ini'], dialogTitle: title);
  } on WrongFileTypeException catch (error) {
    tellAboutDefinition(messenger, error.message, problem: true);
  } on Object catch (error) {
    // On Linux the dialog comes from the desktop portal, and without one there
    // is no dialog at all - which has to be said, not silently shrugged off.
    tellAboutDefinition(
      messenger,
      'Could not open a file: $error',
      problem: true,
    );
  }
  return null;
}

/// Asks for the definition file of the connected ECU, and uses it.
///
/// The file has to be for the exact firmware the ECU reports; anything else is
/// refused with the two signatures side by side, so the difference is plain.
Future<void> chooseDefinition(BuildContext context, WidgetRef ref) async {
  final connection = ref.read(connectionProvider);
  if (connection is! EcuConnected) return;
  final messenger = ScaffoldMessenger.of(context);

  final picked = await pickDefinitionFile(
    ref,
    messenger,
    title: 'Definition for ${connection.identification.signature}',
  );
  if (picked == null) return;

  try {
    await ref
        .read(connectionProvider.notifier)
        .adoptDefinition(decodeDefinition(picked.bytes), fileName: picked.name);
    tellAboutDefinition(
      messenger,
      'Using ${picked.name}. It is kept for next time.',
    );
  } on DefinitionMismatchException catch (error) {
    tellAboutDefinition(messenger, '$error', problem: true);
  } on IniParseException catch (error) {
    tellAboutDefinition(
      messenger,
      '${picked.name} is not a definition FoxTune can read: $error',
      problem: true,
    );
  }
}
