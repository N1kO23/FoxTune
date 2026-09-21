import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:foxtune_ini/foxtune_ini.dart';

import '../connection/connection_controller.dart';
import '../connection/connection_state.dart';
import '../dashboard/gauge_status.dart';
import '../files/file_saving.dart';
import 'definition_library.dart';

/// Asks for the definition file of the connected ECU, and uses it.
///
/// The file has to be for the exact firmware the ECU reports; anything else is
/// refused with the two signatures side by side, so the difference is plain.
Future<void> chooseDefinition(BuildContext context, WidgetRef ref) async {
  final connection = ref.read(connectionProvider);
  if (connection is! EcuConnected) return;
  final messenger = ScaffoldMessenger.of(context);

  void tell(String message, {bool problem = false}) => messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: problem ? StatusPalette.critical : null,
      duration: Duration(seconds: problem ? 8 : 4),
    ),
  );

  final picked = await ref
      .read(fileSavingProvider)
      .pickFile(
        extensions: const ['ini'],
        dialogTitle: 'Definition for ${connection.identification.signature}',
      );
  if (picked == null) return;

  try {
    await ref
        .read(connectionProvider.notifier)
        .adoptDefinition(decodeDefinition(picked.bytes));
    tell('Using ${picked.name}. It is kept for next time.');
  } on DefinitionMismatchException catch (error) {
    tell('$error', problem: true);
  } on IniParseException catch (error) {
    tell(
      '${picked.name} is not a definition FoxTune can read: $error',
      problem: true,
    );
  }
}
