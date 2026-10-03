import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/autotune/log_replay_screen.dart';
import 'package:foxtune_app/src/branding/brand_theme.dart';
import 'package:foxtune_app/src/dashboard/dashboard_controller.dart';
import 'package:foxtune_app/src/files/file_saving.dart';
import 'package:foxtune_app/src/logging/log_files.dart';
import 'package:foxtune_app/src/tune/offline_tune.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_app/src/tune/tune_controller.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

class _FakeTuneController extends TuneController {
  _FakeTuneController(this._tune);

  final TuneState? _tune;

  @override
  Future<TuneState?> build() async => _tune;
}

/// A file already open for editing, with no ECU.
class _OpenFile extends OfflineTuneController {
  _OpenFile(this._tune);

  final TuneState _tune;

  @override
  OfflineTune? build() =>
      OfflineTune(tune: _tune, fileName: 'base.msq', saved: _tune.copy());
}

/// Keeps what is saved, and hands out [next] when asked for a file.
class _Files extends FileSaving {
  _Files() : super(mobile: false);

  String? saved;
  PickedFile? next;

  @override
  Future<String?> saveBytes({
    required String fileName,
    required String extension,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    saved = utf8.decode(bytes);
    return fileName;
  }

  @override
  Future<PickedFile?> pickFile({
    required List<String> extensions,
    String? dialogTitle,
  }) async => next;
}

/// Runs the analysis in place: a real isolate cannot be waited on inside the
/// test's fake clock.
Future<LogReplayResult> _runHere(
  TuneState tune,
  String log,
  AutotuneSettings settings,
) async =>
    LogReplay.analyse(tune: tune, log: MslLog.parse(log), settings: settings);

/// Replaying a log, driven through the screen against the real definition.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IniDocument doc;
  late TuneState tune;
  late _Files files;

  /// Where the log below holds the engine: 2000 rpm, 60 kPa.
  const cell = (row: 4, column: 3);

  setUpAll(() async {
    final source = await rootBundle.loadString('assets/speeduino.ini');
    doc = IniParser(defined: {'CELSIUS'}).parse(source);
  });

  setUp(() {
    files = _Files();
    tune = TuneState.empty(doc);

    // A wideband, a stoichiometric ratio, a flat VE table and a flat target.
    final ego = tune.locate('egoType')!;
    tune.writeBits(ego.page, ego.field as IniBitsField, 2);
    SettingView.of(tune, 'stoich')!.setValue(14.7);
    SettingView.of(tune, 'algorithm')!.setOptionIndex(0);

    final ve = TableView.of(tune, doc.tableNamed('veTable1Tbl')!)!;
    for (var i = 0; i < 16; i++) {
      ve.setXAt(i, 500 + i * 500);
      ve.setYAt(i, 20 + i * 10);
    }
    for (var r = 0; r < 16; r++) {
      for (var c = 0; c < 16; c++) {
        ve.setValueAt(r, c, 50);
      }
    }

    final afr = TableView.of(tune, doc.tableNamed('afrTable1Tbl')!)!;
    for (var r = 0; r < afr.rows; r++) {
      for (var c = 0; c < afr.columns; c++) {
        afr.setValueAt(r, c, 14.7);
      }
    }
    for (var i = 0; i < afr.columns; i++) {
      afr.setXAt(i, 500 + i * 1000);
    }
    for (var i = 0; i < afr.rows; i++) {
      afr.setYAt(i, 20 + i * 15);
    }

    tune.markClean();
  });

  double? veAt(TuneState state, ({int row, int column}) at) => TableView.of(
    state,
    doc.tableNamed('veTable1Tbl')!,
  )!.valueAt(at.row, at.column);

  /// A log of the engine held at 2000 rpm and 60 kPa, running [afr] against
  /// the 14.7 target on a VE of [ve].
  String logText({double afr = 15.4, int ve = 50, bool withVe = true}) {
    String label(String channel) =>
        doc.datalog.firstWhere((e) => e.channel == channel).label;
    final columns = {
      'time': 's',
      'rpm': 'rpm',
      'fuelLoad': 'kPa',
      'afr': 'O2',
      'egoCorrection': '%',
      'coolant': 'C',
      'engine': 'bits',
      'pulseWidth': 'ms',
      if (withVe) 'VE1': '%',
    };
    final buffer = StringBuffer()
      ..writeln('"${doc.identity.signature}"')
      ..writeln('"Capture Date: 2026-09-27T10:00:00Z"')
      ..writeln(columns.keys.map(label).join('\t'))
      ..writeln(columns.values.join('\t'));
    for (var i = 0; i < 60; i++) {
      buffer.writeln(
        [
          (i * 0.05).toStringAsFixed(3),
          2000,
          60,
          afr,
          100,
          85,
          0,
          3.0,
          if (withVe) ve,
        ].join('\t'),
      );
    }
    return buffer.toString();
  }

