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
  })  : _catalogs = catalogs,
        _dao = dao;

  final Map<CardGame, CardCatalog> _catalogs;
  final CatalogDao _dao;

  /// Sets are re-fetched when the cache is older than this.
  static const setCacheTtl = Duration(days: 7);

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
        final sets = await catalogFor(game).fetchAllSets(onProgress: onProgress);
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
  }) =>
      _dao.sets(game,
          search: search, types: types, includeDigital: includeDigital, sort: sort);

  Future<Map<String, int>> setTypeCounts(CardGame game,
          {bool includeDigital = false}) =>
      _dao.setTypeCounts(game, includeDigital: includeDigital);

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
      final cards =
          await catalogFor(game).fetchCardsInSet(code, onProgress: onProgress);
      if (cards.isNotEmpty) {
        await _dao.upsertCards(game, cards);
        await _dao.markCatalogued(game, code);
      }
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

  Future<TcgCard?> cardById(CardGame game, String id) => _dao.cardById(game, id);

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
  Future<List<TcgCard>> search(CardGame game, String query, {int limit = 80}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final local = await _dao.searchByName(game, q, limit: limit);
    if (local.length >= 12) return local;
    try {
      final remote = await catalogFor(game).search(q, limit: limit);
      if (remote.isNotEmpty) {
        await _dao.upsertCards(game, remote);
        final merged = await _dao.searchByName(game, q, limit: limit);
        return merged.isNotEmpty ? merged : remote;
      }
    } catch (_) {
      // Offline or no results; the local answer stands.
    }
    return local;
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
