import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/mtg_catalog.dart';
import 'package:arcanum/data/catalog/pokemon_catalog.dart';
import 'package:arcanum/data/catalog/ygo_catalog.dart';
import 'package:arcanum/data/db/alert_dao.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/repositories/alert_repository.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// A headline figure for one game, used by the game switcher and the drawer.
class GameSummary {
  const GameSummary({
    required this.game,
    required this.totalCards,
    required this.uniqueCards,
    required this.totalValue,
    required this.setCount,
    required this.hasCatalog,
  });

  final CardGame game;
  final int totalCards;
  final int uniqueCards;
  final double totalValue;
  final int setCount;

  /// Whether the catalogue for this game has been downloaded at least once.
  final bool hasCatalog;

  bool get isEmpty => totalCards == 0 && !hasCatalog;
}

/// Everything the app needs, constructed once during bootstrap.
///
/// Passing a single object down through an override keeps the dependency graph
/// explicit and makes the whole app trivially testable: a test overrides
/// [bootstrapProvider] with in-memory fakes.
class Bootstrap {
  Bootstrap({
    required this.database,
    required this.settings,
    required this.catalogDao,
    required this.collectionDao,
    required this.historyDao,
    required this.alertDao,
    required this.historyService,
    required this.catalog,
    required this.collections,
    required this.catalogs,
    required this.alerts,
  });

  final AppDatabase database;
  final AppSettings settings;
  final CatalogDao catalogDao;
  final CollectionDao collectionDao;
  final HistoryDao historyDao;
  final PriceHistoryService historyService;
  final CatalogRepository catalog;

  /// One collection repository per game. They never share state.
  final Map<CardGame, CollectionRepository> collections;

  /// One card catalogue per game.
  final Map<CardGame, CardCatalog> catalogs;

  final AlertDao alertDao;

  /// Alerts are evaluated across every game at once, so there is one repository
  /// rather than one per game.
  final AlertRepository alerts;

  /// The collection repository for a game.
  CollectionRepository collectionFor(CardGame game) => collections[game]!;

  /// Wires the object graph. The only place construction order matters.
  static Bootstrap create({
    required AppDatabase database,
    required AppSettings settings,
    Map<CardGame, CardCatalog>? catalogs,
  }) {
    final catalogDao = CatalogDao(database.db);
    final collectionDao = CollectionDao(database.db);
    final historyDao = HistoryDao(database.db);
    final alertDao = AlertDao(database.db);
    final historyService = PriceHistoryService(dao: historyDao, settings: settings);

    final resolvedCatalogs = catalogs ??
        <CardGame, CardCatalog>{
          CardGame.mtg: MtgCatalog(),
          CardGame.pokemon: PokemonCatalog(),
          CardGame.yugioh: YgoCatalog(),
        };

    final catalogRepository =
        CatalogRepository(catalogs: resolvedCatalogs, dao: catalogDao);

    final collections = <CardGame, CollectionRepository>{
      for (final game in CardGame.values)
        game: CollectionRepository(
          game: game,
          collectionDao: collectionDao,
          catalogDao: catalogDao,
          historyDao: historyDao,
          history: historyService,
          catalogs: catalogRepository,
          settings: settings,
        ),
    };

    return Bootstrap(
      database: database,
      settings: settings,
      catalogDao: catalogDao,
      collectionDao: collectionDao,
      historyDao: historyDao,
      alertDao: alertDao,
      historyService: historyService,
      catalog: catalogRepository,
      collections: collections,
      catalogs: resolvedCatalogs,
      alerts: AlertRepository(dao: alertDao, catalogDao: catalogDao),
    );
  }
}

/// Overridden in `main()` with the real graph.
final bootstrapProvider = Provider<Bootstrap>(
  (ref) => throw UnimplementedError('bootstrapProvider must be overridden'),
);

final settingsProvider =
    Provider<AppSettings>((ref) => ref.watch(bootstrapProvider).settings);

final catalogRepositoryProvider =
    Provider<CatalogRepository>((ref) => ref.watch(bootstrapProvider).catalog);

final historyServiceProvider =
    Provider<PriceHistoryService>((ref) => ref.watch(bootstrapProvider).historyService);

final alertRepositoryProvider =
    Provider<AlertRepository>((ref) => ref.watch(bootstrapProvider).alerts);

// --------------------------------------------------------------------- alerts

/// Every alert for a game, armed ones first.
final alertsProvider =
    FutureProvider.family<List<PriceAlert>, CardGame>((ref, game) async {
  ref.watch(alertRevisionProvider);
  return ref.watch(alertRepositoryProvider).all(game);
});