  PickedFile logFile(String text) =>
      PickedFile(name: 'drive.msl', bytes: utf8.encode(text));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    Widget home = const LogReplayScreen(),
    WritePermission permission = const WritePermission.granted(),
    Size size = const Size(1400, 1200),
    List<Override> extra = const [],
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(
      overrides: [
        tuneProvider.overrideWith(() => _FakeTuneController(tune)),
        writePermissionProvider.overrideWithValue(permission),
        realtimeMonitorProvider.overrideWithValue(null),
        realtimeProvider.overrideWith((ref) => const Stream.empty()),
        logReplayRunnerProvider.overrideWithValue(_runHere),
        fileSavingProvider.overrideWithValue(files),
        recentLogsProvider.overrideWith((ref) async => const []),
        ...extra,
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: brandTheme(Brightness.light), home: home),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> chooseLog(WidgetTester tester, String text) async {
    files.next = logFile(text);
    await tester.tap(
      find.textContaining(RegExp('^(Choose a log|Another log)')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open a file...'));
    await tester.pumpAndSettle();
  }

  FilledButton buttonLabelled(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(FilledButton),
        ),
      );

  testWidgets('shows what a log would change, without changing it', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('Choose a recorded log'), findsOneWidget);

    await chooseLog(tester, logText());

    expect(tester.takeException(), isNull);
    expect(find.text('Log: drive.msl'), findsOneWidget);
    expect(find.text('Cells to change '), findsOneWidget);
    expect(find.byType(TableGrid), findsOneWidget);
    expect(veAt(tune, cell), 50);
    expect(tune.isDirty, isFalse);
  });

  testWidgets('applies into the tune, which then waits for a burn', (
    tester,
  ) async {
    await pump(tester);
    await chooseLog(tester, logText());

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    // 15.4 against 14.7 is 4.8% lean, applied at once rather than a step.
    expect(veAt(tune, cell), 52);
    expect(tune.isDirty, isTrue);
    expect(find.textContaining('until you burn'), findsOneWidget);
    expect(buttonLabelled(tester, 'Apply').onPressed, isNull);
  });

  testWidgets('a read-only session can look but not apply', (tester) async {
    await pump(
      tester,
      permission: const WritePermission.refused('Write mode is off.'),
    );
    await chooseLog(tester, logText());

    expect(find.byType(TableGrid), findsOneWidget);
    expect(buttonLabelled(tester, 'Apply').onPressed, isNull);
    expect(find.text('Write mode is off.'), findsOneWidget);
  });

  testWidgets('a log recorded on another table changes nothing, and says why', (
    tester,
  ) async {
    await pump(tester);
    await chooseLog(tester, logText(ve: 45));

    expect(find.textContaining('Nothing to change'), findsOneWidget);
    expect(buttonLabelled(tester, 'Apply').onPressed, isNull);

    await tester.tap(find.text('Why?'));
    await tester.pumpAndSettle();
    expect(find.text('Table since changed'), findsOneWidget);
  });

  testWidgets('a log that cannot be replayed says why', (tester) async {
    await pump(tester);
    await chooseLog(tester, logText(withVe: false));

    expect(find.textContaining('VE1'), findsOneWidget);
    expect(find.byType(TableGrid), findsNothing);
  });

  testWidgets('a file that is not a log says so', (tester) async {
    await pump(tester);
    await chooseLog(tester, 'this is not a log\n');

    expect(find.textContaining('not a MegaLogViewer log'), findsOneWidget);
  });

  testWidgets('lays out at phone width', (tester) async {
    await pump(tester, size: const Size(400, 850));
    await chooseLog(tester, logText());
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('into a file, with no ECU', () {
    testWidgets('applies, and the file is saved as a .msq', (tester) async {
      final container = await pump(
        tester,
        extra: [offlineTuneProvider.overrideWith(() => _OpenFile(tune))],
      );
      expect(find.text('Tune: base.msq'), findsOneWidget);
      expect(find.text('Write mode'), findsNothing);
      expect(find.text('Burn to ECU'), findsNothing);

      await chooseLog(tester, logText());
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Save it to keep it'), findsOneWidget);
      expect(container.read(offlineTuneProvider)!.unsaved, isTrue);

      await tester.tap(find.text('Save .msq'));
      await tester.pumpAndSettle();

      final saved = TuneState.empty(doc);
      MsqCodec.decode(files.saved!, saved);
      expect(veAt(saved, cell), 52);
      expect(container.read(offlineTuneProvider)!.unsaved, isFalse);
    });
  });
}
