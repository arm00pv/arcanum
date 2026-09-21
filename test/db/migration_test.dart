import 'dart:io';

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Reproduces the exact v1 (Magic-only) schema so the migration can be tested
/// against a realistic database rather than a synthetic one.
const _v1Schema = <String>[
  '''
  CREATE TABLE sets (
    code TEXT PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL,
    set_type TEXT NOT NULL, released_at TEXT, card_count INTEGER NOT NULL DEFAULT 0,
    printed_size INTEGER, icon_svg_uri TEXT, digital INTEGER NOT NULL DEFAULT 0,
    foil_only INTEGER NOT NULL DEFAULT 0, nonfoil_only INTEGER NOT NULL DEFAULT 0,
    parent_set_code TEXT, block_code TEXT, block TEXT,
    catalogued_at INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL)
  ''',
  '''
  CREATE TABLE cards (
    id TEXT PRIMARY KEY, oracle_id TEXT, set_code TEXT NOT NULL, name TEXT NOT NULL,
    collector_number TEXT NOT NULL, collector_sort INTEGER NOT NULL DEFAULT 0,
    rarity TEXT NOT NULL DEFAULT 'unknown', layout TEXT, type_line TEXT,
    oracle_text TEXT, mana_cost TEXT, cmc REAL, colors TEXT NOT NULL DEFAULT '',
    color_identity TEXT NOT NULL DEFAULT '', artist TEXT, image_small TEXT,
    image_normal TEXT, image_large TEXT, image_art_crop TEXT, image_png TEXT,
    back_image_small TEXT, back_image_normal TEXT, price_usd REAL,
    price_usd_foil REAL, price_usd_etched REAL, price_eur REAL,
    price_eur_foil REAL, price_tix REAL, prices_updated_at INTEGER,
    digital INTEGER NOT NULL DEFAULT 0, promo INTEGER NOT NULL DEFAULT 0,
    reprint INTEGER NOT NULL DEFAULT 0, reserved INTEGER NOT NULL DEFAULT 0,
    full_art INTEGER NOT NULL DEFAULT 0, edhrec_rank INTEGER, released_at TEXT,
    set_name TEXT)
  ''',
  '''
  CREATE TABLE collection_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
    finish TEXT NOT NULL DEFAULT 'nonfoil',
    condition TEXT NOT NULL DEFAULT 'near_mint',
    language TEXT NOT NULL DEFAULT 'en', quantity INTEGER NOT NULL DEFAULT 1,
    purchase_price REAL, purchase_date INTEGER, binder TEXT NOT NULL DEFAULT '',
    notes TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)
  ''',
  '''
  CREATE TABLE price_history (
    card_id TEXT NOT NULL, finish TEXT NOT NULL, date TEXT NOT NULL,
    price REAL NOT NULL, source TEXT NOT NULL DEFAULT 'snapshot',
    PRIMARY KEY (card_id, finish, date, source)) WITHOUT ROWID
  ''',
  '''
  CREATE TABLE portfolio_snapshots (
    date TEXT PRIMARY KEY, total_value REAL NOT NULL,
    unique_cards INTEGER NOT NULL, total_cards INTEGER NOT NULL)
  ''',
  '''
  CREATE TABLE alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, card_id TEXT NOT NULL,
    finish TEXT NOT NULL DEFAULT 'nonfoil', kind TEXT NOT NULL,
    threshold REAL NOT NULL, created_at INTEGER NOT NULL,
    triggered_at INTEGER, last_value REAL)
  ''',
  'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
];

