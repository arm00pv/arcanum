// What the server's set-list revision does to this device's cache.
//
//   flutter test test/data/catalog_revision_test.dart
//
// Section 6 of docs/catalogue-server-side.md. The server publishes a
// `sets_revision` per game, this client remembers the last one it read in the
// local `meta` table, and a revision that has moved is a set list to download
// again - which is the difference between a set released this morning appearing
// this morning and appearing up to seven days from now.
//
// Two rules in that section are the ones this file exists to hold, and they are
// the two that are easy to get wrong in opposite directions:
//
//   * a revision is an invalidation signal and never a presence signal. A
//     client that has read revision 2 and holds nothing must download, not show
//     an empty Sets tab and keep showing it;
//   * the revision replaces the seven-day TTL rather than joining it. Two
//     independent reasons to refetch is how a browser ends up re-downloading a
//     set list on every visit.
//
// Nothing here touches the network, and nothing here is a browser: the catalogue
// is a CardCatalog and the metadata is a CatalogMetaTable, which is what those
// two seams are for. Where a test reads the stored revision back it reads the
// `meta` row through HistoryDao rather than through the accessor it is testing,
// so the assertion is about the row that was written and not about a reader
// agreeing with itself.

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

TcgSet _set(String code, [CardGame game = _game]) => TcgSet(
  game: game,
  id: code,
  code: code,
  name: 'A set named $code',
  setType: 'expansion',
);

/// A catalogue that answers from a script and counts what it was asked.
///
/// The two things a test needs are how many times the set list was read and
/// whether the read failed, because every rule in this file is about a decision
/// made before that read.
class _ScriptedCatalog extends CardCatalog {
  _ScriptedCatalog({
    CardGame? game,
    this.sets = const <TcgSet>[],
    this.fail = false,
  }) : game = game ?? _game;

  /// What the next read answers with. A test that recovers from a failure
  /// changes it, which is why it is not final.
  List<TcgSet> sets;

  /// Set by a test to make the next read behave like a provider that is down.
  bool fail;

  /// How many times `fetchAllSets` was reached.
  int setsCalls = 0;

  @override
  final CardGame game;

  @override
  String get sourceName => 'scripted';

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    setsCalls++;
    if (fail) throw const CatalogException('the catalogue did not answer');
    return sets;
  }

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
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async => cards;
}

/// The server's `catalog_meta` table, as rows.
///
/// Built in the shape PostgREST answers `?select=*` with, all nine columns
/// present and only one of them acted on, so a test is reading what the client
/// actually receives rather than a trimmed version of it.
class _FakeMeta implements CatalogMetaTable {
  _FakeMeta(this.revisions);

  /// The revision published per game. A game absent from this map is a game
  /// the table has no row for.
  final Map<CardGame, int> revisions;

  /// Set by a test to make the read behave like a server that cannot be
  /// reached.
  bool fail = false;

  /// How many times the table was read.
  int calls = 0;

