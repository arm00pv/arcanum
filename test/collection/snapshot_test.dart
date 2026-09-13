import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A catalogue whose live price can be moved, so a snapshot can be shown to
/// record today's price rather than whatever happened to be cached.
class _MovableCatalog implements CardCatalog {
  _MovableCatalog(this.game);

  @override
  final CardGame game;

  /// The price the provider would report right now.
  double livePrice = 10.0;

  /// Makes the provider fail, the way an offline device does.
  bool failing = false;

  int refreshCalls = 0;
  List<String> refreshed = const <String>[];

  @override
  String get sourceName => 'test';

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    refreshCalls++;
    refreshed = cards.map((c) => c.id).toList();
    if (failing) throw const CatalogException('offline');
    return <TcgCard>[
      for (final card in cards)
        card.copyWith(
          prices: TcgPrices(byFinish: {CardFinish.nonfoil.code: livePrice}),
        ),
    ];
  }

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async => const [];

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async => const [];

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async =>
      const [];

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async => const [];
}

/// A printing cached at $10.
TcgCard _cachedCard() => TcgCard(
  game: CardGame.mtg,
  id: 'c1',
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Test Card',
  collectorNumber: '1',
  rarity: 'rare',
  prices: TcgPrices(byFinish: {CardFinish.nonfoil.code: 10.0}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CatalogDao catalogDao;
  late _MovableCatalog catalog;
  late CollectionRepository collection;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await AppDatabase.openInMemory();
    catalogDao = CatalogDao(db.db);
    catalog = _MovableCatalog(CardGame.mtg);
    final catalogs = CatalogRepository(
      catalogs: <CardGame, CardCatalog>{CardGame.mtg: catalog},
      dao: catalogDao,
    );
    final settings = await AppSettings.load();
    collection = CollectionRepository(
      game: CardGame.mtg,
      collectionDao: CollectionDao(db.db),
      catalogDao: catalogDao,
      historyDao: HistoryDao(db.db),
      history: PriceHistoryService(dao: HistoryDao(db.db), settings: settings),
      catalogs: catalogs,
      settings: settings,
    );
    await catalogDao.upsertCards(CardGame.mtg, <TcgCard>[_cachedCard()]);
    await collection.addCard(cardId: 'c1', quantity: 1);
  });

  tearDown(() async => db.close());

  /// The most recent price recorded for a card.
  Future<double?> recorded(String cardId) async {
    final rows = await db.db.query(
      'price_history',
      where: 'card_id = ?',
      whereArgs: <Object?>[cardId],
      orderBy: 'date DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['price'] as num?)?.toDouble();
  }

  test('records today\'s price, not the one left in the cache', () async {
    catalog.livePrice = 25.0;

    await collection.recordDailySnapshot(force: true);

    expect(catalog.refreshCalls, 1);
    expect(catalog.refreshed, <String>['c1']);
    expect(await recorded('c1'), 25.0);

    // The cache is left holding the fresh price too, so the rest of the app
    // shows the same number the history just recorded.
    final cached = await catalogDao.cardById(CardGame.mtg, 'c1');
    expect(cached!.prices.from, 25.0);
  });

  test('falls back to the cached price when the provider is offline', () async {
    catalog.livePrice = 25.0;
    catalog.failing = true;

    final written = await collection.recordDailySnapshot(force: true);

    // A failed refresh must not lose the day: the stale price is better than
    // a hole in the series.
    expect(written, greaterThan(0));
    expect(await recorded('c1'), 10.0);
  });

  test('does not call the provider when nothing is owned', () async {
    await collection.removeEntry(
      (await collection.entriesForCard('c1')).single.id!,
    );

    final written = await collection.recordDailySnapshot(force: true);

    expect(written, 0);
    expect(catalog.refreshCalls, 0);
  });

  test('only one snapshot is written per day unless forced', () async {
    await collection.recordDailySnapshot(force: true);
    catalog.livePrice = 99.0;

    final second = await collection.recordDailySnapshot();

    expect(second, 0);
    expect(await recorded('c1'), 10.0);
  });
}
