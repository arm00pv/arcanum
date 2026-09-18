import 'dart:math' as math;

import 'package:arcanum/core/utils/collector_query.dart';
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

  /// How many missing printings are asked about, and stored, in one go.
  ///
  /// A chunk is both the unit a request is made in and the unit that reaches
  /// disk, and the number is the same one it always was: a sign-in on a browser
  /// that has never downloaded the sets behind a collection is minutes of work,
  /// so what has arrived is written every couple of hundred cards rather than
  /// at the end. Handing the catalogue a chunk rather than a card is the
  /// difference that matters - it is the catalogue that knows a whole set can
  /// be read at once, and it cannot say so about an id it is given alone.
  static const _resolveChunk = 200;

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
  /// The missing ids travel to the catalogue in chunks rather than one at a
  /// time, and [CardCatalog.fetchCardsByIds] is where the cost of a chunk is
  /// decided. Every catalogue can answer a chunk - the ones with nothing clever
  /// to do with it ask about each id in turn, which is what this method used to
  /// do itself - and the five tcgcsv games read a whole set per chunk instead,
  /// which is what turns a browser's first sign-in from a thousand paced
  /// requests into one per set.
  ///
  /// Returns how many printings were stored. Cards the shop cannot answer for
  /// are left out rather than guessed at - their rows keep the placeholder they
  /// already had - and a printing nobody knows is asked again next time rather
  /// than remembered as unanswerable.
  Future<int> resolveMissingCards(
    CardGame game,
    List<String> ids, {
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
    var stored = 0;
    for (var start = 0; start < missing.length; start += _resolveChunk) {
      final end = math.min(start + _resolveChunk, missing.length);
      final chunk = missing.sublist(start, end);
      Map<String, TcgCard> arrived;
      try {
        arrived = await catalog.fetchCardsByIds(chunk);
      } catch (_) {
        // A catalogue that cannot answer a chunk at all costs that chunk's
        // cards and none of the ones behind it, which is the same bargain the
        // per-card version struck.
        arrived = const <String, TcgCard>{};
      }
      stored += await _store(game, arrived.values.toList());
      onProgress?.call(end, missing.length);
    }
    return stored;
  }

  /// Stores one chunk of what a run has collected.
  ///
  /// Written as it arrives rather than once at the end: a first sign-in on a
  /// browser holding a few thousand cards is minutes of requests, and a tab
  /// that is closed, or a session that ends, halfway through should keep the
  /// cards that did arrive.
  Future<int> _store(CardGame game, List<TcgCard> arrived) async {
    if (arrived.isEmpty) return 0;
    await _dao.upsertCards(game, arrived);
    return arrived.length;
  }

  /// Every printing sharing a group id, fetching on demand when unknown.
  Future<List<TcgCard>> printingsOf(CardGame game, String groupId) async {
    final local = await _dao.printingsOf(game, groupId);
    if (local.isNotEmpty) return local;
    final remote = await catalogFor(game).fetchPrintingsOf(groupId);
    if (remote.isNotEmpty) await _dao.upsertCards(game, remote);
    return _dao.printingsOf(game, groupId);
  }

  /// Free-text search over the cached catalogue, extended by the catalogue
  /// behind it when the local cache has nothing useful to offer.
  ///
  /// A number and a word leave here by different roads, and neither of them is
  /// a provider for the number. A number names a printing, the providers answer
  /// in words - asking Scryfall for "001" answers with every card that mentions
  /// it - so a number is answered from the cache, and, when the cache holds the
  /// grammar but not the card, from the shared catalogue, which can address a
  /// printing by its number. That is the case a browser meets on its first
  /// sign-in: it holds a collection whose rows name their cards by id, and a
  /// catalogue that has never downloaded the set they are in.
  Future<List<TcgCard>> search(
    CardGame game,
    String query, {
    int limit = 80,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final CollectorQuery? parsed = CollectorQuery.parse(q);
    if (parsed != null) {
      final List<TcgCard>? local = await _dao.searchByNumber(
        game,
        q,
        limit: limit,
      );
      if (local != null && local.isNotEmpty) return local;
      final List<TcgCard> remote = await _numberFromCatalogue(
        game,
        q,
        parsed,
        limit: limit,
      );
      if (remote.isNotEmpty) return remote;
      // The query read as a number and the cache had an answer for it, even if
      // that answer was nothing: "BT26-999" is a printing this set does not
      // have, and searching every card that mentions "BT26-999" would be a
      // worse answer than none.
      if (local != null) return local;
    }

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

  /// A number the local cache cannot answer, asked of the catalogue that can.
  ///
  /// Reached only when the query parsed as a collector number and this device
  /// could not resolve it, and never for the phone: the catalogue's default
  /// implementation of the number lookup returns nothing without a request, so
  /// a device with no server behaves exactly as it did before this existed.
  ///
  /// A source that answers nothing is answered with the local result - an empty
  /// list - rather than by asking a provider, because a provider has no number
  /// endpoint to ask and would answer a question nobody put.
  Future<List<TcgCard>> _numberFromCatalogue(
    CardGame game,
    String query,
    CollectorQuery parsed, {
    required int limit,
  }) async {
    if (!supports(game)) return const <TcgCard>[];
    // A parse that named no set and does not stand on its own names no printing
    // either: "P1" is a number with a region in front of it and "Mewtwo 2" is a
    // word with a number after it, and the catalogue answers both with nothing.
    // Not asking is the difference between one wasted request per keystroke and
    // none.
    if (parsed.codeCandidates.isEmpty && !parsed.standalone) {
      return const <TcgCard>[];
    }
    try {
      final cards = await catalogFor(game)
          .fetchCardsByNumber(parsed, limit: limit);
      if (cards.isEmpty) return const <TcgCard>[];
      await _dao.upsertCards(game, cards);
      // SQLite is what the screen reads, so the number is asked of it again:
      // a printing that was already cached keeps the row it had, prices and
      // all, and the ones that just arrived are read back in the order the
      // local search puts them in.
      final merged = await _dao.searchByNumber(game, query, limit: limit);
      return merged != null && merged.isNotEmpty ? merged : cards;
    } catch (_) {
      // Offline, signed out, or a catalogue that cannot address a printing by
      // its number. All three are the app as it was before the shared
      // catalogue existed, which is the only acceptable failure here.
      return const <TcgCard>[];
    }
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