  @override
  Future<List<Map<String, Object?>>> meta() async {
    calls++;
    if (fail) throw const CatalogException('catalog_meta is unreachable');
    return <Map<String, Object?>>[
      for (final MapEntry<CardGame, int> entry in revisions.entries)
        <String, Object?>{
          'game': entry.key.id,
          'sets_revision': entry.value,
          'prices_revision': 0,
          'set_count': 0,
          'card_count': 0,
          'sets_updated_at': null,
          'prices_observed_on': null,
          'last_import_ok': true,
          'last_import_note': null,
          'source': null,
        },
    ];
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

  /// A repository reading [catalog], with [meta] as the server's revisions when
  /// one is given.
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

  /// Puts a set list in the cache, as a previous visit would have left it.
  Future<void> cacheSets(List<String> codes) =>
      dao.upsertSets(_game, <TcgSet>[for (final String code in codes) _set(code)]);

  /// Moves the cached set list back in time, so the seven-day TTL has expired.
  Future<void> ageCache(Duration by) => db.db.update(
    'sets',
    <String, Object?>{
      'fetched_at': DateTime.now().subtract(by).millisecondsSinceEpoch,
    },
    where: 'game = ?',
    whereArgs: <Object?>[_game.id],
  );

  /// The revision row as it is stored, read without the accessor under test.
  Future<String?> storedRevision() =>
      history.metaValue(CatalogDao.setsRevisionKey(_game));

  Future<void> recordRevision(int revision) =>
      dao.setSetsRevision(_game, revision);

  group('a set list the server says has moved', () {
    test('is downloaded again', () async {
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(2);
      final catalog = _ScriptedCatalog(
        sets: <TcgSet>[_set('the-first-chapter'), _set('released-today')],
      );
      final meta = _FakeMeta(<CardGame, int>{_game: 3});

      final sets = await repositoryFor(catalog, meta: meta).loadSets(_game);

      expect(catalog.setsCalls, 1, reason: 'the revision moved, so it was read');
      expect(
        sets.map((TcgSet s) => s.code),
        contains('released-today'),
        reason: 'the set the server added is in the answer',
      );
      expect(
        await storedRevision(),
        '3',
        reason: 'what was read is what is remembered',
      );
    });

    test('is downloaded again while the cached list is still fresh', () async {
      // The cache was written a moment ago, so the seven-day TTL says "leave it
      // alone" and the revision says otherwise. Only one of them is consulted,
      // and this is the direction that proves which.
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(2);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);

      await repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 3}),
      ).loadSets(_game);

      expect(catalog.setsCalls, 1);
      expect(
        (await dao.setsFetchedAt(_game))!.difference(DateTime.now()).inMinutes,
        0,
        reason: 'the cached copy really was fresh when it was replaced',
      );
    });
  });

  group('a set list the server says has not moved', () {
    test('is not downloaded again, even once the TTL has expired', () async {
      await cacheSets(<String>['the-first-chapter']);
      await ageCache(const Duration(days: 8));
      await recordRevision(2);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);

      final sets = await repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 2}),
      ).loadSets(_game);

      expect(
        catalog.setsCalls,
        0,
        reason: 'a server answered, so the TTL is not consulted at all',
      );
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
    });
  });

  group('a revision this client has never read', () {
    test('is not read as "I already have the sets"', () async {
      // The empty-Sets-tab trap. Nothing is cached, nothing has ever been
      // recorded, and a revision arriving for the first time is a reason to
      // download rather than a reason to believe the cache is complete.
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);
      final meta = _FakeMeta(<CardGame, int>{_game: 2});

      final sets = await repositoryFor(catalog, meta: meta).loadSets(_game);

      expect(catalog.setsCalls, 1);
      expect(sets.map((TcgSet s) => s.code), <String>['released-today']);
      expect(await storedRevision(), '2');
    });

    test('settles after one read rather than one per visit', () async {
      // A device that downloaded its sets from a provider, or from a server
      // that never wrote a revision down, has rows and no number. The first
      // read records the number; the second has nothing to do.
      await cacheSets(<String>['the-first-chapter']);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('the-first-chapter')]);
      final repository = repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 4}),
      );

      await repository.loadSets(_game);
      expect(catalog.setsCalls, 1);

      await repository.loadSets(_game);
      expect(catalog.setsCalls, 1, reason: 'the revision was recorded');
      expect(await storedRevision(), '4');
    });

    test('a cleared cache is filled again, whatever the revision says', () async {
      // The design's own sentence about this rule: clearCachedCatalog deletes
      // rows and leaves the revisions in meta, so the client is left holding
      // revision 2 and nothing else.
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(2);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('the-first-chapter')]);
      final repository = repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 2}),
      );

      await repository.loadSets(_game);
      expect(catalog.setsCalls, 0, reason: 'nothing has moved');

      await repository.clearCachedCatalog(_game);
      expect(await dao.setCount(_game), 0);
      expect(
        await storedRevision(),
        '2',
        reason: 'clearing the cache does not unread the revision',
      );

      final sets = await repository.loadSets(_game);
      expect(catalog.setsCalls, 1, reason: 'an empty cache is always read');
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
    });
  });

  group('with no server to ask', () {
    test('the seven-day TTL still governs a fresh cache', () async {
      await cacheSets(<String>['the-first-chapter']);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);

      // A phone: no catalog_meta table in this build at all.
      final sets = await repositoryFor(catalog).loadSets(_game);

      expect(catalog.setsCalls, 0);
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
    });

    test('and still refetches an expired one', () async {
      await cacheSets(<String>['the-first-chapter']);
      await ageCache(const Duration(days: 8));
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);

      final sets = await repositoryFor(catalog).loadSets(_game);

      expect(catalog.setsCalls, 1);
      // Upserted, not replaced: a set that has left the provider's list keeps
      // its row, which is the design's soft delete and not this change's.
      expect(sets.map((TcgSet s) => s.code), contains('released-today'));
      expect(
        await storedRevision(),
        isNull,
        reason: 'no server answered, so there is no revision to record',
      );
    });

    test('a switch that is off stops the read rather than the TTL', () async {
      // The Settings switch turns the shared catalogue off; it must turn this
      // off with it, or the app keeps talking to a server the collector has
      // switched away from.
      await cacheSets(<String>['the-first-chapter']);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);
      final meta = _FakeMeta(<CardGame, int>{_game: 9});

      final sets = await repositoryFor(
        catalog,
        meta: meta,
        allowed: false,
      ).loadSets(_game);

      expect(meta.calls, 0, reason: 'the revision was not even asked for');
      expect(catalog.setsCalls, 0, reason: 'a fresh cache, on the TTL');
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
    });

    test('a game the shared catalogue does not hold is never invalidated by a '
        'revision', () async {
      // catalog_meta carries a row for every game on the server; this app routes
      // only the games in sharedCatalogueGames. For any other game the revision
      // is about a set list the device does not read from there, and acting on
      // it would take the seven-day TTL away from Magic and pin its sets to
      // whatever it first read.
      await dao.upsertSets(CardGame.mtg, <TcgSet>[_set('lea', CardGame.mtg)]);
      final catalog = _ScriptedCatalog(
        game: CardGame.mtg,
        sets: <TcgSet>[_set('lea', CardGame.mtg)],
      );
      final meta = _FakeMeta(<CardGame, int>{CardGame.mtg: 9});

      final sets = await repositoryFor(catalog, meta: meta).loadSets(
        CardGame.mtg,
      );

      expect(meta.calls, 0, reason: 'the table was not even read');
      expect(catalog.setsCalls, 0);
      expect(sets.map((TcgSet s) => s.code), <String>['lea']);
    });

    test('a game the table has no row for is left to the TTL', () async {
      // Not "revision zero": a game the server has never imported has nothing
      // to say about whether this cache is behind, and treating a missing row
      // as a number would make it refetch on every visit for ever.
      await cacheSets(<String>['the-first-chapter']);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);
      final meta = _FakeMeta(<CardGame, int>{CardGame.mtg: 7});

      final sets = await repositoryFor(catalog, meta: meta).loadSets(_game);

      expect(meta.calls, 1, reason: 'the table was read');
      expect(catalog.setsCalls, 0, reason: 'and had nothing to say about this one');
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
    });
  });

  group('a server that cannot answer', () {
    test('leaves the TTL in charge when only the metadata read fails', () async {
      await cacheSets(<String>['the-first-chapter']);
      final catalog = _ScriptedCatalog(sets: <TcgSet>[_set('released-today')]);
      final meta = _FakeMeta(<CardGame, int>{_game: 3})..fail = true;

      final sets = await repositoryFor(catalog, meta: meta).loadSets(_game);

      expect(
        catalog.setsCalls,
        0,
        reason: 'a revision nobody can read is not a revision that moved',
      );
      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);

      // And the TTL is not merely assumed to be in charge: expiry still works.
      await ageCache(const Duration(days: 8));
      await repositoryFor(catalog, meta: meta).loadSets(_game);
      expect(catalog.setsCalls, 1);
    });

    test('does not wipe the cache when the set list fails', () async {
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(2);
      final catalog = _ScriptedCatalog(fail: true);

      final sets = await repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 3}),
      ).loadSets(_game);

      expect(sets.map((TcgSet s) => s.code), <String>['the-first-chapter']);
      expect(catalog.setsCalls, 1, reason: 'the read was attempted');
      expect(
        await storedRevision(),
        '2',
        reason: 'a read that failed is not a revision this client has read',
      );
    });

    test('and the next visit tries the revision that moved again', () async {
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(2);
      final catalog = _ScriptedCatalog(fail: true);
      final repository = repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 3}),
      );

      await repository.loadSets(_game);
      expect(catalog.setsCalls, 1);

      catalog.fail = false;
      catalog.sets = <TcgSet>[_set('the-first-chapter'), _set('released-today')];
      final sets = await repository.loadSets(_game);

      expect(catalog.setsCalls, 2, reason: 'the revision was still unread');
      expect(sets.map((TcgSet s) => s.code), contains('released-today'));
      expect(await storedRevision(), '3');
    });

    test('still throws when there is nothing cached to fall back on', () async {
      // Unchanged behaviour, and worth holding: an empty cache plus a failure
      // is the one case that is an error rather than a stale answer.
      final catalog = _ScriptedCatalog(fail: true);
      final repository = repositoryFor(
        catalog,
        meta: _FakeMeta(<CardGame, int>{_game: 3}),
      );

      await expectLater(
        repository.loadSets(_game),
        throwsA(isA<CatalogException>()),
      );
      expect(await storedRevision(), isNull);
    });
  });

  group('the revision in the local meta table', () {
    test('is remembered, and read back', () async {
      await recordRevision(7);

      expect(await dao.setsRevision(_game), 7);
      expect(await storedRevision(), '7');
      expect(CatalogDao.setsRevisionKey(_game), 'catalog_sets_rev:lorcana');
    });

    test('is per game', () async {
      await dao.setSetsRevision(CardGame.lorcana, 7);
      await dao.setSetsRevision(CardGame.pokemon, 9);

      expect(await dao.setsRevision(CardGame.lorcana), 7);
      expect(await dao.setsRevision(CardGame.pokemon), 9);
      expect(await dao.setsRevision(CardGame.mtg), isNull);
    });

    test('is null for a game that has never been read from the server', () async {
      expect(await dao.setsRevision(_game), isNull);
      expect(await storedRevision(), isNull);
    });

    test('survives clearGame, which deletes rows and not memory', () async {
      await cacheSets(<String>['the-first-chapter']);
      await recordRevision(5);

      await dao.clearGame(_game);

      expect(await dao.setCount(_game), 0);
      expect(await dao.setsRevision(_game), 5);
    });

    test('reads an unreadable row as never read rather than as zero', () async {
      // A row this build cannot parse is a row it has no revision for, which
      // sends the next visit to the server - the safe direction, and the one
      // that cannot leave a stale cache in place for ever.
      await db.db.insert('meta', <String, Object?>{
        'key': CatalogDao.setsRevisionKey(_game),
        'value': 'not a number',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      expect(await dao.setsRevision(_game), isNull);
    });
  });
}