/// Bumped whenever an alert is created, deleted or re-armed, so the alert
/// providers recompute without duplicating mutation logic in the UI.
class AlertRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that the alert set changed.
  void bump() => state = state + 1;
}

final alertRevisionProvider = NotifierProvider<AlertRevision, int>(AlertRevision.new);

/// Alerts for one printing.
final cardAlertsProvider =
    FutureProvider.family<List<PriceAlert>, CardRef>((ref, ref0) async {
  ref.watch(alertRevisionProvider);
  return ref.watch(alertRepositoryProvider).forCard(ref0.game, ref0.id);
});

/// How many alerts have fired and not been acknowledged, per game.
final triggeredAlertCountProvider =
    FutureProvider.family<int, CardGame>((ref, game) async {
  ref.watch(alertRevisionProvider);
  return ref.watch(alertRepositoryProvider).triggeredCount(game);
});

/// Card data for every printing that has an alert in a game.
final alertCardsProvider =
    FutureProvider.family<Map<String, TcgCard>, CardGame>((ref, game) async {
  final alerts = await ref.watch(alertsProvider(game).future);
  final ids = alerts.map((a) => a.cardId).toSet().toList();
  if (ids.isEmpty) return const {};
  return ref.watch(catalogRepositoryProvider).cardsByIds(game, ids);
});

/// Evaluates every armed alert across all games.
///
/// Runs against stored prices, which are already refreshed daily. Invalidate
/// this to re-check after a price refresh.
final alertEvaluationProvider = FutureProvider<List<AlertEvaluation>>((ref) async {
  ref.watch(alertRevisionProvider);
  return ref.watch(alertRepositoryProvider).evaluate();
});

/// The game the whole app is currently scoped to.
///
/// Every catalogue, collection, portfolio and price series below is keyed by
/// this value, so switching games swaps the entire app over rather than merging
/// anything.
class ActiveGameNotifier extends Notifier<CardGame> {
  @override
  CardGame build() => ref.read(settingsProvider).activeGame;

  /// Switches the app to another game.
  void select(CardGame game) {
    if (state == game) return;
    final settings = ref.read(settingsProvider);
    settings.activeGame = game;
    settings.noteGameOpened(game);
    state = game;
  }
}

final activeGameProvider =
    NotifierProvider<ActiveGameNotifier, CardGame>(ActiveGameNotifier.new);

/// Convenience: the game-scoped collection repository for the active game.
final activeCollectionProvider = Provider<CollectionRepository>(
  (ref) => ref.watch(bootstrapProvider).collectionFor(ref.watch(activeGameProvider)),
);

// ------------------------------------------------------------------ catalogue

/// A game's full set catalogue, newest first.
final setsProvider =
    FutureProvider.family<List<TcgSet>, CardGame>((ref, game) async {
  return ref.watch(catalogRepositoryProvider).loadSets(game);
});

/// How many sets a game has cached.
final setCountProvider = FutureProvider.family<int, CardGame>((ref, game) async {
  await ref.watch(setsProvider(game).future);
  return ref.watch(catalogRepositoryProvider).setCount(game);
});

/// How many sets exist per set type, for the filter row.
final setTypeCountsProvider =
    FutureProvider.family<Map<String, int>, CardGame>((ref, game) async {
  await ref.watch(setsProvider(game).future);
  return ref.watch(catalogRepositoryProvider).setTypeCounts(game);
});

/// Identifies a set within a game.
typedef SetRef = ({CardGame game, String code});

/// A single set's metadata from the cache.
final setProvider = FutureProvider.family<TcgSet?, SetRef>((ref, ref0) async {
  await ref.watch(setsProvider(ref0.game).future);
  return ref.watch(catalogRepositoryProvider).set(ref0.game, ref0.code);
});

/// Every printing of a set, ordered by collector number.
final setCardsProvider =
    FutureProvider.family<List<TcgCard>, SetRef>((ref, ref0) async {
  return ref.watch(catalogRepositoryProvider).cardsInSet(ref0.game, ref0.code);
});

/// Identifies a printing within a game.
typedef CardRef = ({CardGame game, String id});

/// A single printing, resolved from cache or the network.
final cardProvider = FutureProvider.family<TcgCard?, CardRef>((ref, ref0) async {
  return ref.watch(catalogRepositoryProvider).resolveCard(ref0.game, ref0.id);
});

/// All reprints of a card, identified by its group id.
final printingsProvider =
    FutureProvider.family<List<TcgCard>, CardRef>((ref, ref0) async {
  return ref.watch(catalogRepositoryProvider).printingsOf(ref0.game, ref0.id);
});

/// Identifies a search query within a game.
typedef SearchRef = ({CardGame game, String query});

