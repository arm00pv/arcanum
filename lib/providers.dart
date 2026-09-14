import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/data/catalog/lorcana_catalog.dart';
import 'package:arcanum/data/catalog/mtg_catalog.dart';
import 'package:arcanum/data/catalog/pokemon_catalog.dart';
import 'package:arcanum/data/catalog/tcgcsv_catalog.dart';
import 'package:arcanum/data/catalog/ygo_catalog.dart';
import 'package:arcanum/data/db/alert_dao.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/lots_dao.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/domain/portfolio/realised.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/db/box_dao.dart';
import 'package:arcanum/data/db/sealed_dao.dart';
import 'package:arcanum/data/db/wanted_dao.dart';
import 'package:arcanum/data/decks/ban_list_service.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/identity/identity_service.dart';
import 'package:arcanum/data/repositories/alert_repository.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/data/repositories/deck_repository.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/data/security/app_lock.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_format.dart';
import 'package:arcanum/domain/decks/deck_suggestions.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:arcanum/domain/models/set_completion.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/portfolio_change.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// The phone's own authentication: a fingerprint, a face, or the screen lock.
///
/// One provider so the lock screen and the Settings switch ask the same device
/// the same question, and so a test can supply a device that always says yes.
final deviceAuthProvider = Provider<DeviceAuth>((ref) => LocalDeviceAuth());

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
    required this.lotsDao,
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

  /// The purchases behind the stacks, and the sales matched against them.
  final LotsDao lotsDao;
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
    final lotsDao = LotsDao(database.db);
    final historyDao = HistoryDao(database.db);
    final alertDao = AlertDao(database.db);
    final historyService = PriceHistoryService(
      dao: historyDao,
      settings: settings,
    );

    final resolvedCatalogs =
        catalogs ??
        <CardGame, CardCatalog>{
          CardGame.mtg: MtgCatalog(),
          CardGame.pokemon: PokemonCatalog(),
          CardGame.yugioh: YgoCatalog(),
          CardGame.lorcana: LorcanaCatalog(),
          // The three games TCGplayer catalogs itself share one adapter: the
          // provider's shape is the same for all of them and only the category
          // id and the name of the colour field differ.
          CardGame.onePiece: TcgcsvCatalog.onePiece(),
          CardGame.starWarsUnlimited: TcgcsvCatalog.starWarsUnlimited(),
          CardGame.digimon: TcgcsvCatalog.digimon(),
          CardGame.dragonBall: TcgcsvCatalog.dragonBall(),
          CardGame.gundam: TcgcsvCatalog.gundam(),
        };

    final catalogRepository = CatalogRepository(
      catalogs: resolvedCatalogs,
      dao: catalogDao,
    );

    final collections = <CardGame, CollectionRepository>{
      for (final game in CardGame.values)
        game: CollectionRepository(
          game: game,
          collectionDao: collectionDao,
          lotsDao: lotsDao,
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
      lotsDao: lotsDao,
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

final settingsProvider = Provider<AppSettings>(
  (ref) => ref.watch(bootstrapProvider).settings,
);

final catalogRepositoryProvider = Provider<CatalogRepository>(
  (ref) => ref.watch(bootstrapProvider).catalog,
);

final historyServiceProvider = Provider<PriceHistoryService>(
  (ref) => ref.watch(bootstrapProvider).historyService,
);

final alertRepositoryProvider = Provider<AlertRepository>(
  (ref) => ref.watch(bootstrapProvider).alerts,
);

/// Keeps a copy of the collector's own data on their own server.
///
/// Its own provider rather than a method on the bootstrap, because everything
/// it does is user-initiated: nothing here runs unless the collector presses a
/// button in Settings.
final backupServiceProvider = Provider<BackupService>((ref) {
  final bootstrap = ref.watch(bootstrapProvider);
  return BackupService(
    database: bootstrap.database,
    settings: bootstrap.settings,
  );
});

/// Signing in to the collector's own server, without a password.
///
/// A provider of its own for the same reason the backup service has one:
/// nothing here happens unless the collector presses a button, and the one
/// thing it writes is the token the rest of the app already uses.
final identityServiceProvider = Provider<IdentityService>((ref) {
  final bootstrap = ref.watch(bootstrapProvider);
  return IdentityService(settings: bootstrap.settings);
});

// --------------------------------------------------------------------- alerts

/// Every alert for a game, armed ones first.
final alertsProvider = FutureProvider.family<List<PriceAlert>, CardGame>((
  ref,
  game,
) async {
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

final alertRevisionProvider = NotifierProvider<AlertRevision, int>(
  AlertRevision.new,
);

/// Alerts for one printing.
final cardAlertsProvider = FutureProvider.family<List<PriceAlert>, CardRef>((
  ref,
  ref0,
) async {
  ref.watch(alertRevisionProvider);
  return ref.watch(alertRepositoryProvider).forCard(ref0.game, ref0.id);
});

/// How many alerts have fired and not been acknowledged, per game.
final triggeredAlertCountProvider = FutureProvider.family<int, CardGame>((
  ref,
  game,
) async {
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
final alertEvaluationProvider = FutureProvider<List<AlertEvaluation>>((
  ref,
) async {
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

final activeGameProvider = NotifierProvider<ActiveGameNotifier, CardGame>(
  ActiveGameNotifier.new,
);

/// Convenience: the game-scoped collection repository for the active game.
final activeCollectionProvider = Provider<CollectionRepository>(
  (ref) =>
      ref.watch(bootstrapProvider).collectionFor(ref.watch(activeGameProvider)),
);

// ------------------------------------------------------------------ catalogue

/// A game's full set catalogue, newest first.
final setsProvider = FutureProvider.family<List<TcgSet>, CardGame>((
  ref,
  game,
) async {
  return ref.watch(catalogRepositoryProvider).loadSets(game);
});

/// How many sets a game has cached.
final setCountProvider = FutureProvider.family<int, CardGame>((
  ref,
  game,
) async {
  await ref.watch(setsProvider(game).future);
  return ref.watch(catalogRepositoryProvider).setCount(game);
});

/// How many sets exist per set type, for the filter row.
final setTypeCountsProvider = FutureProvider.family<Map<String, int>, CardGame>(
  (ref, game) async {
    await ref.watch(setsProvider(game).future);
    return ref.watch(catalogRepositoryProvider).setTypeCounts(game);
  },
);

/// Identifies a set within a game.
typedef SetRef = ({CardGame game, String code});

/// A single set's metadata from the cache.
final setProvider = FutureProvider.family<TcgSet?, SetRef>((ref, ref0) async {
  await ref.watch(setsProvider(ref0.game).future);
  return ref.watch(catalogRepositoryProvider).set(ref0.game, ref0.code);
});

/// Every printing of a set, ordered by collector number.
final setCardsProvider = FutureProvider.family<List<TcgCard>, SetRef>((
  ref,
  ref0,
) async {
  return ref.watch(catalogRepositoryProvider).cardsInSet(ref0.game, ref0.code);
});

/// Identifies a printing within a game.
typedef CardRef = ({CardGame game, String id});

/// A single printing, resolved from cache or the network.
final cardProvider = FutureProvider.family<TcgCard?, CardRef>((
  ref,
  ref0,
) async {
  return ref.watch(catalogRepositoryProvider).resolveCard(ref0.game, ref0.id);
});

/// All reprints of a card, identified by its group id.
final printingsProvider = FutureProvider.family<List<TcgCard>, CardRef>((
  ref,
  ref0,
) async {
  return ref.watch(catalogRepositoryProvider).printingsOf(ref0.game, ref0.id);
});

/// Identifies a search query within a game.
typedef SearchRef = ({CardGame game, String query});

/// Free-text search across a game's catalogue.
final searchProvider = FutureProvider.family<List<TcgCard>, SearchRef>((
  ref,
  ref0,
) async {
  if (ref0.query.trim().length < 2) return const [];
  return ref.watch(catalogRepositoryProvider).search(ref0.game, ref0.query);
});

/// Sets whose name or code matches the same query.
///
/// The set catalogue is fetched before matching so that a first search still
/// finds a set the user has never opened; after that it is a cache read.
final setSearchProvider = FutureProvider.family<List<TcgSet>, SearchRef>((
  ref,
  ref0,
) async {
  if (ref0.query.trim().length < 2) return const [];
  await ref.watch(setsProvider(ref0.game).future);
  return ref.watch(catalogRepositoryProvider).searchSets(ref0.game, ref0.query);
});

// ----------------------------------------------------------------- collection

/// The full portfolio picture for a game.
final collectionOverviewProvider =
    FutureProvider.family<CollectionOverview, CardGame>((ref, game) async {
      return ref
          .watch(bootstrapProvider)
          .collectionFor(game)
          .overview(withMovers: true);
    });

/// Full card data for every printing the user owns in a game.
final ownedCardsProvider =
    FutureProvider.family<Map<String, TcgCard>, CardGame>((ref, game) async {
      await ref.watch(collectionOverviewProvider(game).future);
      final ids = await ref
          .watch(bootstrapProvider)
          .collectionDao
          .ownedCardIds(game);
      return ref.watch(catalogRepositoryProvider).cardsByIds(game, ids);
    });

/// How many copies the user owns of each printing in a game.
final ownedQuantityProvider = FutureProvider.family<Map<String, int>, CardGame>(
  (ref, game) async {
    await ref.watch(collectionOverviewProvider(game).future);
    final rows = await ref.watch(bootstrapProvider).database.db.rawQuery(
      'SELECT card_id, SUM(quantity) AS n FROM collection_entries '
      'WHERE game = ? GROUP BY card_id',
      [game.id],
    );
    return {
      for (final r in rows)
        (r['card_id'] as String): (r['n'] as num?)?.toInt() ?? 0,
    };
  },
);

/// When the catalogue's prices for a game were last refreshed.
///
/// Null until prices have been fetched at least once, which a report says
/// rather than pretending the figures are current.
final pricesAsOfProvider = FutureProvider.family<DateTime?, CardGame>(
  (ref, game) => ref.watch(bootstrapProvider).catalogDao.latestPricesAt(game),
);

/// How many physical cards the user owns from each set, keyed by set code.
final ownedBySetProvider = FutureProvider.family<Map<String, int>, CardGame>((
  ref,
  game,
) async {
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
      return ref
          .watch(bootstrapProvider)
          .collectionFor(ref0.game)
          .entriesForCard(ref0.id);
    });

/// The portfolio value series for a game, for the dashboard chart.
final portfolioSeriesProvider =
    FutureProvider.family<List<PricePoint>, CardGame>((ref, game) async {
      await ref.watch(collectionOverviewProvider(game).future);
      return ref.watch(bootstrapProvider).collectionFor(game).portfolioSeries();
    });

/// The portfolio curve with the card count of each day, for the dashboard.
///
/// Its own provider rather than a change to [portfolioSeriesProvider]: the count
/// is only needed where the change is captioned, and one extra column should not
/// change what every other caller of the series receives.
final portfolioHistoryProvider =
    FutureProvider.family<List<PortfolioPoint>, CardGame>((ref, game) async {
      await ref.watch(collectionOverviewProvider(game).future);
      return ref
          .watch(bootstrapProvider)
          .collectionFor(game)
          .portfolioHistory();
    });

/// Headline figures for every game, used by the switcher.
final gameSummariesProvider = FutureProvider<Map<CardGame, GameSummary>>((
  ref,
) async {
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

// ------------------------------------------------------------------- wants

/// Reads and writes the collector's wants list.
///
/// A plain DAO over the shared database rather than part of the bootstrap: a
/// want is one table with no catalogue, no network and no repository of its
/// own to coordinate.
final wantedDaoProvider = Provider<WantedDao>(
  (ref) => WantedDao(ref.watch(bootstrapProvider).database.db),
);

/// Bumped whenever a want is added or removed, so the screens that show them
/// recompute without every caller remembering to invalidate three providers.
class WantedRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that the wants list changed.
  void bump() => state = state + 1;
}

final wantedRevisionProvider = NotifierProvider<WantedRevision, int>(
  WantedRevision.new,
);

/// The wanted printings of a game, most recently wanted first.
final wantedIdsProvider = FutureProvider.family<List<String>, CardGame>((
  ref,
  game,
) async {
  ref.watch(wantedRevisionProvider);
  return ref.watch(wantedDaoProvider).ids(game);
});

/// The wanted printings of a game, with their catalogue data.
///
/// The wants list holds ids; everything worth showing about a card - its name,
/// its set, its price - lives in the catalogue, which is why this is a second
/// provider rather than a join in the DAO.
final wantedCardsProvider = FutureProvider.family<List<TcgCard>, CardGame>((
  ref,
  game,
) async {
  final ids = await ref.watch(wantedIdsProvider(game).future);
  if (ids.isEmpty) return const <TcgCard>[];
  final byId = await ref.watch(catalogRepositoryProvider).cardsByIds(game, ids);
  // In the order they were wanted, not the order cardsByIds returned them.
  return <TcgCard>[
    for (final id in ids)
      if (byId[id] != null) byId[id]!,
  ];
});

/// How many printings are wanted in a game, for the tab badge.
final wantedCountProvider = FutureProvider.family<int, CardGame>((
  ref,
  game,
) async {
  ref.watch(wantedRevisionProvider);
  return ref.watch(wantedDaoProvider).count(game);
});

// ------------------------------------------------------------------ cost basis

/// Bumped whenever a sale is recorded or undone.
///
/// The purchases screen, the card screen and the tax-year export all read the
/// same ledger, and a bump is cheaper and less error-prone than every caller
/// knowing which three providers to invalidate.
class CostBasisRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that the sales ledger changed.
  void bump() => state = state + 1;
}

final costBasisRevisionProvider = NotifierProvider<CostBasisRevision, int>(
  CostBasisRevision.new,
);

/// Everything sold in one game, grouped by tax year, with the names attached.
///
/// The names come from the local catalogue: a sale of a card from a set that
/// has since been removed from the phone still has to be readable on a tax
/// sheet, so the id is the fallback rather than an empty cell.
final realisedProvider = FutureProvider.family<Realised, CardGame>((
  ref,
  game,
) async {
  ref.watch(costBasisRevisionProvider);
  final sales = await ref.watch(bootstrapProvider).collectionFor(game).sales();
  if (sales.isEmpty) return Realised.of(const <SaleRow>[]);
  final byId = await ref
      .watch(catalogRepositoryProvider)
      .cardsByIds(
        game,
        <String>{for (final sale in sales) sale.cardId}.toList(),
      );
  return Realised.of(<SaleRow>[
    for (final sale in sales)
      SaleRow(
        sale: sale,
        name: byId[sale.cardId]?.name ?? sale.cardId,
        setCode: byId[sale.cardId]?.setCode ?? '',
        setName: byId[sale.cardId]?.setName ?? '',
      ),
  ]);
});

/// A printing's own purchases and sales, for the card screen.
final cardCostBasisProvider =
    FutureProvider.family<CardCostBasis, (CardGame, String)>((ref, key) async {
      ref.watch(costBasisRevisionProvider);
      final repository = ref.watch(bootstrapProvider).collectionFor(key.$1);
      return CardCostBasis(
        lots: await repository.lotsForCard(key.$2),
        sales: await repository.salesForCard(key.$2),
      );
    });

/// What one printing's purchases and sales are.
class CardCostBasis {
  /// Creates the pair.
  const CardCostBasis({required this.lots, required this.sales});

  /// The purchases behind it, oldest first.
  final List<CardLot> lots;

  /// What has been sold out of it, newest first.
  final List<CardSale> sales;
}

// -------------------------------------------------------------- sealed product

/// Reads and writes the collector's sealed product.
final sealedDaoProvider = Provider<SealedDao>(
  (ref) => SealedDao(ref.watch(bootstrapProvider).database.db),
);

/// Bumped whenever the sealed shelf changes, so screens recompute without every
/// caller remembering to invalidate three providers.
class SealedRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that the shelf changed.
  void bump() => state = state + 1;
}

final sealedRevisionProvider = NotifierProvider<SealedRevision, int>(
  SealedRevision.new,
);

/// The sealed holdings of one game, added up.
final sealedPortfolioProvider =
    FutureProvider.family<SealedPortfolio, CardGame>((ref, game) async {
      ref.watch(sealedRevisionProvider);
      return SealedPortfolio.of(await ref.watch(sealedDaoProvider).all(game));
    });

/// Reads and writes what each set's boxes are assumed to hold.
final boxDaoProvider = Provider<BoxDao>(
  (ref) => BoxDao(ref.watch(bootstrapProvider).database.db),
);

/// Bumped whenever a box composition is stated or changed.
class BoxRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that a composition changed.
  void bump() => state = state + 1;
}

final boxRevisionProvider = NotifierProvider<BoxRevision, int>(BoxRevision.new);

/// What a set's boxes are assumed to hold, or null when nobody has said.
///
/// Null is not the same as an empty box: it means the app has nothing to value
/// the box with, and every screen that reads this has to say so rather than
/// showing a box worth nothing.
final boxCompositionProvider = FutureProvider.family<BoxComposition?, SetRef>((
  ref,
  key,
) async {
  ref.watch(boxRevisionProvider);
  return ref.watch(boxDaoProvider).forSet(key.game, key.code);
});

/// Sealed products a price list knows about for one set.
///
/// Fetched on demand, for the one set somebody is adding a box from, rather than
/// pulled wholesale: the phone has no business holding every product of every
/// set it will never buy.
final sealedOffersProvider = FutureProvider.family<List<SealedOffer>, SetRef>((
  ref,
  key,
) async {
  final settings = ref.watch(settingsProvider);
  return CompanionSealedSource(endpoint: settings.historyEndpoint)
      .forSet(key.game, key.code);
});

// ----------------------------------------------------------------- set progress

/// How much of each cached set of a game the collector owns.
///
/// A holding changes this answer, so the collection overview is watched first.
/// A download changes it too - a set of 180 becomes completable only once its
/// 180 printings are on disk - which is why the set screen invalidates this
/// provider after it stores a set rather than this one watching the catalogue.
final setCompletionProvider =
    FutureProvider.family<Map<String, SetCompletion>, CardGame>((
      ref,
      game,
    ) async {
      await ref.watch(collectionOverviewProvider(game).future);
      return ref.watch(bootstrapProvider).catalogDao.setCompletion(game);
    });

// -------------------------------------------------------------------- decks

/// Reads and writes decks and the cards in them.
final deckDaoProvider = Provider<DeckDao>(
  (ref) => DeckDao(ref.watch(bootstrapProvider).database.db),
);

/// Decks, with their cards priced against the catalogue.
final deckRepositoryProvider = Provider<DeckRepository>(
  (ref) => DeckRepository(
    dao: ref.watch(deckDaoProvider),
    catalog: ref.watch(catalogRepositoryProvider),
  ),
);

/// Bumped whenever a deck or its contents change.
class DeckRevision extends Notifier<int> {
  @override
  int build() => 0;

  /// Signals that the decks changed.
  void bump() => state = state + 1;
}

final deckRevisionProvider = NotifierProvider<DeckRevision, int>(
  DeckRevision.new,
);

/// Every deck of a game, priced and counted against what is owned.
final decksProvider = FutureProvider.family<List<DeckContents>, CardGame>((
  ref,
  game,
) async {
  ref.watch(deckRevisionProvider);
  final owned = await ref.watch(ownedQuantityProvider(game).future);
  return ref.watch(deckRepositoryProvider).all(game, owned: owned);
});

/// One deck by id, priced and counted against what is owned.
final deckProvider = FutureProvider.family<DeckContents?, int>((
  ref,
  deckId,
) async {
  ref.watch(deckRevisionProvider);
  final repository = ref.watch(deckRepositoryProvider);
  final deck = await repository.contents(deckId);
  if (deck == null) return null;
  final owned = await ref.watch(ownedQuantityProvider(deck.deck.game).future);
  return repository.contents(deckId, owned: owned);
});

/// Cards the collector owns that would fit one deck, best first.
///
/// Recomputed whenever the deck changes, so adding a suggestion takes it off
/// the list - which is the honest answer to 'what else could go in here'.
final deckSuggestionsProvider =
    FutureProvider.family<List<DeckSuggestion>, int>((ref, deckId) async {
      ref.watch(deckRevisionProvider);
      final contents = await ref.watch(deckProvider(deckId).future);
      if (contents == null) return const <DeckSuggestion>[];
      final game = contents.deck.game;
      final owned = await ref.watch(ownedCardsProvider(game).future);
      final quantities = await ref.watch(ownedQuantityProvider(game).future);
      final bans = await ref.watch(
        banListProvider(contents.deck.formatId).future,
      );
      return suggestForDeck(
        contents: contents,
        ownedCards: owned,
        ownedQuantities: quantities,
        bannedNames: bans?.names ?? const <String>{},
      );
    });

/// How many decks hold one printing, for the card screen.
final cardDeckCountProvider = FutureProvider.family<int, CardRef>((
  ref,
  card,
) async {
  ref.watch(deckRevisionProvider);
  return ref.watch(deckDaoProvider).decksHolding(card.game, card.id);
});

/// A format's banned list, fetched once and cached in the database.
///
/// Null for formats with no list Arcanum can check, and null while a first
/// fetch is in flight; the legality check reads null as 'not checked' rather
/// than as 'nothing is banned'.
final banListProvider = FutureProvider.family<BanList?, String>((
  ref,
  formatId,
) async {
  final format = DeckFormats.byId(formatId);
  if (format == null || !format.checksBanList) return null;
  return BanListService(db: ref.watch(bootstrapProvider).database.db)
      .get(format);
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

/// Identifies a back-test: one collection, one forecast horizon.
typedef ForecastAuditKey = ({CardGame game, int horizonDays});

/// The payload handed to the isolate that runs a back-test.
typedef ForecastAuditRequest = ({
  String label,
  List<BacktestSeries> series,
  int horizonDays,
});

/// Runs a back-test on a background isolate.
///
/// Top-level and single-argument because that is what [compute] requires. The
/// arithmetic refits the model the card screen would have shown, once per
/// prediction, which is far too much to do between two frames.
ForecastAudit runForecastAuditInIsolate(ForecastAuditRequest request) =>
    runForecastAudit(
      gameLabel: request.label,
      series: request.series,
      horizonDays: request.horizonDays,
    );

/// Back-tests the app's own trend reading and forecast on this phone's own
/// history.
///
/// Reads only what is already stored - no network, no catalogue, no price
/// refresh - and then scores the model against what actually happened. A
/// collection with no recorded history produces an audit that says exactly
/// that rather than an empty set of zeros.
final forecastAuditProvider =
    FutureProvider.family<ForecastAudit, ForecastAuditKey>((ref, key) async {
      final bootstrap = ref.watch(bootstrapProvider);
      final ids = await bootstrap.collectionDao.ownedCardIds(key.game);
      final series = ids.isEmpty
          ? const <BacktestSeries>[]
          : await bootstrap.historyDao
                .seriesForCards(
                  key.game,
                  ids,
                  finish: key.game.finishes.first,
                  days: 400,
                )
                .then(
                  (Map<String, List<PricePoint>> byCard) => <BacktestSeries>[
                    for (final MapEntry<String, List<PricePoint>> e
                        in byCard.entries)
                      BacktestSeries(e.key, e.value),
                  ],
                );
      return compute(runForecastAuditInIsolate, (
        label: key.game.label,
        series: series,
        horizonDays: key.horizonDays,
      ));
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
