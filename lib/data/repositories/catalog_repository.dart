import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Coordinates the per-game catalogues and the local SQLite cache.
///
/// The rule is simple: SQLite is authoritative for display, and the network is
/// only consulted when the cache cannot answer. Card data never changes once a
/// set is printed, so a set is downloaded exactly once; prices ride along and
/// are refreshed separately.
///
/// Every method takes the game it is acting on, and routes to that game's
/// [CardCatalog]. Nothing here can accidentally mix two games together.
class CatalogRepository {
  CatalogRepository({
    required Map<CardGame, CardCatalog> catalogs,
    required CatalogDao dao,
  }) : _catalogs = catalogs,
       _dao = dao;

  final Map<CardGame, CardCatalog> _catalogs;
  final CatalogDao _dao;

  /// Sets are re-fetched when the cache is older than this.
  static const setCacheTtl = Duration(days: 7);

  /// How many of [resolveMissingCards]' requests are in flight at once.
  ///
  /// The same small number the other bulk readers in the app use: enough to
  /// keep a patient shop busy, few enough that none of them is being hammered.
  static const _resolveConcurrency = 4;

  /// How many resolved cards are written before the run carries on.
  static const _resolveFlushSize = 200;

  /// The catalogue backing a game.
  CardCatalog catalogFor(CardGame game) => _catalogs[game]!;

  /// Whether a catalogue is registered for a game.
  bool supports(CardGame game) => _catalogs.containsKey(game);

  /// Loads a game's full set catalogue, refreshing when stale.
  ///
  /// [forceRefresh] bypasses the TTL. A network failure with a warm cache is not
  /// an error: the cached catalogue is returned instead.
  Future<List<TcgSet>> loadSets(
    CardGame game, {
    bool forceRefresh = false,
    SetSort sort = SetSort.newest,
    void Function(int done, int total)? onProgress,
  }) async {
    final cachedCount = await _dao.setCount(game);
    final fetchedAt = await _dao.setsFetchedAt(game);
    final stale =
        fetchedAt == null || DateTime.now().difference(fetchedAt) > setCacheTtl;

    if (forceRefresh || cachedCount == 0 || stale) {
      try {
        final sets = await catalogFor(game)
            .fetchAllSets(onProgress: onProgress);
        if (sets.isNotEmpty) await _dao.upsertSets(game, sets);
      } catch (_) {
        if (cachedCount == 0) rethrow;
        // Otherwise fall through to the cache.
      }
    }
    return _dao.sets(game, sort: sort);
  }

  /// All sets currently in the cache for a game, with no network access.
  Future<List<TcgSet>> cachedSets(
    CardGame game, {
    String? search,
    Set<String>? types,
    bool includeDigital = false,
    SetSort sort = SetSort.newest,
  }) => _dao.sets(
    game,
    search: search,
    types: types,
    includeDigital: includeDigital,
    sort: sort,
  );

  Future<Map<String, int>> setTypeCounts(
    CardGame game, {
    bool includeDigital = false,
  }) => _dao.setTypeCounts(game, includeDigital: includeDigital);

  Future<int> setCount(CardGame game) => _dao.setCount(game);

  Future<TcgSet?> set(CardGame game, String code) => _dao.set(game, code);