/// Free-text search across a game's catalogue.
final searchProvider =
    FutureProvider.family<List<TcgCard>, SearchRef>((ref, ref0) async {
  if (ref0.query.trim().length < 2) return const [];
  return ref.watch(catalogRepositoryProvider).search(ref0.game, ref0.query);
});

// ----------------------------------------------------------------- collection

/// The full portfolio picture for a game.
final collectionOverviewProvider =
    FutureProvider.family<CollectionOverview, CardGame>((ref, game) async {
  return ref.watch(bootstrapProvider).collectionFor(game).overview(withMovers: true);
});

/// Full card data for every printing the user owns in a game.
final ownedCardsProvider =
    FutureProvider.family<Map<String, TcgCard>, CardGame>((ref, game) async {
  await ref.watch(collectionOverviewProvider(game).future);
  final ids = await ref.watch(bootstrapProvider).collectionDao.ownedCardIds(game);
  return ref.watch(catalogRepositoryProvider).cardsByIds(game, ids);
});

/// How many copies the user owns of each printing in a game.
final ownedQuantityProvider =
    FutureProvider.family<Map<String, int>, CardGame>((ref, game) async {
  await ref.watch(collectionOverviewProvider(game).future);
  final rows = await ref.watch(bootstrapProvider).database.db.rawQuery(
        'SELECT card_id, SUM(quantity) AS n FROM collection_entries '
        'WHERE game = ? GROUP BY card_id',
        [game.id],
      );
  return {
    for (final r in rows) (r['card_id'] as String): (r['n'] as num?)?.toInt() ?? 0,
  };
});

/// How many physical cards the user owns from each set, keyed by set code.
final ownedBySetProvider =
    FutureProvider.family<Map<String, int>, CardGame>((ref, game) async {
  await ref.watch(collectionOverviewProvider(game).future);
  final rows = await ref.watch(bootstrapProvider).database.db.rawQuery(
        'SELECT c.set_code AS code, SUM(e.quantity) AS n '
        'FROM collection_entries e JOIN cards c ON c.id = e.card_id '
        'WHERE e.game = ? GROUP BY c.set_code',
        [game.id],
      );
  return {
    for (final r in rows) (r['code'] as String): (r['n'] as num?)?.toInt() ?? 0,
  };
});

/// The user's own stacks of one printing.
final cardEntriesProvider =
    FutureProvider.family<List<CollectionEntry>, CardRef>((ref, ref0) async {
  await ref.watch(collectionOverviewProvider(ref0.game).future);
  return ref.watch(bootstrapProvider).collectionFor(ref0.game).entriesForCard(ref0.id);
});

/// The portfolio value series for a game, for the dashboard chart.
final portfolioSeriesProvider =
    FutureProvider.family<List<PricePoint>, CardGame>((ref, game) async {
  await ref.watch(collectionOverviewProvider(game).future);
  return ref.watch(bootstrapProvider).collectionFor(game).portfolioSeries();
});

/// Headline figures for every game, used by the switcher.
final gameSummariesProvider = FutureProvider<Map<CardGame, GameSummary>>((ref) async {
  final bootstrap = ref.watch(bootstrapProvider);
  final out = <CardGame, GameSummary>{};
  for (final game in CardGame.values) {
    final sets = await bootstrap.catalog.setCount(game);
    final cards = await bootstrap.collectionDao.totalCardCount(game);
    final unique = await bootstrap.collectionDao.uniqueCount(game);
    final value = cards == 0
        ? 0.0
        : (await bootstrap.collectionFor(game).overview()).totalValue;
    out[game] = GameSummary(
      game: game,
      totalCards: cards,
      uniqueCards: unique,
      totalValue: value,
      setCount: sets,
      hasCatalog: sets > 0,
    );
  }
  return out;
});

// ------------------------------------------------------------------ analytics

/// Identifies one printing/finish pair for analytics lookups.
typedef AnalyticsKey = ({CardGame game, String cardId, CardFinish finish});

/// Full on-device analytics for one printing.
final cardAnalyticsProvider =
    FutureProvider.family<CardAnalytics, AnalyticsKey>((ref, key) async {
  return ref
      .watch(bootstrapProvider)
      .collectionFor(key.game)
      .analyticsFor(key.cardId, finish: key.finish);
});

/// Price history for one printing, used by the detail chart.
final priceHistoryProvider =
    FutureProvider.family<List<PricePoint>, AnalyticsKey>((ref, key) async {
  final bootstrap = ref.watch(bootstrapProvider);
  final card = await bootstrap.catalog.cardById(key.game, key.cardId);
  return bootstrap.historyService.historyFor(
    key.game,
    key.cardId,
    finish: key.finish,
    days: 400,
    cardName: card?.name,
    externalId: card?.extras['tcgplayerId']?.toString(),
  );
});
