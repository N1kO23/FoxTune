import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxtune_app/src/app_settings/app_settings.dart';
import 'package:foxtune_app/src/app_settings/app_settings_screen.dart';
import 'package:foxtune_app/src/app_settings/map_colours.dart';
import 'package:foxtune_app/src/app_settings/map_colours_screen.dart';
import 'package:foxtune_app/src/definitions/definition_library.dart';
import 'package:foxtune_app/src/storage/json_store.dart';
import 'package:foxtune_app/src/tune/table_grid.dart';
import 'package:foxtune_ini/foxtune_ini.dart';
import 'package:foxtune_tune/foxtune_tune.dart';

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);
const _redToBlue = MapGradient('Red to blue', [
  GradientStop(0, _red),
  GradientStop(1, _blue),
]);

/// A table of 101 to 112, two rows of six.
TableView _table() {
  final doc = IniParser().parse('''
[MegaTune]
signature = "test 1"
[Constants]
endianness = little
nPages     = 1
pageSize   = 32
page = 1
  zTable = array, U08, 0,  [2x6], "%",   1.0,   0.0, 0.0, 255.0, 0
  xAxis  = array, U08, 12, [6],   "RPM", 100.0, 0.0, 100.0, 25500.0, 0
  yAxis  = array, U08, 18, [2],   "kPa", 2.0,   0.0, 0.0, 510.0, 0
[TableEditor]
  table = t, tMap, "Wide Table", 1
    xBins = xAxis, rpm
    yBins = yAxis, map
    zBins = zTable
''');
  final tune = TuneState.empty(doc);
  final z = tune.locate('zTable')!;
  final x = tune.locate('xAxis')!;
  final y = tune.locate('yAxis')!;
  for (var i = 0; i < 12; i++) {
    tune.writeRaw(z.page, z.field, 101 + i, i);
  }
  for (var i = 0; i < 6; i++) {
    tune.writeRaw(x.page, x.field, 10 * (i + 1), i);
  }
  for (var i = 0; i < 2; i++) {
    tune.writeRaw(y.page, y.field, 5 * (i + 1), i);
  }
  tune.markClean();
  return TableView.of(tune, doc.tables.single)!;
}

/// [expected], to within what float arithmetic leaves over.
Matcher _colour(Color expected) => predicate<Color>(
  (actual) =>
      (actual.a - expected.a).abs() < 1e-6 &&
      (actual.r - expected.r).abs() < 1e-6 &&
      (actual.g - expected.g).abs() < 1e-6 &&
      (actual.b - expected.b).abs() < 1e-6,
  'close to $expected',
);