/// The same migration logic the app ships, applied to a v1 database.
Future<void> applyV2Migration(Database d) async {
  final batch = d.batch();
  batch.execute('''
    CREATE TABLE sets_v2 (
      game TEXT NOT NULL DEFAULT 'mtg', code TEXT NOT NULL, id TEXT NOT NULL,
      name TEXT NOT NULL, set_type TEXT NOT NULL, released_at TEXT,
      card_count INTEGER NOT NULL DEFAULT 0, printed_size INTEGER,
      icon_svg_uri TEXT, logo_uri TEXT, series TEXT,
      digital INTEGER NOT NULL DEFAULT 0, foil_only INTEGER NOT NULL DEFAULT 0,
      nonfoil_only INTEGER NOT NULL DEFAULT 0, parent_set_code TEXT,
      block_code TEXT, block TEXT, collector_number_start INTEGER,
      catalogued_at INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL,
      PRIMARY KEY (game, code))
  ''');
  batch.execute('''
    INSERT INTO sets_v2 (game, code, id, name, set_type, released_at, card_count,
      printed_size, icon_svg_uri, digital, foil_only, nonfoil_only,
      parent_set_code, block_code, block, catalogued_at, fetched_at)
    SELECT 'mtg', code, id, name, set_type, released_at, card_count, printed_size,
      icon_svg_uri, digital, foil_only, nonfoil_only, parent_set_code, block_code,
      block, catalogued_at, fetched_at FROM sets
  ''');
  batch.execute('DROP TABLE sets');
  batch.execute('ALTER TABLE sets_v2 RENAME TO sets');

  batch.execute('''
    CREATE TABLE portfolio_snapshots_v2 (
      game TEXT NOT NULL DEFAULT 'mtg', date TEXT NOT NULL,
      total_value REAL NOT NULL, unique_cards INTEGER NOT NULL,
      total_cards INTEGER NOT NULL, PRIMARY KEY (game, date))
  ''');
  batch.execute('''
    INSERT INTO portfolio_snapshots_v2 (game, date, total_value, unique_cards, total_cards)
    SELECT 'mtg', date, total_value, unique_cards, total_cards FROM portfolio_snapshots
  ''');
  batch.execute('DROP TABLE portfolio_snapshots');
  batch.execute(
    'ALTER TABLE portfolio_snapshots_v2 RENAME TO portfolio_snapshots',
  );

  for (final table in [
    'cards',
    'collection_entries',
    'price_history',
    'alerts',
  ]) {
    batch.execute(
      "ALTER TABLE $table ADD COLUMN game TEXT NOT NULL DEFAULT 'mtg'",
    );
  }
  batch.execute('ALTER TABLE cards ADD COLUMN flavor_text TEXT');
  batch.execute(
    'ALTER TABLE cards ADD COLUMN booster INTEGER NOT NULL DEFAULT 0',
  );
  batch.execute('ALTER TABLE cards ADD COLUMN foil INTEGER NOT NULL DEFAULT 0');
  batch.execute(
    'ALTER TABLE cards ADD COLUMN nonfoil INTEGER NOT NULL DEFAULT 0',
  );
  batch.execute('ALTER TABLE cards ADD COLUMN prices_json TEXT');
  batch.execute('ALTER TABLE cards ADD COLUMN extras_json TEXT');

  await batch.commit(noResult: true);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('arcanum_migration_test');
  });

  tearDown(() async {
    // The FFI factory keeps a pooled handle open briefly; a failure to delete a
    // temp directory must never fail the test itself.
    try {
      if (dir.existsSync()) await dir.delete(recursive: true);
    } on FileSystemException {
      // Ignored: the OS will reclaim it.
    }
  });

  test('v1 -> v2 migration preserves sets, cards and the collection', () async {
    final path = '${dir.path}/arcanum.db';

    // ---- Build a realistic v1 database with real data in it.
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) async {
          for (final stmt in _v1Schema) {
            await d.execute(stmt);
          }
        },
      ),
    );

    const now = 1755000000000;
    await v1.insert('sets', {
      'code': 'fra',
      'id': 'set-fra',
      'name': 'Reality Fracture',
      'set_type': 'expansion',
      'released_at': '2026-10-02',
      'card_count': 249,
      'fetched_at': now,
    });
    await v1.insert('cards', {
      'id': 'card-loyal-tutor',
      'set_code': 'fra',
      'set_name': 'Reality Fracture',
      'name': 'Loyal Tutor',
      'collector_number': '14',
      'collector_sort': 14,
      'rarity': 'rare',
      'colors': 'W',
      'color_identity': 'W',
      'price_usd': 11.44,
      'prices_updated_at': now,
    });
    await v1.insert('collection_entries', {
      'card_id': 'card-loyal-tutor',
      'finish': 'nonfoil',
      'condition': 'near_mint',
      'language': 'en',
      'quantity': 3,
      'purchase_price': 9.0,
      'binder': 'Binder A',
      'created_at': now,
      'updated_at': now,
    });
    await v1.insert('price_history', {
      'card_id': 'card-loyal-tutor',
      'finish': 'nonfoil',
      'date': '2026-09-01',
      'price': 11.0,
      'source': 'snapshot',
    });
    await v1.insert('portfolio_snapshots', {
      'date': '2026-09-01',
      'total_value': 33.0,
      'unique_cards': 1,
      'total_cards': 3,
    });
    await v1.close();

    // ---- Reopen at v2, running the migration.
    final v2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onUpgrade: (d, from, to) async {
          expect(from, 1);
          await applyV2Migration(d);
        },
      ),
    );

    final entries = await v2.query('collection_entries');
    expect(entries, hasLength(1), reason: 'the collection entry must survive');
    expect(entries.first['quantity'], 3);
    expect(entries.first['binder'], 'Binder A');
    expect(entries.first['purchase_price'], 9.0);
    expect(
      entries.first['game'],
      'mtg',
      reason: 'pre-existing rows become Magic rows',
    );

    final cards = await v2.query('cards');
    expect(cards, hasLength(1));
    expect(cards.first['name'], 'Loyal Tutor');
    expect(cards.first['game'], 'mtg');

    final sets = await v2.query('sets');
    expect(sets, hasLength(1));
    expect(sets.first['code'], 'fra');
    expect(sets.first['game'], 'mtg');
    expect(sets.first['logo_uri'], isNull);

    final history = await v2.query('price_history');
    expect(history, hasLength(1));
    expect(history.first['game'], 'mtg');

    final snapshots = await v2.query('portfolio_snapshots');
    expect(snapshots, hasLength(1));
    expect(snapshots.first['game'], 'mtg');
    expect(snapshots.first['total_value'], 33.0);

    // ---- The composite keys must now allow a Pokémon row to coexist.
    await v2.insert('sets', {
      'game': 'pokemon',
      'code': 'fra',
      'id': 'pk-fra',
      'name': 'A Pokémon set that happens to share a code',
      'set_type': 'expansion',
      'fetched_at': now,
    });
    final both = await v2.query('sets', where: 'code = ?', whereArgs: ['fra']);
    expect(
      both,
      hasLength(2),
      reason: 'the same set code must be allowed in both games',
    );

    await v2.close();
  });

  test('the migrated collection is still queryable per game', () async {
    final path = '${dir.path}/arcanum2.db';
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) async {
          for (final stmt in _v1Schema) {
            await d.execute(stmt);
          }
        },
      ),
    );
    const now = 1755000000000;
    await v1.insert('cards', {
      'id': 'c1',
      'set_code': 'fra',
      'name': 'Loyal Tutor',
      'collector_number': '14',
      'collector_sort': 14,
    });
    await v1.insert('collection_entries', {
      'card_id': 'c1',
      'quantity': 3,
      'created_at': now,
      'updated_at': now,
    });
    await v1.close();

    final v2 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onUpgrade: (d, from, to) => applyV2Migration(d),
      ),
    );

    final mtgTotal = await v2.rawQuery(
      "SELECT COALESCE(SUM(quantity),0) AS n FROM collection_entries WHERE game = 'mtg'",
    );
    final pkTotal = await v2.rawQuery(
      "SELECT COALESCE(SUM(quantity),0) AS n FROM collection_entries WHERE game = 'pokemon'",
    );

    expect(mtgTotal.first['n'], 3);
    expect(
      pkTotal.first['n'],
      0,
      reason: 'a Pokémon query must not see Magic holdings',
    );
    await v2.close();
  });

  /// A Lorcana printing in the Format Coconut set, named as given.
  TcgCard lorcana(String id, String name) => TcgCard(
    game: CardGame.lorcana,
    id: id,
    setCode: 'coconut',
    setName: 'Format Coconut',
    name: name,
    collectorNumber: '1',
    rarity: 'Promo',
  );

  group('Lorcana data fixes (v4 and v5)', () {
    /// A database at the current schema, which is shape-identical to v3: the
    /// step changes rows, not columns.
    Future<AppDatabase> openV4() async {
      final db = await AppDatabase.openInMemory();
      // The migration is written to run inside an upgrade; an in-memory
      // database has no version to move from, so the step is applied directly.
      return db;
    }

    test(
      'folds the provider casing onto the casing the app queries with',
      () async {
        final db = await openV4();
        final dao = CatalogDao(db.db);

        // What 1.5.0 stored: Lorcast's own spelling, which the app then asked
        // for in lowercase and got a 404 back for.
        await dao.upsertSets(CardGame.lorcana, <TcgSet>[
          const TcgSet(
            game: CardGame.lorcana,
            id: 'set_p1',
            code: 'P1',
            name: 'Promo Set 1',
            setType: 'promo',
          ),
          const TcgSet(
            game: CardGame.lorcana,
            id: 'set_d23',
            code: 'D23',
            name: 'D23 Collection',
            setType: 'expansion',
          ),
          const TcgSet(
            game: CardGame.lorcana,
            id: 'set_3',
            code: '3',
            name: 'Into the Inklands',
            setType: 'expansion',
          ),
        ]);

        await AppDatabase.normaliseLorcanaCodes(db.db);

        final sets = await dao.sets(CardGame.lorcana);
        expect(sets.map((s) => s.code).toList()..sort(), <String>[
          '3',
          'd23',
          'p1',
        ]);
        await db.close();
      },
    );

    test('moves a printing with its set', () async {
      final db = await openV4();
      final dao = CatalogDao(db.db);

      await dao.upsertCards(CardGame.lorcana, <TcgCard>[
        const TcgCard(
          game: CardGame.lorcana,
          id: 'crd_p1a',
          setCode: 'P1',
          setName: 'Promo Set 1',
          name: 'Mickey Mouse – Brave Little Tailor',
          collectorNumber: '1',
          rarity: 'Promo',
        ),
      ]);

      await AppDatabase.normaliseLorcanaCodes(db.db);

      // A card left under the old code would be invisible to the set screen,
      // which asks for the lowercase one.
      expect(await dao.cardsInSet(CardGame.lorcana, 'p1'), hasLength(1));
      expect(await dao.cardsInSet(CardGame.lorcana, 'P1'), isEmpty);
      await db.close();
    });

    test('leaves the other games alone', () async {
      final db = await openV4();
      final dao = CatalogDao(db.db);

      // Magic set codes are lowercase already, but a provider that ever used
      // mixed case must not have its rows rewritten by a Lorcana fix.
      await dao.upsertSets(CardGame.mtg, <TcgSet>[
        const TcgSet(
          game: CardGame.mtg,
          id: 'set_blb',
          code: 'BLB',
          name: 'Bloomburrow',
          setType: 'expansion',
        ),
      ]);

      await AppDatabase.normaliseLorcanaCodes(db.db);

      expect((await dao.sets(CardGame.mtg)).single.code, 'BLB');
      await db.close();
    });

    test('unwraps a subtitle the provider quoted whole', () async {
      final db = await AppDatabase.openInMemory();
      final dao = CatalogDao(db.db);

      await dao.upsertCards(CardGame.lorcana, <TcgCard>[
        lorcana('crd_coco', 'Ariel – "Spectacular Singer"'),
        // Quotes printed inside a subtitle: two of them, and the name ends in
        // one, so only the shape tells this apart from the artefact.
        lorcana('crd_flotsam', 'Flotsam – Ursula\'s "Baby"'),
        // Nothing quoted at all.
        lorcana('crd_elsa', 'Elsa – Snow Queen'),
      ]);

      await AppDatabase.unwrapQuotedSubtitles(db.db);

      final names = {
        for (final c in await dao.cardsInSet(CardGame.lorcana, 'coconut'))
          c.id: c.name,
      };
      expect(names['crd_coco'], 'Ariel – Spectacular Singer');
      expect(names['crd_flotsam'], 'Flotsam – Ursula\'s "Baby"');
      expect(names['crd_elsa'], 'Elsa – Snow Queen');
      await db.close();
    });

    test('leaves other games alone', () async {
      final db = await AppDatabase.openInMemory();
      final dao = CatalogDao(db.db);

      await dao.upsertCards(CardGame.mtg, <TcgCard>[
        const TcgCard(
          game: CardGame.mtg,
          id: 'mtg-1',
          setCode: 'blb',
          setName: 'Bloomburrow',
          name: 'Bello – "Bard" of the Boughs',
          collectorNumber: '1',
          rarity: 'rare',
        ),
      ]);

      await AppDatabase.unwrapQuotedSubtitles(db.db);

      expect(
        (await dao.cardById(CardGame.mtg, 'mtg-1'))!.name,
        'Bello – "Bard" of the Boughs',
      );
      await db.close();
    });

    test(
      'survives a database that already stores the lowercase code',
      () async {
        // Re-running the step must be a no-op rather than an error: an install
        // that shipped the fix and then upgraded again would hit it twice.
        final db = await openV4();
        final dao = CatalogDao(db.db);

        await dao.upsertSets(CardGame.lorcana, <TcgSet>[
          const TcgSet(
            game: CardGame.lorcana,
            id: 'set_p1',
            code: 'p1',
            name: 'Promo Set 1',
            setType: 'promo',
          ),
        ]);

        await AppDatabase.normaliseLorcanaCodes(db.db);

        expect((await dao.sets(CardGame.lorcana)).single.code, 'p1');
        await db.close();
      },
    );
  });

  group('promotional printings (v13)', () {
    /// A printing in the named set of the named game.
    TcgCard printing(CardGame game, String id, String setCode) => TcgCard(
      game: game,
      id: id,
      setCode: setCode,
      setName: setCode.toUpperCase(),
      name: 'Card $id',
      collectorNumber: '1',
      rarity: 'common',
    );

    /// A set of the named game and type.
    TcgSet promoSet(CardGame game, String code, String type) => TcgSet(
      game: game,
      id: code,
      code: code,
      name: code.toUpperCase(),
      setType: type,
    );

    test('are marked from the run they were filed under', () async {
      // The flag arrives with the catalogue now, but a set already on the phone
      // was downloaded before it did - and those rows are exactly the ones a
      // collector is looking at when a card shows SAMPLE across its art.
      final db = await AppDatabase.openInMemory();
      final dao = CatalogDao(db.db);

      await dao.upsertSets(CardGame.gundam, <TcgSet>[
        promoSet(CardGame.gundam, 'gcgpr', 'promo'),
        promoSet(CardGame.gundam, 'gd01', 'expansion'),
      ]);
      await dao.upsertCards(CardGame.gundam, <TcgCard>[
        printing(CardGame.gundam, 'promo-1', 'gcgpr'),
        printing(CardGame.gundam, 'booster-1', 'gd01'),
      ]);

      await AppDatabase.markPromotionalPrintings(db.db);

      expect((await dao.cardById(CardGame.gundam, 'promo-1'))!.promo, isTrue);
      expect(
        (await dao.cardById(CardGame.gundam, 'booster-1'))!.promo,
        isFalse,
        reason: 'a booster printing of the same card is not promotional',
      );
      await db.close();
    });

    test('leave the games whose catalogue states the flag alone', () async {
      // Scryfall marks Magic's promotional printings itself, and a set type is
      // not the same fact: rewriting those rows would replace what the provider
      // said with what this app guessed.
      final db = await AppDatabase.openInMemory();
      final dao = CatalogDao(db.db);

      await dao.upsertSets(CardGame.mtg, <TcgSet>[
        promoSet(CardGame.mtg, 'plst', 'promo'),
      ]);
      await dao.upsertCards(CardGame.mtg, <TcgCard>[
        printing(CardGame.mtg, 'mtg-1', 'plst'),
      ]);

      await AppDatabase.markPromotionalPrintings(db.db);

      expect((await dao.cardById(CardGame.mtg, 'mtg-1'))!.promo, isFalse);
      await db.close();
    });
  });

  group('collection tombstones (v15)', () {
    /// The collection table as it stood before v15: a stack that was removed
    /// simply stopped existing, which is the bug the column fixes.
    const String v14Entries = '''
  CREATE TABLE collection_entries (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    game           TEXT NOT NULL DEFAULT 'mtg',
    card_id        TEXT NOT NULL,
    finish         TEXT NOT NULL DEFAULT 'nonfoil',
    condition      TEXT NOT NULL DEFAULT 'near_mint',
    language       TEXT NOT NULL DEFAULT 'en',
    quantity       INTEGER NOT NULL DEFAULT 1,
    purchase_price REAL,
    purchase_date  INTEGER,
    binder         TEXT NOT NULL DEFAULT '',
    notes          TEXT,
    for_trade      INTEGER NOT NULL DEFAULT 0,
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL
  )
  ''';

    const String v14Unique = '''
  CREATE UNIQUE INDEX idx_entries_unique ON collection_entries(
    game, card_id, finish, condition, language, binder)
  ''';

    Future<Database> openV14() async {
      final Database db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
      );
      await db.execute(v14Entries);
      await db.execute(v14Unique);
      return db;
    }

    test('marks every stack that is already there as still held', () async {
      final Database db = await openV14();
      await db.insert('collection_entries', <String, Object?>{
        'game': 'mtg',
        'card_id': 'lotus-1',
        'quantity': 4,
        'purchase_price': 9.0,
        'binder': 'Binder A',
        'created_at': 1755000000000,
        'updated_at': 1755000000000,
      });

      await AppDatabase.addCollectionTombstones(db);

      final List<Map<String, Object?>> rows = await db.query(
        'collection_entries',
      );
      expect(rows, hasLength(1));
      expect(rows.single['quantity'], 4);
      expect(rows.single['binder'], 'Binder A');
      expect(rows.single['purchase_price'], 9.0);
      // Null means held, which is what every row that existed already was, so
      // there is nothing for the step to decide and nothing it can get wrong.
      expect(rows.single['deleted_at'], isNull);
      await db.close();
    });

    test('leaves the unique index that makes a revival possible', () async {
      final Database db = await openV14();
      await db.insert('collection_entries', <String, Object?>{
        'card_id': 'lotus-1',
        'quantity': 1,
        'created_at': 1755000000000,
        'updated_at': 1755000000000,
      });

      await AppDatabase.addCollectionTombstones(db);

      // The slot a removed stack keeps is the slot a re-added card has to land
      // in. Losing the index here would turn every revival into a second row.
      await expectLater(
        db.insert('collection_entries', <String, Object?>{
          'card_id': 'lotus-1',
          'quantity': 1,
          'created_at': 1755000000000,
          'updated_at': 1755000000000,
        }),
        throwsA(isA<DatabaseException>()),
      );
      await db.close();
    });

    test('a database created from scratch has the column too', () async {
      // The schema and its migration are two spellings of one shape, and a
      // fresh install that never runs the step has to arrive at the same place.
      final db = await AppDatabase.openInMemory();
      final List<Map<String, Object?>> columns = await db.db.rawQuery(
        'PRAGMA table_info(collection_entries)',
      );
      expect(
        columns.map((Map<String, Object?> c) => c['name']),
        contains('deleted_at'),
      );
      await db.close();
    });
  });

  group('decks that can travel (v16)', () {
    /// The deck tables as they stood before v16: a deck had no identity the
    /// client owned, no clocks and no mark, and a line had no clock of its own.
    const List<String> v15DeckSql = <String>[
      '''
    CREATE TABLE decks (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      game       TEXT NOT NULL DEFAULT 'mtg',
      name       TEXT NOT NULL,
      format_id  TEXT NOT NULL DEFAULT '',
      notes      TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''',
      'CREATE INDEX idx_decks_game ON decks(game, updated_at DESC)',
      '''
    CREATE TABLE deck_cards (
      deck_id  INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
      card_id  TEXT NOT NULL,
      board    TEXT NOT NULL DEFAULT 'main',
      quantity INTEGER NOT NULL DEFAULT 1,
      sort     INTEGER NOT NULL DEFAULT 0,
      category TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (deck_id, card_id, board)
    )
  ''',
      'CREATE INDEX idx_deck_cards_deck ON deck_cards(deck_id, board, sort)',
    ];

    /// A v15 database with one deck and two lines of it in it.
    Future<Database> openV15() async {
      final Database db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      for (final String sql in v15DeckSql) {
        await db.execute(sql);
      }
      return db;
    }

    /// The deck a collector has been using since v7, with the stamp it carries.
    Future<int> putDeck(Database db, {int updatedAt = 1755000000000}) => db.insert(
      'decks',
      <String, Object?>{
        'game': 'mtg',
        'name': 'Krenko',
        'format_id': 'commander',
        'notes': 'goblins',
        'created_at': 1754000000000,
        'updated_at': updatedAt,
      },
    );

    List<String> namesOf(List<Map<String, Object?>> columns) =>
        <String>[for (final Map<String, Object?> c in columns) c['name']! as String];

    test('every deck that is already here is given an identity', () async {
      final Database db = await openV15();
      final int id = await putDeck(db);

      await AppDatabase.addDeckSyncColumns(db);

      final List<Map<String, Object?>> rows = await db.query('decks');
      expect(rows, hasLength(1));
      expect(
        rows.single['id'],
        id,
        reason: 'a deck keeps the local id every screen addresses it by',
      );
      expect(rows.single['name'], 'Krenko');
      expect(rows.single['format_id'], 'commander');
      expect(rows.single['notes'], 'goblins');
      final String syncId = rows.single['sync_id']! as String;
      expect(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(syncId),
        isTrue,
        reason: 'one uuid per deck, minted in Dart rather than in SQL: $syncId',
      );
      await db.close();
    });

    test('two decks are given two different identities', () async {
      // The identity is what tells two decks apart on the account, and two
      // devices each numbering their decks 1, 2, 3 are the reason it has to be
      // minted rather than derived.
      final Database db = await openV15();
      await putDeck(db);
      await putDeck(db);

      await AppDatabase.addDeckSyncColumns(db);

      final List<Map<String, Object?>> rows = await db.query('decks');
      expect(
        rows.map((Map<String, Object?> r) => r['sync_id']).toSet(),
        hasLength(2),
      );
      await db.close();
    });

    test('every line takes the stamp of the deck that owns it', () async {
      // A line has never been edited on its own before this version, so the last
      // moment its deck changed is the honest clock for it.
      final Database db = await openV15();
      final int id = await putDeck(db, updatedAt: 1755000000123);
      await db.insert('deck_cards', <String, Object?>{
        'deck_id': id,
        'card_id': 'goblin-chieftain',
        'quantity': 4,
        'sort': 0,
      });
      await db.insert('deck_cards', <String, Object?>{
        'deck_id': id,
        'card_id': 'mogg-war-marshal',
        'board': 'side',
        'quantity': 1,
        'sort': 1,
      });

      await AppDatabase.addDeckSyncColumns(db);

      final List<Map<String, Object?>> lines = await db.query('deck_cards');
      expect(lines, hasLength(2));
      for (final Map<String, Object?> line in lines) {
        expect(line['updated_at'], 1755000000123, reason: 'took the deck stamp');
        expect(line['deleted_at'], isNull);
      }
      expect(
        lines.map((Map<String, Object?> r) => r['quantity']).toSet(),
        <Object?>{4, 1},
        reason: 'nothing about a line was changed but its clock',
      );
      await db.close();
    });

    test('nothing is marked deleted, and no field claims an edit', () async {
      // Every deck that exists is present, and no name has been edited since the
      // clocks appeared - so null is the correct value for all of it and there
      // is no backfill to get wrong. A field with no stamp loses to any stamped
      // edit, which is how an old deck merges correctly the first time it meets
      // the account.
      final Database db = await openV15();
      final int id = await putDeck(db);
      await db.insert('deck_cards', <String, Object?>{
        'deck_id': id,
        'card_id': 'goblin-chieftain',
      });

      await AppDatabase.addDeckSyncColumns(db);

      final Map<String, Object?> deck = (await db.query('decks')).single;
      for (final String column in <String>[
        'name_at',
        'format_at',
        'notes_at',
        'deleted_at',
      ]) {
        expect(deck[column], isNull, reason: column);
      }
      expect(
        (await db.query('deck_cards')).single['deleted_at'],
        isNull,
        reason: 'a line that is in a deck is in the deck',
      );
      await db.close();
    });

    test('the identity is unique, so an arriving deck lands on the one here', () async {
      // SQLite cannot add a unique constraint in place, so it is an index. It is
      // what makes a deck pulled from the account land on the deck that is
      // already here rather than beside it.
      final Database db = await openV15();
      await putDeck(db);
      await AppDatabase.addDeckSyncColumns(db);
      final String syncId = (await db.query('decks')).single['sync_id']! as String;

      await expectLater(
        db.insert('decks', <String, Object?>{
          'game': 'mtg',
          'name': 'a second deck with one identity',
          'format_id': 'modern',
          'created_at': 1755000000000,
          'updated_at': 1755000000000,
          'sync_id': syncId,
        }),
        throwsA(isA<DatabaseException>()),
      );
      await db.close();
    });

    test('a database created from scratch has the same shape', () async {
      // The schema and its migration are two spellings of one shape, and a fresh
      // install that never runs the step has to arrive at the same place - which
      // is the rule _deckSql is shared by both for.
      final Database upgraded = await openV15();
      await AppDatabase.addDeckSyncColumns(upgraded);
      final AppDatabase fresh = await AppDatabase.openInMemory(own: true);

      for (final String table in <String>['decks', 'deck_cards']) {
        final List<Map<String, Object?>> fromMigration = await upgraded.rawQuery(
          'PRAGMA table_info($table)',
        );
        final List<Map<String, Object?>> fromSchema = await fresh.db.rawQuery(
          'PRAGMA table_info($table)',
        );
        expect(
          namesOf(fromMigration),
          namesOf(fromSchema),
          reason: '$table must be the same table either way',
        );
      }

      final List<Map<String, Object?>> indexes = await fresh.db.rawQuery(
        "PRAGMA index_list('decks')",
      );
      expect(
        indexes.map((Map<String, Object?> i) => i['name']),
        contains('idx_decks_sync'),
        reason: 'the schema needs the identity index too',
      );
      await upgraded.close();
      await fresh.close();
    });

    test('the deck tables createDecks builds are already this shape', () async {
      // The v16 step adds its columns to decks that are already there. A
      // database below v7 has no deck at all, and createDecks hands it the shape
      // this version is - so there is nothing to add and nothing to backfill
      // there, which is what the upgrade switch reads when it skips the step.
      final Database db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );

      await AppDatabase.createDecks(db);

      for (final String table in <String>['decks', 'deck_cards']) {
        final List<Map<String, Object?>> columns = await db.rawQuery(
          'PRAGMA table_info($table)',
        );
        expect(namesOf(columns), contains('deleted_at'), reason: table);
      }
      expect(
        namesOf(await db.rawQuery('PRAGMA table_info(decks)')),
        containsAll(<String>['sync_id', 'name_at', 'format_at', 'notes_at']),
      );
      expect(
        namesOf(await db.rawQuery('PRAGMA table_info(deck_cards)')),
        contains('updated_at'),
      );
      // And so the step would fail on it rather than being quietly harmless,
      // which is the reason the switch does not run it there.
      await expectLater(
        AppDatabase.addDeckSyncColumns(db),
        throwsA(isA<DatabaseException>()),
      );
      await db.close();
    });
  });

  group('card identity scoped to the game (v14)', () {
    /// The cards table as it stood before v14: the id was the whole primary
    /// key, and the game was only a column on the row.
    const String v13Cards = '''
  CREATE TABLE cards (
    id                  TEXT PRIMARY KEY,
    game                TEXT NOT NULL DEFAULT 'mtg',
    oracle_id           TEXT,
    set_code            TEXT NOT NULL,
    set_name            TEXT,
    name                TEXT NOT NULL,
    collector_number    TEXT NOT NULL,
    collector_sort      INTEGER NOT NULL DEFAULT 0,
    rarity              TEXT NOT NULL DEFAULT 'unknown',
    layout              TEXT,
    type_line           TEXT,
    oracle_text         TEXT,
    mana_cost           TEXT,
    cmc                 REAL,
    colors              TEXT NOT NULL DEFAULT '',
    color_identity      TEXT NOT NULL DEFAULT '',
    artist              TEXT,
    flavor_text         TEXT,
    image_small         TEXT,
    image_normal        TEXT,
    image_large         TEXT,
    image_art_crop      TEXT,
    image_png           TEXT,
    back_image_small    TEXT,
    back_image_normal   TEXT,
    prices_json         TEXT,
    prices_updated_at   INTEGER,
    digital             INTEGER NOT NULL DEFAULT 0,
    promo               INTEGER NOT NULL DEFAULT 0,
    reprint             INTEGER NOT NULL DEFAULT 0,
    reserved            INTEGER NOT NULL DEFAULT 0,
    full_art            INTEGER NOT NULL DEFAULT 0,
    booster             INTEGER NOT NULL DEFAULT 0,
    foil                INTEGER NOT NULL DEFAULT 0,
    nonfoil             INTEGER NOT NULL DEFAULT 0,
    edhrec_rank         INTEGER,
    released_at         TEXT,
    extras_json         TEXT
  )
  ''';

    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await db.execute(v13Cards);
    });

    tearDown(() async => db.close());

    test('keeps every printing and everything it knew', () async {
      await db.insert('cards', <String, Object?>{
        'id': 'bt26-001',
        'game': 'digimon',
        'set_code': 'BT26',
        'set_name': 'Timeless Bonds',
        'name': 'Yokomon',
        'collector_number': '001',
        'collector_sort': 1,
        'rarity': 'common',
        'prices_json': '{"byFinish":{"normal":0.09}}',
        'extras_json': '{"number":"BT26-001"}',
        'released_at': '2026-09-04',
      });

      await AppDatabase.scopeCardIdsToGame(db);

      final rows = await db.query('cards');
      expect(rows, hasLength(1));
      expect(rows.single['name'], 'Yokomon');
      expect(rows.single['game'], 'digimon');
      expect(rows.single['collector_number'], '001');
      expect(rows.single['collector_sort'], 1);
      expect(rows.single['prices_json'], '{"byFinish":{"normal":0.09}}');
      expect(rows.single['extras_json'], '{"number":"BT26-001"}');
      expect(rows.single['released_at'], '2026-09-04');
      // A column nothing wrote keeps its default rather than arriving null.
      expect(rows.single['digital'], 0);
    });

    test('before v14 the second game using an id took the first row', () async {
      // Not a wish, a record: it is what the old key did, and it is the reason
      // the table is rebuilt. It also holds the fixture above to being the
      // shape it claims to be - a v13 table with a single-column key would
      // refuse the second insert outright.
      await db.insert('cards', <String, Object?>{
        'id': '1',
        'game': 'mtg',
        'set_code': 'blb',
        'name': "Innkeeper's Talent",
        'collector_number': '1',
      });
      await db.insert('cards', <String, Object?>{
        'id': '1',
        'game': 'digimon',
        'set_code': 'BT26',
        'name': 'Yokomon',
        'collector_number': '001',
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      final rows = await db.query('cards');
      expect(rows, hasLength(1));
      expect(rows.single['game'], 'digimon');
      expect(
        rows.single['name'],
        'Yokomon',
        reason: 'the id was the whole key, so the second write won',
      );
    });

    test('after v14 the same id in two games is two printings', () async {
      await db.insert('cards', <String, Object?>{
        'id': '1',
        'game': 'mtg',
        'set_code': 'blb',
        'name': "Innkeeper's Talent",
        'collector_number': '1',
      });

      await AppDatabase.scopeCardIdsToGame(db);

      await db.insert('cards', <String, Object?>{
        'id': '1',
        'game': 'digimon',
        'set_code': 'BT26',
        'name': 'Yokomon',
        'collector_number': '001',
      });

      final rows = await db.query('cards', orderBy: 'game');
      expect(rows, hasLength(2));
      expect(rows.first['game'], 'digimon');
      expect(rows.first['name'], 'Yokomon');
      expect(rows.last['game'], 'mtg');
      expect(
        rows.last['name'],
        "Innkeeper's Talent",
        reason: 'the row that was there first kept its game',
      );
    });
  });
}
