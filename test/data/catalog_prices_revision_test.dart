// What the server's price revision does to this device's prices.
//
//   flutter test test/data/catalog_prices_revision_test.dart
//
// Section 6 of docs/catalogue-server-side.md, price half. The server publishes a
// `prices_revision` per game - the importer bumps it whenever it rewrites that
// game's price rows - and this client remembers the last one it read in the local
// `meta` table. When it has moved, the prices of **the cards this client already
// holds** are fetched again, bounded and batched, and written through
// `CatalogDao.updatePrices`. When it has not, nothing is asked for: that is the
// whole point of the signal, and the reason a nightly price import does not cost
// every browser a request it does not need.
//
// The three rules this file exists to hold are the ones the sets half holds, in
// the shape prices give them:
//
//   * a revision is an invalidation signal and never a presence signal. A client
//     that has read revision 2 and holds no price must fetch, not report that its
//     prices are current and keep reporting it;
//   * the request is bounded by the client's own holdings and never by the game,
//     and the server is never asked to relate a price to a holding: the ids travel
//     as ids this browser read out of its own SQLite;
//   * a game the server has no prices for - revision 0, no row, a revision with no
//     sample date, no session, a failed read - refreshes exactly as the app did
//     before any of this existed.
//
// Nothing here touches the network and nothing here is a browser: the catalogue is
// a CardCatalog and the metadata is a CatalogMetaTable, which is what those two
// seams are for. The real PostgREST call - `catalog_meta` and
// `catalog_prices?card_id=in.(...)` - cannot be exercised from here and is not:
// what is tested is the decision made before it and the write made after it.
// Where a test reads the stored revision back it reads the `meta` row through
// HistoryDao rather than through the accessor it is testing, so the assertion is
// about the row that was written and not about a reader agreeing with itself.

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/catalog_meta.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const CardGame _game = CardGame.lorcana;

/// The price the scripted catalogue quotes for everything it is asked about.
const double _fresh = 9.99;

/// A printing, priced or not, as the cache would hold it.
TcgCard _card(String id, {double? price, CardGame game = _game}) => TcgCard(
  game: game,
  id: id,
  setCode: 'tfc',
  setName: 'The First Chapter',
  name: 'A card named $id',
  collectorNumber: '1',
  rarity: 'common',
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{CardFinish.nonfoil.code: price}),
);

/// One row of the server's `catalog_meta`, in the shape PostgREST answers
/// `?select=*` with - all ten columns present, so a test is reading what the
/// client actually receives rather than a trimmed version of it.
Map<String, Object?> _metaRowFor(
  CardGame game, {
  int sets = 1,
  int prices = 1,
  Object? observed = '2026-09-21',
}) => <String, Object?>{
  'game': game.id,
  'sets_revision': sets,
  'prices_revision': prices,
  'set_count': 0,
  'card_count': 0,
  'sets_updated_at': null,
  'prices_observed_on': observed,
  'last_import_ok': true,
  'last_import_note': null,
  'source': 'lorcast',
};

/// A catalogue that answers from a script and records what it was asked.
///
/// What a test needs to see is which ids were handed over and how they were
/// grouped, because every rule in this file is about what leaves the client - a
/// request bounded by the client's holdings, batched, and made or not made
/// according to a revision.
class _ScriptedCatalog extends CardCatalog {
  _ScriptedCatalog({CardGame? game, this.fail = false}) : game = game ?? _game;

  /// Set by a test to make the next price read behave like a source that is
  /// down.
  bool fail;

  /// How many times prices were asked for.
  int priceCalls = 0;

  /// Every id handed to a price read, in the order it was handed over.
  final List<String> askedIds = <String>[];

  /// How many printings each price read was given.
  final List<int> batchSizes = <int>[];

  @override
  final CardGame game;

  @override
  String get sourceName => 'scripted';

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async => const <TcgSet>[];

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async => const <TcgCard>[];

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    priceCalls++;
    batchSizes.add(cards.length);
    askedIds.addAll(cards.map((TcgCard c) => c.id));
    if (fail) throw const CatalogException('the catalogue did not answer');
    return <TcgCard>[
      for (final TcgCard c in cards)
        c.copyWith(
          prices: TcgPrices(
            byFinish: <String, double?>{CardFinish.nonfoil.code: _fresh},
          ),
        ),
    ];
  }
}