void main() {
  group('a gradient', () {
    const three = MapGradient('Three', [
      GradientStop(0.2, _red),
      GradientStop(0.5, Color(0xFF00FF00)),
      GradientStop(0.8, _blue),
    ]);

    test('is its colours at their stops, and blends between them', () {
      expect(three.colorAt(0.2), _red);
      expect(three.colorAt(0.5), const Color(0xFF00FF00));
      expect(three.colorAt(0.8), _blue);
      expect(
        three.colorAt(0.35),
        _colour(Color.lerp(_red, const Color(0xFF00FF00), 0.5)!),
      );
    });

    test('is its outermost colours beyond them', () {
      expect(three.colorAt(0), _red);
      expect(three.colorAt(1), _blue);
      expect(three.colorAt(-3), _red);
      expect(three.colorAt(double.nan), _red);
    });

    test('reversed, runs the other way', () {
      final reversed = three.reversed('Back');
      expect(reversed.name, 'Back');
      expect(reversed.colorAt(0.2), _colour(_blue));
      expect(reversed.colorAt(0.8), _colour(_red));
    });

    test('reads back what it writes, sorted, and refuses what is not one', () {
      expect(MapGradient.fromJson(three.toJson()), three);
      expect(
        MapGradient.fromJson({
          'name': 'Backwards',
          'stops': [
            {'at': 1, 'color': '#0000FF'},
            {'at': 0, 'color': '#FF0000'},
          ],
        })!.stops.first.color,
        _red,
      );
      expect(MapGradient.fromJson(null), isNull);
      expect(
        MapGradient.fromJson({
          'name': 'One colour',
          'stops': [
            {'at': 0, 'color': '#FF0000'},
          ],
        }),
        isNull,
      );
      expect(
        MapGradient.fromJson({
          'name': 'Not a colour',
          'stops': [
            {'at': 0, 'color': 'red'},
            {'at': 1, 'color': '#0000FF'},
          ],
        }),
        isNull,
      );
    });

    test('is written in hex as the web writes it', () {
      expect(hexOf(const Color(0xFFFF2E6E)), '#FF2E6E');
      expect(hexOf(const Color(0x80FF2E6E)), '#FF2E6E80');
      expect(colorFromHex('#ff2e6e'), const Color(0xFFFF2E6E));
      expect(colorFromHex('FF2E6E80'), const Color(0x80FF2E6E));
      expect(colorFromHex('#FF2E6'), isNull);
      expect(colorFromHex('pink'), isNull);
    });
  });

  test('text keeps its colour where it reads, and is black or white where it '
      'would not', () {
    const onSurface = Color(0xFF1B1B1B);
    expect(readableOn(const Color(0xFFFAFAFA), onSurface), onSurface);
    expect(readableOn(const Color(0xFF0000A0), onSurface), Colors.white);
    expect(
      readableOn(const Color(0xFFFFE000), const Color(0xFFE3E3E3)),
      Colors.black,
    );
  });

  test('the gradient in use, and the ones saved, are kept', () {
    final settings = AppSettings(
      mapGradient: builtInGradients[3],
      savedGradients: const [_redToBlue],
    );
    expect(AppSettings.fromJson(settings.toJson()), settings);

    // One saved gradient that does not read costs only itself.
    final json = settings.toJson()
      ..['savedGradients'] = [
        {'name': 'Broken'},
        _redToBlue.toJson(),
      ];
    expect(AppSettings.fromJson(json).savedGradients, [_redToBlue]);
  });

  testWidgets('the table grid is shaded with the theme\'s gradient', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [MapColours(_redToBlue)]),
        home: Scaffold(
          body: TableGrid(
            view: _table(),
            selection: const CellSelection.single(1, 5),
            onSelectionChanged: (_) {},
            onEdit: (_) {},
          ),
        ),
      ),
    );

    BoxDecoration cellOf(String text) =>
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text(text),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;

    // 101 is the lowest value, 111 the highest not selected.
    expect(cellOf('101').color, _red);
    expect(cellOf('111').color, Color.lerp(_red, _blue, 10 / 11));
    // Dark text would not read on the blue: it is white.
    expect(tester.widget<Text>(find.text('111')).style?.color, Colors.white);
  });

  group('the editor', () {
    late Directory storage;

    setUp(() => storage = Directory.systemTemp.createTempSync('foxtune_maps'));
    tearDown(() => storage.deleteSync(recursive: true));

    Future<ProviderContainer> pumpEditor(
      WidgetTester tester, {
      AppSettings settings = const AppSettings(),
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            initialAppSettingsProvider.overrideWithValue(settings),
            appStorageDirectoryProvider.overrideWith((ref) async => storage),
          ],
          child: const MaterialApp(home: MapColoursScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(MapColoursScreen)),
      );
    }

    MapGradient inUse(ProviderContainer container) =>
        container.read(appSettingsProvider).mapGradient;

    AppSettings saved() => AppSettings.fromJson(
      jsonDecode(File('${storage.path}/settings.json').readAsStringSync()),
    );

    testWidgets('puts a preset to use, and keeps it', (tester) async {
      final container = await pumpEditor(tester);
      expect(inUse(container), foxTuneGradient);

      await tester.tap(find.text('Viridis'));
      await tester.pumpAndSettle();
      expect(inUse(container), builtInGradients[3]);
      expect(saved().mapGradient, builtInGradients[3]);
    });

    testWidgets('adds a colour where the gradient is tapped, and removes it '
        'again - but never below two', (tester) async {
      final container = await pumpEditor(tester);
      final remove = find.widgetWithText(OutlinedButton, 'Remove colour');
      expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);

      await tester.tap(find.bySemanticsLabel('Gradient'));
      await tester.pumpAndSettle();
      expect(inUse(container).stops, hasLength(3));
      expect(inUse(container).name, 'Custom');

      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(inUse(container).stops, hasLength(2));
      expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
    });

    testWidgets('moves a colour as it is dragged, keeping it once let go', (
      tester,
    ) async {
      final container = await pumpEditor(
        tester,
        settings: const AppSettings(mapGradient: _redToBlue),
      );

      final drag = await tester.startGesture(
        tester.getCenter(find.bySemanticsLabel('Colour at 100%')),
      );
      // Past the slop first, as a finger goes, then the rest of the way.
      await drag.moveBy(const Offset(-20, 0));
      await drag.moveBy(const Offset(-100, 0));
      await tester.pump();
      expect(find.bySemanticsLabel('Colour at 100%'), findsNothing);
      // Shown while dragged, and kept only once let go.
      expect(inUse(container), _redToBlue);

      await drag.up();
      await tester.pumpAndSettle();
      expect(inUse(container).stops.last.position, lessThan(1));
      expect(saved().mapGradient, inUse(container));
    });

    testWidgets('sets a colour from hex, and reverses', (tester) async {
      final container = await pumpEditor(
        tester,
        settings: const AppSettings(mapGradient: _redToBlue),
      );

      // The first colour is the one chosen to begin with.
      await tester.enterText(find.widgetWithText(TextField, 'Hex'), '#00FF00');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(inUse(container).colorAt(0), const Color(0xFF00FF00));

      await tester.tap(find.text('Reverse'));
      await tester.pumpAndSettle();
      expect(inUse(container).colorAt(0), _blue);
      expect(inUse(container).colorAt(1), const Color(0xFF00FF00));
      expect(saved().mapGradient, inUse(container));
    });

    testWidgets('saves a preset, which can be deleted - unlike the built-in '
        'ones', (tester) async {
      final container = await pumpEditor(
        tester,
        settings: const AppSettings(mapGradient: _redToBlue),
      );
      expect(find.byTooltip('Delete FoxTune'), findsNothing);

      await tester.tap(find.text('Save as preset'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Race day',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsProvider).savedGradients.single.name,
        'Race day',
      );
      expect(saved().savedGradients.single.name, 'Race day');
      expect(inUse(container).name, 'Race day');
      expect(find.text('Saved'), findsOneWidget);

      final delete = find.byTooltip('Delete Race day');
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(container.read(appSettingsProvider).savedGradients, isEmpty);
      expect(find.text('Saved'), findsNothing);
      // Deleting the preset leaves the maps as they were.
      expect(inUse(container).sameColoursAs(_redToBlue), isTrue);
    });

    testWidgets('will not save over a built-in preset\'s name', (tester) async {
      final container = await pumpEditor(tester);
      await tester.tap(find.text('Save as preset'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Viridis',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('is a built-in preset'), findsOneWidget);
      expect(container.read(appSettingsProvider).savedGradients, isEmpty);
    });
  });

  testWidgets('App settings shows the gradient in use, and leads to the '
      'editor', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final doc = IniParser(defined: {'CELSIUS'})
        .parse(File('assets/speeduino.ini').readAsStringSync());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialAppSettingsProvider.overrideWithValue(
            AppSettings(mapGradient: builtInGradients[3]),
          ),
          bundledDefinitionProvider.overrideWith((ref) async => doc),
        ],
        child: const MaterialApp(home: AppSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(ListTile, 'Map colours');
    await tester.scrollUntilVisible(tile, 100);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: tile, matching: find.text('Viridis')),
      findsOneWidget,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byType(MapColoursScreen), findsOneWidget);
  });
}
