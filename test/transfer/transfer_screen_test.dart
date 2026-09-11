import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/transfer/collection_transfer.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/transfer/transfer_screen.dart';
import 'package:arcanum/providers.dart';

/// A catalogue that answers from memory, so the screen never touches a network.
class _FakeCatalog implements CardCatalog {
  _FakeCatalog(this.game);

  @override
  final CardGame game;

  @override
  String get sourceName => 'test';

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async =>
      const [];

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async =>
      const [];

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async =>
      const [];

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async => const [];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async => cards;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late Bootstrap bootstrap;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await AppDatabase.openInMemory();
    bootstrap = Bootstrap.create(
      database: db,
      settings: await AppSettings.load(),
      catalogs: <CardGame, CardCatalog>{
        CardGame.mtg: _FakeCatalog(CardGame.mtg),
      },
    );
  });

  tearDown(() async => db.close());

  /// Pumps the screen on a tall surface with a real event loop.
  ///
  /// The taller surface matters because a [ListView] only builds what is near
  /// the viewport, and the default 800x600 test window cuts the bottom sections
  /// off entirely. The real event loop matters because the providers read
  /// SQLite through an FFI isolate, which no amount of [WidgetTester.pump] will
  /// advance on its own.
  Future<void> pumpScreen(WidgetTester tester, {double textScale = 1.0}) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapProvider.overrideWithValue(bootstrap)],
          child: MaterialApp(
            theme: AppTheme.build(dark: true),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
              child: const TransferScreen(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  testWidgets('renders every section for the active game', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Import & export'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Formats'), findsOneWidget);
    expect(find.text('Share as CSV'), findsOneWidget);
    expect(find.text('Choose a CSV file'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('says there is nothing to export when the collection is empty',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('There is nothing to export yet.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every dialect is offered and switching one updates the text',
      (tester) async {
    await pumpScreen(tester);

    for (final dialect in TransferDialect.values) {
      expect(find.widgetWithText(ChoiceChip, dialect.label), findsOneWidget);
    }

    ChoiceChip chip(String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    // Arcanum is the default.
    expect(chip('Arcanum').selected, isTrue);
    expect(chip('Moxfield').selected, isFalse);

    // The description of the chosen dialect appears twice once it is selected:
    // once as the export hint and once in the Formats reference list.
    expect(find.text(TransferDialect.arcanum.description), findsNWidgets(2));
    expect(find.text(TransferDialect.moxfield.description), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Moxfield'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(chip('Moxfield').selected, isTrue);
    expect(chip('Arcanum').selected, isFalse);
    expect(find.text(TransferDialect.moxfield.description), findsNWidgets(2));
    expect(find.text(TransferDialect.arcanum.description), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explains that matching is exact', (tester) async {
    await pumpScreen(tester);
    expect(
      find.textContaining('A row that matches nothing is reported'),
      findsOneWidget,
    );
  });

  testWidgets('lays out without overflow at 2x text scale', (tester) async {
    await pumpScreen(tester, textScale: 2.0);
    expect(tester.takeException(), isNull);
  });
}
