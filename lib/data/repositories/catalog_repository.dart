import 'dart:math' as math;

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/catalog_meta.dart';
import 'package:arcanum/data/catalog/shared_catalogue.dart';
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
    CatalogMetaTable? metaTable,
    bool Function()? serverAllowed,
  }) : _catalogs = catalogs,
       _dao = dao,
       _meta = metaTable,
       _serverAllowed = serverAllowed;

  final Map<CardGame, CardCatalog> _catalogs;
  final CatalogDao _dao;

  /// The server's `catalog_meta` table, when there is one to read.
  ///
  /// Absent on a phone and absent in a browser that has not been handed the
  /// server path at all, which is what keeps "no server" a build-time fact
  /// rather than a caught error.
  final CatalogMetaTable? _meta;

  /// Whether the server may be read for the call about to be made.
  ///
  /// The same question [RoutedCatalog] asks before it reads a card, asked here
  /// before a revision is read: the Settings switch and whether anybody is
  /// signed in, answered at call time because both change while the app is
  /// open. One answer for both is deliberate - a switch that turns the shared
  /// catalogue off must not leave something in the app still talking to it.
  final bool Function()? _serverAllowed;

  /// Sets are re-fetched when the cache is older than this - but only where
  /// there is no server to ask.
  ///
  /// Section 6 offers two ways to keep this TTL and the server's
  /// `sets_revision` from both invalidating the same set list, and warns about
  /// what happens if they are simply added together: two independent reasons to
  /// re-download is how a browser ends up re-downloading the set list on every
  /// visit. **This implements the simpler of the two - when a server answers,
  /// the revision wins and this TTL is not consulted at all** - rather than the
  /// floor, and the reason is that the floor is not one rule but two: it needs
  /// the revision to be authoritative *and* a per-session memo of what has
  /// already been fetched, which is a second piece of state that has to be
  /// right for the first rule to hold. Ignoring the TTL when a server answers
  /// is a single branch with a single owner: [CatalogDao.isCatalogued] and the
  /// local row count say whether anything is cached, the revision says whether
  /// what is cached is old, and this number says nothing at all.
  ///
  /// So the TTL keeps exactly the job it has today - the phone, and any browser
  /// with no session, where no revision exists to act on. It is a week of
  /// staleness on a device that has no way to learn the catalogue changed, and
  /// it is the thing the revision replaces rather than the thing it joins.
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

  /// How many printings have their prices asked for, and written, in one go.
  ///
  /// A chunk is a batch of requests and a write, and it is bounded by the same
  /// reasoning [_resolveChunk] is: a collection's prices are refreshed in one
  /// run, and what has arrived is written before the next batch is asked for, so
  /// a tab closed halfway through keeps the prices it got. It is deliberately not
  /// the number of ids that fits in one request - that is a URL's business and
  /// [SupabaseCatalogTable] answers it - and it is not the game: a client holding
  /// forty cards still asks once.
  static const _priceChunk = 200;

  /// The catalogue backing a game.
  CardCatalog catalogFor(CardGame game) => _catalogs[game]!;

  /// Whether a catalogue is registered for a game.
  bool supports(CardGame game) => _catalogs.containsKey(game);

  /// Loads a game's full set catalogue, refreshing when it is out of date.
  ///
  /// "Out of date" has two answers, and which one is asked depends on whether
  /// there is a server to ask. With one, the server's `sets_revision` for the
  /// game decides: a revision this device has not read is a set list it does not
  /// have the current form of, and a set released today appears today rather
  /// than up to seven days from now. Without one, [setCacheTtl] decides exactly
  /// as it always has.
  ///
  /// [forceRefresh] bypasses both - it is the pull-to-refresh gesture, and a
  /// collector who asks for the list gets the list. A network failure with a
  /// warm cache is not an error: the cached catalogue is returned instead.
  Future<List<TcgSet>> loadSets(
    CardGame game, {
    bool forceRefresh = false,
    SetSort sort = SetSort.newest,
    void Function(int done, int total)? onProgress,
  }) async {
    final cachedCount = await _dao.setCount(game);
    final _SetsRevision? revision = await _revision(game);

    final bool mustFetch;
    if (forceRefresh) {
      mustFetch = true;
    } else if (cachedCount == 0) {
      // Presence, and it is decided by the local rows rather than by any
      // revision. A revision this client has already read says the sets it has
      // are current, and says nothing whatever about whether it has any: a
      // cache that was cleared, evicted by Safari, or never filled all leave a
      // client that has read revision 2 and holds nothing. Reading that match as
      // "I have them" is what would leave the Sets tab empty and keep it empty,
      // which is why this branch comes first and cannot be skipped.
      mustFetch = true;
    } else if (revision != null) {
      // A server answered, so it decides and the TTL is not consulted at all -
      // see [setCacheTtl]. A revision never read before counts as moved: the
      // client cannot say that what it holds is the current form of the list,
      // and one read settles it.
      mustFetch = revision.server != revision.seen;
    } else {
      final fetchedAt = await _dao.setsFetchedAt(game);
      mustFetch =
          fetchedAt == null ||
          DateTime.now().difference(fetchedAt) > setCacheTtl;
    }

    if (mustFetch) {
      try {
        final sets = await catalogFor(game)
            .fetchAllSets(onProgress: onProgress);
        if (sets.isNotEmpty) await _dao.upsertSets(game, sets);
        // Written after the read came back and never before it. A revision this
        // client has written down is a claim that it has read the set list at
        // that revision, so recording one for a request that failed - or one
        // that a cancelled tab abandoned - would leave the next visit believing
        // itself current on the strength of an answer nobody received.
        //
        // An empty answer is still an answer and is recorded: the catalogue is
        // asked and has nothing, which is what a game whose import has not run
        // looks like - and when that import does run it moves the revision, so
        // the list arrives without this device having to ask again every visit
        // in the meantime.
        //
        // Two things this cannot tell apart, said plainly because neither is
        // visible from here: [RoutedCatalog] answers from the provider whenever
        // the server has nothing or fails, so the rows written may have come
        // from either half; and the number recorded is the server's, whichever
        // half produced the list.
        if (revision != null) await _dao.setSetsRevision(game, revision.server);
      } catch (_) {
        if (cachedCount == 0) rethrow;
        // Otherwise fall through to the cache, and the revision stays where it
        // was, so the next visit asks again.
      }
    }
    return _dao.sets(game, sort: sort);
  }

  /// A game's set list revision: the one the server publishes and the one this
  /// device last read.
  ///
  /// Read together because neither half means anything alone, and null whenever
  /// the server cannot be asked - no `catalog_meta` table in this build, no
  /// session, the switch off, a request that failed, or a table with no row for
  /// this game. Every one of those is the same answer on purpose: the seven-day
  /// TTL governs, which is the app exactly as it was before this read existed.
  ///
  /// One request per call, and no memo of it. [loadSets] is asked once per game
  /// per session by `setsProvider` and again on an explicit refresh, so one
  /// extra request per set-list read is the whole cost of knowing whether the
  /// cache is behind - and it is the request the design says to make at boot
  /// and after sign-in, which is when this happens.
  ///
  /// A row for another game is skipped rather than counted, and a table with no
  /// row for this game is "no revision" rather than revision zero: a game the
  /// server has never imported is a game whose set list this client cannot learn
  /// anything about, and the TTL is the honest answer for it. The read itself,
  /// and every way it can come back with nothing, is [_metaRow] - the price half
  /// asks the same table the same question and only compares a different
  /// counter.
  ///
  /// And only for the games the shared catalogue holds. `catalog_meta` carries
  /// a row for every game on the server, but a revision is a statement about the
  /// set list *the server serves*: for a game this app reads from its provider,
  /// a revision it cannot act on would take the seven-day TTL away and pin that
  /// game's set list to whatever it happened to read first. Which games those
  /// are is [sharedCatalogueGames], the one place that answers it.
  Future<_SetsRevision?> _revision(CardGame game) async {
    final CatalogMeta? entry = await _metaRow(game);
    if (entry == null) return null;
    return _SetsRevision(
      server: entry.setsRevision,
      seen: await _dao.setsRevision(game),
    );
  }

  /// A game's price revision: the one the server publishes and the one this
  /// device last read.
  ///
  /// The same pair as [_revision], asked of the same row and compared the same
  /// way, and null in every case where there is nothing to act on: no
  /// `catalog_meta` table in this build, no session, the switch off, a request
  /// that failed, no row for this game, a game this app reads from its provider
  /// ([sharedCatalogueGames]), a `prices_revision` of 0 - the value a game whose
  /// price import has never run carries - and a revision with no
  /// `prices_observed_on` beside it.
  ///
  /// Null is not "these prices are current". It is "ask the way the app asked
  /// before any of this existed", which is what [refreshStalePrices] does with
  /// it, so the worst a wrong null can cost is the request the app was already
  /// making. The last two of those cases are this implementation's reading
  /// rather than the design's own sentence, and they are one reading: the client
  /// is asking whether the server has prices to serve, and a counter of zero or
  /// a revision the server cannot date is not prices it can serve. Acting on
  /// either would suppress a browser's provider path in favour of a table that
  /// has nothing in it.
  ///
  /// One request per call, and no memo of it, for the reason the set-list half
  /// gives: a price refresh is a once-a-day gesture, and one extra request per
  /// refresh is the whole cost of knowing whether the cache is behind.
  Future<_PricesRevision?> _pricesRevision(CardGame game) async {
    final CatalogMeta? entry = await _metaRow(game);
    if (entry == null ||
        entry.pricesRevision <= 0 ||
        entry.pricesObservedOn == null) {
      return null;
    }
    return _PricesRevision(
      server: entry.pricesRevision,
      seen: await _dao.pricesRevision(game),
    );
  }

  /// This game's row of the server's `catalog_meta`, or null when there is none
  /// to read.
  ///
  /// One request, and the one place both halves of section 6 read the table
  /// through - the set list and the prices ask the same question of the same row
  /// and differ only in which counter they compare. Null covers every way there
  /// can be no revision: no table in this build (the phone), a game the shared
  /// catalogue does not hold (a revision about a set list this device reads
  /// elsewhere is a revision it cannot act on), the Settings switch off or nobody
  /// signed in, a request that failed, and a table with no row for this game - a
  /// game the server has never imported has nothing to say about whether this
  /// cache is behind, and is not "revision zero".
  Future<CatalogMeta?> _metaRow(CardGame game) async {
    final CatalogMetaTable? meta = _meta;
    if (meta == null || !sharedCatalogueGames.contains(game)) return null;
    if (!(_serverAllowed?.call() ?? false)) return null;
    final List<Map<String, Object?>> rows;
    try {
      rows = await meta.meta();
    } catch (_) {
      return null;
    }
    for (final Map<String, Object?> row in rows) {
      final CatalogMeta? entry = CatalogMeta.fromRow(row);
      if (entry == null || entry.game != game) continue;
      return entry;
    }
    return null;
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
  /// more often than that. It asks unconditionally - it is the explicit gesture,
  /// what the alerts screen makes - and [refreshStalePrices] is the same read
  /// with the server's own invalidation signal in front of it.
  Future<int> refreshPrices(CardGame game, List<String> cardIds) async =>
      _refresh(game, await _heldCards(game, cardIds), null);

  /// Refreshes prices for the printings this client holds, when the server says
  /// they have moved.
  ///
  /// The prices row of section 6's table, and the counterpart of [loadSets]: the
  /// server publishes a `prices_revision` per game, the importer bumps it
  /// whenever it rewrites that game's prices, and a revision this device has not
  /// read is a set of prices that is behind. What is refetched is **bounded by
  /// what this client holds rather than by the game** - a client holding forty
  /// cards asks about forty, and a client holding four thousand asks about four
  /// thousand in batches - which is the whole reason a signal is worth having:
  /// the server holds 77,925 price rows and no browser needs them.
  ///
  /// [heldIds] is what the client holds - a collection's card ids - and is passed
  /// in rather than looked up here, because a collection is another repository's
  /// business. The request itself is the one [refreshPrices] already makes, made
  /// through the game's catalogue, so [RoutedCatalog] asks the shared catalogue
  /// first and the provider second exactly as it does today and the ids leave as
  /// the ids this device already has in its own SQLite. **The server is never
  /// asked to relate a price to a holding**: there is no request here that names
  /// an account, and the filter it carries is a list of ids this browser read out
  /// of its own database.
  ///
  /// The decision is the same four-way one [loadSets] makes, in the same order:
  ///
  /// * [forceRefresh] decides - an explicit pull gets what it asked for;
  /// * otherwise presence comes first: a client holding no price at all for the
  ///   cards it holds is not a client whose prices are current, whatever revision
  ///   it has read. This is the branch that fills a cache that was cleared or
  ///   evicted, and it is asked first for the reason [loadSets] asks it first -
  ///   a revision is an invalidation signal and never a presence signal;
  /// * otherwise the revision decides, where there is one: a revision this device
  ///   has not read is prices to ask for, and a revision it has read is not;
  /// * otherwise - no server to ask, no row for the game, `prices_revision` 0, a
  ///   revision with no sample date, or a metadata read that failed - the prices
  ///   are refreshed exactly as the app refreshed them before any of this
  ///   existed, which is what keeps a phone and a signed-out browser unchanged.
  ///
  /// Returns how many printings had prices written. A read that failed returns
  /// what arrived before it failed and leaves the previous revision in place, so
  /// the next visit tries the revision that moved again.
  Future<int> refreshStalePrices(
    CardGame game,
    List<String> heldIds, {
    bool forceRefresh = false,
  }) async {
    if (heldIds.isEmpty || !supports(game)) return 0;

    // The catalogue is handed printings rather than ids, and [CatalogDao.updatePrices]
    // writes onto rows, so the ids are resolved to the rows this client actually
    // has. A client holding ids and no rows for them - the cache Safari swept
    // away, a game cleared to reclaim space - has nowhere to put a price, and is
    // asked again on the first visit after those rows are downloaded: nothing is
    // recorded here, and presence is decided by the rows rather than by the
    // revision, so the revision it read before cannot stand in for prices it no
    // longer has.
    final List<TcgCard> held = await _heldCards(game, heldIds);
    if (held.isEmpty) return 0;

    final _PricesRevision? revision = await _pricesRevision(game);

    final bool mustFetch;
    if (forceRefresh) {
      mustFetch = true;
    } else if (!_priced(held)) {
      mustFetch = true;
    } else if (revision != null) {
      mustFetch = revision.server != revision.seen;
    } else {
      mustFetch = true;
    }
    if (!mustFetch) return 0;

    return _refresh(game, held, revision);
  }

  /// Prices for [cards], asked for and written a chunk at a time.
  ///
  /// [revision] is the server revision this read settles, when there is one; it
  /// is recorded only after a read came back, and never for the plain
  /// [refreshPrices] gesture, which asks a question no revision was read to
  /// answer.
  Future<int> _refresh(
    CardGame game,
    List<TcgCard> cards,
    _PricesRevision? revision,
  ) async {
    if (cards.isEmpty) return 0;

    final catalog = catalogFor(game);
    var written = 0;
    try {
      for (var start = 0; start < cards.length; start += _priceChunk) {
        final end = math.min(start + _priceChunk, cards.length);
        final fresh = await catalog.refreshPrices(cards.sublist(start, end));
        await _dao.updatePrices(game, fresh);
        written += fresh.length;
      }
    } catch (_) {
      // A source that cannot answer costs this chunk's prices and none of the
      // ones behind it, and what arrived before it is kept. The revision stays
      // where it was: a revision this client has written down is a claim that it
      // read the prices at that revision, so recording one for a request that
      // failed would leave the next visit believing itself current on the
      // strength of an answer nobody received.
      return written;
    }
    // Written after the read came back and never before it, and only when there
    // was a revision to settle. A game the server holds no revision for has
    // nothing to record, and recording zero would be a claim to have read a
    // revision that does not exist.
    if (revision != null) await _dao.setPricesRevision(game, revision.server);
    return written;
  }

  /// The stored printings among [ids], in the order [ids] names them.
  ///
  /// An id the client names twice is one printing, and an id it has no row for is
  /// left out rather than guessed at: what the catalogue is asked about is the
  /// rows this device actually holds, which is the bound the design asks for.
  Future<List<TcgCard>> _heldCards(CardGame game, List<String> ids) async {
    final seen = <String>{};
    final wanted = <String>[
      for (final String id in ids)
        if (id.isNotEmpty && seen.add(id)) id,
    ];
    if (wanted.isEmpty) return const <TcgCard>[];
    final byId = await _dao.cardsByIds(game, wanted);
    return <TcgCard>[
      for (final String id in wanted)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Whether any of [cards] already carries a price.
  ///
  /// The presence question, and deliberately about what the rows contain rather
  /// than about [CatalogDao.pricesUpdatedAt]: that column is stamped by every
  /// write of a card row, prices or none, so it answers "when was this row
  /// stored" and not "do I have a price".
  ///
  /// Any rather than every, which is the all-or-nothing question [loadSets] asks
  /// with the local set count. A client holding a price for one of the cards it
  /// holds has prices, and a card of its own with none is usually a card whose
  /// source quotes none - asking for those again on every visit is the refetch
  /// storm the design says two invalidation rules produce. A client holding no
  /// price at all is the one that must be filled, whatever its revision says.
  static bool _priced(List<TcgCard> cards) => cards.any(
    (TcgCard card) =>
        _quotes(card.prices.byFinish) || _quotes(card.prices.secondary),
  );

  /// Whether a finish map states a price a collector could be shown.
  ///
  /// A zero is not a price - the design says so for the importer and
  /// [TcgPrices.isEmpty] says so for the screen - so a map of zeroes is a card
  /// this client has no price for.
  static bool _quotes(Map<String, double?> prices) =>
      prices.values.any((double? price) => price != null && price > 0);

  Future<int> cardCount(CardGame game) => _dao.cardCount(game);

  /// Removes a game's cached catalogue to reclaim space.
  ///
  /// The revision this device has read is deliberately left behind: it is a
  /// record of what was read, not of what is stored, and the sets are gone -
  /// which [loadSets] sees as an empty cache and answers by downloading them
  /// again, whatever the revision says.
  Future<void> clearCachedCatalog(CardGame game) => _dao.clearGame(game);
}

/// One game's price revision, both halves of the comparison.
///
/// The same pair as [_SetsRevision] and for the same reason: [seen] is null when
/// this device has never recorded one, which is the state a browser is in the
/// first time it reads a game's prices from the server and the state a device
/// that has only ever used a provider is permanently in.
class _PricesRevision {
  const _PricesRevision({required this.server, required this.seen});

  /// The revision the server publishes for this game's prices.
  final int server;

  /// The revision this device last read, or null if it never has.
  final int? seen;
}

/// One game's set list revision, both halves of the comparison.
///
/// [seen] is null when this device has never recorded one, which is the state a
/// browser is in the first time it reads a game from the server and the state a
/// device that has only ever used a provider is permanently in.
class _SetsRevision {
  const _SetsRevision({required this.server, required this.seen});

  /// The revision the server publishes for this game.
  final int server;

  /// The revision this device last read, or null if it never has.
  final int? seen;
}