/// The server's `catalog_meta` table, as rows.
class _FakeMeta implements CatalogMetaTable {
  _FakeMeta(this.rows);

  /// The rows the table holds. A game absent from them is a game the table has
  /// no row for.
  final List<Map<String, Object?>> rows;

  /// Set by a test to make the read behave like a server that cannot be reached.
  bool fail = false;

  /// How many times the table was read.
  int calls = 0;

  @override
  Future<List<Map<String, Object?>>> meta() async {
    calls++;
    if (fail) throw const CatalogException('catalog_meta is unreachable');
    return rows;
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CatalogDao dao;
  late HistoryDao history;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
    history = HistoryDao(db.db);
  });

  tearDown(() async => db.close());

  /// A repository reading [catalog], with [meta] as the server's rows when one is
  /// given.
  CatalogRepository repositoryFor(
    _ScriptedCatalog catalog, {
    _FakeMeta? meta,
    bool allowed = true,
  }) => CatalogRepository(
    catalogs: <CardGame, CardCatalog>{catalog.game: catalog},
    dao: dao,
    metaTable: meta,
    serverAllowed: () => allowed,
  );

  /// Puts printings in the cache, as a previous visit would have left them.
  Future<void> cacheCards(List<TcgCard> cards) => dao.upsertCards(_game, cards);

  /// The revision row as it is stored, read without the accessor under test.
  Future<String?> storedRevision() =>
      history.metaValue(CatalogDao.pricesRevisionKey(_game));

  Future<double?> storedPriceOf(String id) async =>
      (await dao.cardById(_game, id))!.prices.nonfoil;

  group('a price revision the server says has moved', () {
    test('refetches the prices of the cards this client holds', () async {
      final held = <TcgCard>[
        for (var i = 0; i < 6; i++) _card('card-$i', price: 1.0),
      ];
      await cacheCards(held);
      await dao.setPricesRevision(_game, 1);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 2),
      ]);

      final written = await repositoryFor(catalog, meta: meta).refreshStalePrices(
        _game,
        <String>[for (final TcgCard c in held) c.id],
      );

      expect(written, 6, reason: 'every printing the catalogue quoted was written');
      expect(catalog.priceCalls, 1);
      expect(
        catalog.askedIds,
        <String>[for (final TcgCard c in held) c.id],
        reason: 'the ids asked about are the ids this client holds, in that order',
      );
      expect(
        await storedPriceOf('card-0'),
        _fresh,
        reason: 'written through updatePrices, onto the row already stored',
      );
      expect(
        await storedRevision(),
        '2',
        reason: 'what was read is what is remembered',
      );
    });

    test('is not asked about when the revision has not moved', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 2);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 2),
      ]);

      final written = await repositoryFor(
        catalog,
        meta: meta,
      ).refreshStalePrices(_game, <String>['card-0']);

      expect(written, 0);
      expect(catalog.priceCalls, 0, reason: 'nothing has moved, so nothing is asked');
      expect(
        meta.calls,
        1,
        reason: 'and the revision was read: it is the thing that says so',
      );
      expect(
        await storedPriceOf('card-0'),
        1.0,
        reason: 'the price already held is left exactly as it was',
      );
    });

    test('is not asked about at all when the client holds nothing', () async {
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 9),
      ]);

      final written = await repositoryFor(
        catalog,
        meta: meta,
      ).refreshStalePrices(_game, const <String>[]);

      expect(written, 0);
      expect(catalog.priceCalls, 0);
      expect(meta.calls, 0, reason: 'a client holding nothing asks nothing');
      expect(await storedRevision(), isNull);
    });
  });

  group('a revision is not a presence signal', () {
    test('a client that has read it and holds no price is filled anyway', () async {
      // The cleared-price-cache trap. The revision says what this client has
      // read, and nothing about what it holds: a browser whose rows were evicted,
      // or that downloaded a set before prices were ever asked for, has read
      // revision 2 and holds no price at all.
      await cacheCards(<TcgCard>[_card('card-0'), _card('card-1')]);
      await dao.setPricesRevision(_game, 2);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 2),
      ]);

      final written = await repositoryFor(catalog, meta: meta).refreshStalePrices(
        _game,
        <String>['card-0', 'card-1'],
      );

      expect(
        catalog.priceCalls,
        1,
        reason: 'a matching revision is not "I have prices"',
      );
      expect(written, 2);
      expect(await storedPriceOf('card-0'), _fresh);
    });

    test('a cleared cache is filled again on the first visit with rows back', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 2);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 2),
      ]);
      final repository = repositoryFor(catalog, meta: meta);

      await dao.clearGame(_game);

      // Nothing to write a price onto, so nothing is asked for - and nothing is
      // recorded either, which is what stops the revision this client read from
      // standing in for the prices it no longer has.
      expect(await repository.refreshStalePrices(_game, <String>['card-0']), 0);
      expect(catalog.priceCalls, 0);
      expect(meta.calls, 0, reason: 'the decision was settled locally');
      expect(await storedRevision(), '2');

      // The rows come back - a set opened, a collection resolved against the
      // catalogue - and the very next visit fills them, whatever the revision
      // says.
      await cacheCards(<TcgCard>[_card('card-0')]);
      expect(await repository.refreshStalePrices(_game, <String>['card-0']), 1);
      expect(catalog.priceCalls, 1);
      expect(await storedPriceOf('card-0'), _fresh);
    });
  });

  group('bounded by the cards this client holds', () {
    test('asks about the holdings rather than the game', () async {
      // The catalogue behind a collection holds the whole game; the held ids are
      // forty of them. Asking about the game would be 500 rows of local cache
      // and, on the server, a filter nobody asked for.
      await cacheCards(<TcgCard>[
        for (var i = 0; i < 500; i++) _card('card-$i', price: 1.0),
      ]);
      final held = <String>[for (var i = 0; i < 40; i++) 'card-$i'];
      await dao.setPricesRevision(_game, 1);

      final catalog = _ScriptedCatalog();
      final written = await repositoryFor(
        catalog,
        meta: _FakeMeta(<Map<String, Object?>>[_metaRowFor(_game, prices: 2)]),
      ).refreshStalePrices(_game, held);

      expect(written, 40);
      expect(
        catalog.askedIds,
        held,
        reason: 'forty held cards are forty ids, not the 500 in the cache',
      );
      expect(catalog.batchSizes, <int>[40], reason: 'and they fit in one batch');
    });

    test('asks a client holding more than one batch in batches', () async {
      // A browser that has just signed in holds a collection of thousands. The
      // run is chunked so what arrives is written as it arrives rather than at
      // the end, and the chunk is this repository's own bound, not the game's.
      await cacheCards(<TcgCard>[
        for (var i = 0; i < 250; i++) _card('card-$i', price: 1.0),
      ]);
      final held = <String>[for (var i = 0; i < 250; i++) 'card-$i'];
      await dao.setPricesRevision(_game, 1);

      final catalog = _ScriptedCatalog();
      final written = await repositoryFor(
        catalog,
        meta: _FakeMeta(<Map<String, Object?>>[_metaRowFor(_game, prices: 2)]),
      ).refreshStalePrices(_game, held);

      expect(written, 250);
      expect(catalog.batchSizes.length, greaterThan(1));
      expect(catalog.batchSizes.every((int n) => n <= 200), isTrue);
      expect(catalog.batchSizes.reduce((int a, int b) => a + b), 250);
    });

    test('leaves out ids this client has no row for', () async {
      // A collection names cards by id while the catalogue arrives set by set, so
      // a freshly signed-in browser holds ids it cannot price. They are not asked
      // about, and they are not recorded as asked for either: the cards come
      // first, and the prices follow on the visit after they arrive.
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 1);
      final catalog = _ScriptedCatalog();

      final written = await repositoryFor(
        catalog,
        meta: _FakeMeta(<Map<String, Object?>>[_metaRowFor(_game, prices: 2)]),
      ).refreshStalePrices(_game, <String>['card-0', 'not-downloaded']);

      expect(catalog.askedIds, <String>['card-0']);
      expect(written, 1);
    });
  });

  group('a game the server does not hold', () {
    test('is refreshed the way it always was, and the table is not read', () async {
      // catalog_meta carries a row for every game on the server; this app routes
      // only the games in sharedCatalogueGames. For any other game the price
      // revision is about prices this device does not read from there, and the
      // refresh is exactly the one it made before this existed.
      await dao.upsertCards(CardGame.mtg, <TcgCard>[
        _card('lea-1', price: 1.0, game: CardGame.mtg),
      ]);
      final catalog = _ScriptedCatalog(game: CardGame.mtg);
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(CardGame.mtg, prices: 9),
      ]);

      final written = await repositoryFor(catalog, meta: meta).refreshStalePrices(
        CardGame.mtg,
        <String>['lea-1'],
      );

      expect(meta.calls, 0, reason: 'the table was not even read');
      expect(catalog.priceCalls, 1, reason: 'the refresh the app already made');
      expect(written, 1);
      expect(
        await history.metaValue(CatalogDao.pricesRevisionKey(CardGame.mtg)),
        isNull,
        reason: 'no revision was read, so none is recorded',
      );
    });

    test('and a switch that is off stops the read, not the refresh', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 9),
      ]);

      await repositoryFor(
        catalog,
        meta: meta,
        allowed: false,
      ).refreshStalePrices(_game, <String>['card-0']);

      expect(meta.calls, 0, reason: 'the revision was not even asked for');
      expect(catalog.priceCalls, 1, reason: 'and the prices are still refreshed');
      expect(await storedRevision(), isNull);
    });
  });

  group('a game the server has no prices for', () {
    test('revision zero falls back to the refresh the app already made', () async {
      // The value a game whose price import has never run carries. Acting on it
      // would have a browser suppress its provider path in favour of a table with
      // nothing in it.
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 0, observed: null),
      ]);

      final written = await repositoryFor(catalog, meta: meta).refreshStalePrices(
        _game,
        <String>['card-0'],
      );

      expect(catalog.priceCalls, 1);
      expect(written, 1);
      expect(await storedPriceOf('card-0'), _fresh);
      expect(
        await storedRevision(),
        isNull,
        reason: 'zero is not a revision this client has read',
      );
    });

    test('a revision the server cannot date is not acted on', () async {
      // prices_revision moves with the prices, and the sampler's day is written
      // with them. A revision with no day beside it is a server state this client
      // cannot reconcile with the rest of the row, and the fallback is the safe
      // direction: one request a visit rather than a cache pinned by a number
      // nothing dates.
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 2);
      final catalog = _ScriptedCatalog();

      await repositoryFor(
        catalog,
        meta: _FakeMeta(<Map<String, Object?>>[
          _metaRowFor(_game, prices: 3, observed: null),
        ]),
      ).refreshStalePrices(_game, <String>['card-0']);

      expect(catalog.priceCalls, 1);
      expect(
        await storedRevision(),
        '2',
        reason: 'a revision nobody can date is not a revision this client read',
      );
    });

    test('a table with no row for the game is left to the refresh', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(CardGame.pokemon, prices: 4),
      ]);

      await repositoryFor(catalog, meta: meta).refreshStalePrices(_game, <String>[
        'card-0',
      ]);

      expect(meta.calls, 1, reason: 'the table was read');
      expect(catalog.priceCalls, 1, reason: 'and had nothing to say about this game');
      expect(await storedRevision(), isNull);
    });
  });

  group('a server that cannot answer', () {
    test('leaves the revision that moved unread, and the next visit retries', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 1);
      final catalog = _ScriptedCatalog(fail: true);
      final repository = repositoryFor(
        catalog,
        meta: _FakeMeta(<Map<String, Object?>>[_metaRowFor(_game, prices: 3)]),
      );

      final first = await repository.refreshStalePrices(_game, <String>['card-0']);

      expect(first, 0);
      expect(catalog.priceCalls, 1, reason: 'the read was attempted');
      expect(
        await storedRevision(),
        '1',
        reason: 'a read that failed is not a revision this client has read',
      );
      expect(
        await storedPriceOf('card-0'),
        1.0,
        reason: 'and the price already held is not wiped by a failed read',
      );

      catalog.fail = false;
      final second = await repository.refreshStalePrices(_game, <String>['card-0']);

      expect(catalog.priceCalls, 2, reason: 'the revision was still unread');
      expect(second, 1);
      expect(await storedRevision(), '3');
      expect(await storedPriceOf('card-0'), _fresh);
    });

    test('falls back to the refresh the app already made when only it fails', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      final catalog = _ScriptedCatalog();
      final meta = _FakeMeta(<Map<String, Object?>>[
        _metaRowFor(_game, prices: 3),
      ])..fail = true;

      final written = await repositoryFor(catalog, meta: meta).refreshStalePrices(
        _game,
        <String>['card-0'],
      );

      expect(
        catalog.priceCalls,
        1,
        reason: 'a revision nobody can read is not a revision that moved',
      );
      expect(written, 1);
      expect(await storedRevision(), isNull);
    });
  });

  group('the revision in the local meta table', () {
    test('is remembered, and read back', () async {
      await dao.setPricesRevision(_game, 7);

      expect(await dao.pricesRevision(_game), 7);
      expect(await storedRevision(), '7');
      expect(
        CatalogDao.pricesRevisionKey(_game),
        'catalog_prices_rev:lorcana',
      );
    });

    test('is kept apart from the set list revision', () async {
      // The two counters move independently - a night's price import moves one,
      // a set list moves the other, and most nights neither - so a client that
      // had read one must not be able to mistake it for the other.
      await dao.setSetsRevision(_game, 3);
      await dao.setPricesRevision(_game, 5);

      expect(await dao.setsRevision(_game), 3);
      expect(await dao.pricesRevision(_game), 5);
      expect(
        CatalogDao.pricesRevisionKey(_game),
        isNot(CatalogDao.setsRevisionKey(_game)),
      );
    });

    test('is per game', () async {
      await dao.setPricesRevision(CardGame.lorcana, 7);
      await dao.setPricesRevision(CardGame.pokemon, 9);

      expect(await dao.pricesRevision(CardGame.lorcana), 7);
      expect(await dao.pricesRevision(CardGame.pokemon), 9);
      expect(await dao.pricesRevision(CardGame.mtg), isNull);
    });

    test('is null for a game that has never been read from the server', () async {
      expect(await dao.pricesRevision(_game), isNull);
      expect(await storedRevision(), isNull);
    });

    test('survives clearGame, which deletes rows and not memory', () async {
      await cacheCards(<TcgCard>[_card('card-0', price: 1.0)]);
      await dao.setPricesRevision(_game, 5);

      await dao.clearGame(_game);

      expect(await dao.cardCount(_game), 0);
      expect(await dao.pricesRevision(_game), 5);
    });

    test('reads an unreadable row as never read rather than as zero', () async {
      // A row this build cannot parse is a row it has no revision for, which
      // sends the next visit to the server - the safe direction, and the one that
      // cannot leave a stale price in place for ever.
      await db.db.insert('meta', <String, Object?>{
        'key': CatalogDao.pricesRevisionKey(_game),
        'value': 'not a number',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      expect(await dao.pricesRevision(_game), isNull);
    });
  });

  group('the row the server publishes', () {
    test('carries the price revision and the day it was observed', () {
      final CatalogMeta? meta = CatalogMeta.fromRow(_metaRowFor(_game, prices: 3));

      expect(meta, isNotNull);
      expect(meta!.game, _game);
      expect(meta.pricesRevision, 3);
      // A `date` column carries no zone, so the day is read in this device's
      // own - and nothing acts on the time of day, only on the day.
      expect(meta.pricesObservedOn, DateTime(2026, 9, 21));
    });

    test('reads a missing revision as zero and a missing day as none', () {
      final CatalogMeta? meta = CatalogMeta.fromRow(<String, Object?>{
        'game': 'lorcana',
        'sets_revision': 2,
      });

      expect(meta!.pricesRevision, 0);
      expect(meta.pricesObservedOn, isNull);
    });

    test('drops a game this build does not know', () {
      // An id this build does not know is dropped rather than defaulted, so a
      // tenth game on the server cannot have its revision filed against Magic's
      // cache.
      final CatalogMeta? meta = CatalogMeta.fromRow(<String, Object?>{
        'game': 'flesh-and-blood',
        'prices_revision': 4,
      });

      expect(meta, isNull);
    });
  });
}