  /// Every printing of a set, ordered by collector number.
  ///
  /// Downloads the set the first time it is opened and then serves it from
  /// SQLite forever after.
  Future<List<TcgCard>> cardsInSet(
    CardGame game,
    String setCode, {
    bool forceRefresh = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final code = setCode.toLowerCase();
    if (!forceRefresh && await _dao.isCatalogued(game, code)) {
      return _dao.cardsInSet(game, code);
    }
    try {
      final cards = await catalogFor(game)
          .fetchCardsInSet(code, onProgress: onProgress);
      if (cards.isNotEmpty) {
        await _dao.upsertCards(game, cards);
        // A provider that publishes no card count in its set list - Lorcast
        // does not - only reveals the size here, so the set row learns it the
        // first time the set is opened rather than claiming to hold no cards.
        await _dao.setCardCount(game, code, cards.length);
      }
      // The question was asked and answered either way, and "nothing" is an
      // answer worth keeping: it is what a set the shop has not published yet
      // returns, and a set that returned nothing is not a set to re-download on
      // every visit. [CatalogDao.isCatalogued] re-asks once a day, so a set that
      // is empty today because it is unreleased fills in when it is released.
      await _dao.markCatalogued(game, code);
    } catch (_) {
      // A network failure is only fatal when nothing is cached; otherwise the
      // user keeps browsing the copy we already have.
      final cached = await _dao.cardsInSet(game, code);
      if (cached.isEmpty) rethrow;
      return cached;
    }
    return _dao.cardsInSet(game, code);
  }

  /// Cached printings of a set without touching the network.
  Future<List<TcgCard>> cachedCardsInSet(CardGame game, String setCode) =>
      _dao.cardsInSet(game, setCode.toLowerCase());

  Future<bool> isCatalogued(CardGame game, String setCode) =>
      _dao.isCatalogued(game, setCode.toLowerCase());

  /// Whether the shop has been asked for this set's printings at all.
  ///
  /// A set the shop lists but has published no cards for - a group page opened
  /// before the set is out - is an empty list, exactly like a set that has never
  /// been downloaded. The two call for different words on screen, and this is
  /// what tells them apart.
  Future<bool> askedForCards(CardGame game, String setCode) async =>
      await _dao.cataloguedAt(game, setCode.toLowerCase()) != null;

  Future<TcgCard?> cardById(CardGame game, String id) =>
      _dao.cardById(game, id);

  /// A printing addressed by set code and collector number.
  Future<TcgCard?> cardByNumber(
    CardGame game,
    String setCode,
    String collectorNumber,
  ) => _dao.cardByNumber(game, setCode, collectorNumber);

  /// Printings of one name inside one set.
  Future<List<TcgCard>> cardsByNameInSet(
    CardGame game,
    String name,
    String setCode,
  ) => _dao.cardsByNameInSet(game, name, setCode);

  Future<Map<String, TcgCard>> cardsByIds(CardGame game, List<String> ids) =>
      _dao.cardsByIds(game, ids);

  /// Fetches a single printing, falling back to the network when not cached.
  Future<TcgCard?> resolveCard(CardGame game, String id) async {
    final local = await _dao.cardById(game, id);
    if (local != null) return local;
    final remote = await catalogFor(game).fetchCardById(id);
    if (remote != null) await _dao.upsertCards(game, [remote]);
    return remote;
  }

  /// Fetches the printings among [ids] this device has no row for.
  ///
  /// A collection and the catalogue behind it travel separately. The account
  /// holds holdings, which name their cards by id, while the catalogue is
  /// downloaded set by set - so a browser that has just signed in on an account
  /// holds rows it cannot name, and a collection of "--" is exactly that. This
  /// is the one-off cost of making those rows readable, and it is deliberately
  /// not a catalogue sync: it asks for the cards a collection is already
  /// holding and for nothing else.
  ///
  /// Only a few requests are in flight at a time, the way the catalogue
  /// providers pace their own bulk reads, because a collection can name
  /// thousands of cards and a device that has none of them would otherwise open
  /// thousands of requests at once.
  ///
  /// Returns how many printings were stored. Cards the shop cannot answer for
  /// are left out rather than guessed at - their rows keep the placeholder they
  /// already had - and a printing nobody knows is asked again next time rather
  /// than remembered as unanswerable.
  Future<int> resolveMissingCards(
    CardGame game,
    List<String> ids, {
    int concurrency = _resolveConcurrency,
    void Function(int done, int total)? onProgress,
  }) async {
    if (ids.isEmpty || !supports(game)) return 0;

    final seen = <String>{};
    final wanted = <String>[
      for (final id in ids)
        if (id.isNotEmpty && seen.add(id)) id,
    ];
    final missing = await _dao.missingCardIds(game, wanted);
    if (missing.isEmpty) return 0;

    final catalog = catalogFor(game);
    final queue = List<String>.from(missing);
    final arrived = <TcgCard>[];
    var done = 0;
    var stored = 0;

    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final id = queue.removeAt(0);
        TcgCard? card;
        try {
          card = await catalog.fetchCardById(id);
        } catch (_) {
          // One printing this game's shop cannot answer for is one placeholder
          // that stays a placeholder. It is not a reason to abandon the rest.
        }
        if (card != null) arrived.add(card);
        done++;
        onProgress?.call(done, missing.length);
        if (arrived.length >= _resolveFlushSize) {
          stored += await _store(game, arrived);
        }
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 8), (_) => worker()));
    stored += await _store(game, arrived);
    return stored;
  }

  /// Stores what a run has collected so far, and empties the list.
  ///
  /// Written as it arrives rather than once at the end: a first sign-in on a
  /// browser holding a few thousand cards is minutes of requests, and a tab
  /// that is closed, or a session that ends, halfway through should keep the
  /// cards that did arrive.
  Future<int> _store(CardGame game, List<TcgCard> arrived) async {
    if (arrived.isEmpty) return 0;
    final batch = List<TcgCard>.of(arrived);
    arrived.clear();
    await _dao.upsertCards(game, batch);
    return batch.length;
  }

  /// Every printing sharing a group id, fetching on demand when unknown.
  Future<List<TcgCard>> printingsOf(CardGame game, String groupId) async {
    final local = await _dao.printingsOf(game, groupId);
    if (local.isNotEmpty) return local;
    final remote = await catalogFor(game).fetchPrintingsOf(groupId);
    if (remote.isNotEmpty) await _dao.upsertCards(game, remote);
    return _dao.printingsOf(game, groupId);
  }

  /// Free-text search over the cached catalogue, extended by the API when the
  /// local cache has nothing useful to offer.
  Future<List<TcgCard>> search(
    CardGame game,
    String query, {
    int limit = 80,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // A number names a printing rather than a word. There is nothing for the
    // provider to be asked - its search takes names and rules text - and a
    // name search for "001" would answer with every card that mentions it.
    final List<TcgCard>? byNumber = await _dao.searchByNumber(
      game,
      q,
      limit: limit,
    );
    if (byNumber != null) return byNumber;
    final local = await _dao.searchCached(game, q, limit: limit);
    if (local.length >= 12) return local;
    try {
      final remote = await catalogFor(game).search(q, limit: limit);
      if (remote.isNotEmpty) {
        await _dao.upsertCards(game, remote);
        final merged = await _dao.searchCached(game, q, limit: limit);
        return merged.isNotEmpty ? merged : remote;
      }
    } catch (_) {
      // Offline or no results; the local answer stands.
    }
    return local;
  }

  /// Sets whose name or code matches [query], newest first.
  ///
  /// Answered entirely from the cache, because the set list is downloaded once
  /// and kept: a set the user has never opened is still searchable, and a search
  /// does not need the network to say a set exists. The screen offers these
  /// above card results so typing "Bloomburrow" browses the set rather than
  /// reporting that no card matched.
  Future<List<TcgSet>> searchSets(
    CardGame game,
    String query, {
    int limit = 6,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final matches = await _dao.sets(game, search: q, sort: SetSort.newest);
    return matches.length > limit ? matches.sublist(0, limit) : matches;
  }

  /// Refreshes prices for a set of printings.
  ///
  /// Providers update prices at most once a day, so callers should not do this
  /// more often than that.
  Future<int> refreshPrices(CardGame game, List<String> cardIds) async {
    if (cardIds.isEmpty) return 0;
    final byId = await _dao.cardsByIds(game, cardIds);
    final cards = cardIds.map((id) => byId[id]).whereType<TcgCard>().toList();
    if (cards.isEmpty) return 0;
    try {
      final fresh = await catalogFor(game).refreshPrices(cards);
      await _dao.updatePrices(game, fresh);
      return fresh.length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> cardCount(CardGame game) => _dao.cardCount(game);

  /// Removes a game's cached catalogue to reclaim space.
  Future<void> clearCachedCatalog(CardGame game) => _dao.clearGame(game);
}
