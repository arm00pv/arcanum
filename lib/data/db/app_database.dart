import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Opens and migrates the Arcanum SQLite database.
///
/// The database is the app's single source of truth. Everything the user sees
/// (sets, cards, their collection, accumulated price history and portfolio
/// snapshots) lives here so the app is fully usable offline once a set has been
/// browsed once.
///
/// Since v2 every row carries a `game` column. The two games share a schema but
/// never share rows: a Pokémon collection and a Magic collection are independent,
/// and every query is scoped by game.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'arcanum.db';

  /// v1 — Magic only.
  /// v2 — multi-game: a `game` column on every table, composite keys on `sets`
  ///      and `portfolio_snapshots`.
  /// v3 — price alerts gain a `baseline`, the price the rule was armed at, so
  ///      percentage alerts have something stable to measure against.
  /// v4 — Lorcana set codes are folded to lowercase (see
  ///      [normaliseLorcanaCodes]).
  /// v5 — Lorcana names carrying a whole-subtitle quote artefact are rewritten
  ///      (see [unwrapQuotedSubtitles]).
  /// v6 — a `wanted_cards` table, so a want survives closing the card.
  /// v7 — `decks` and `deck_cards`, so a deck is a thing the app knows about.
  /// v8 — `collection_entries.for_trade`, so a trade pile exists.
  /// v9 — alerts remember the name of the card they watch, so an alert is
  ///      readable without the catalogue - in a backup, in a notification sent
  ///      from the collector's own server, and on a phone that has never
  ///      downloaded the set.
  /// v10 - a sealed_products table, so a booster box is a holding like any
  ///      other and reaches the valuation instead of being a note in a drawer.
  /// v11 - card_lots and card_sales. A stack knows what it cost on average and
  ///      not what each purchase cost, which is enough to value a collection
  ///      and not enough to say what a part of it realised when part of it was
  ///      sold, which is what a tax year is asked for.
  /// v12 - box_compositions. What a box holds is the one figure a box's value
  ///      needs and no feed publishes, so it is stated once per set and kept,
  ///      rather than typed in every time the question is asked.
  /// v13 - the promo flag on cards TCGplayer catalogues. A printing filed under a
  ///      promotional run is a promotional card, and on Gundam that is the
  ///      difference between a photograph of the card and the publisher's sample
  ///      image with SAMPLE across it. Sets already on the phone were downloaded
  ///      before the catalogue wrote the flag, so it is derived here from the
  ///      set each card belongs to.
  static const _version = 13;

  static AppDatabase? _instance;

  /// Opens (or creates) the shared database instance.
  static Future<AppDatabase> open() async {
    if (_instance != null) return _instance!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, _fileName);
    final db = await openDatabase(
      path,
      version: _version,
      onConfigure: (d) async {
        await d.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (d, v) async {
        await _createSchema(d);
      },
      onUpgrade: (d, from, to) async {
        if (from < 2) await _migrateV1ToV2(d);
        if (from < 3) await _migrateV2ToV3(d);
        if (from < 4) await normaliseLorcanaCodes(d);
        if (from < 5) await unwrapQuotedSubtitles(d);
        if (from < 6) await createWantedCards(d);
        if (from < 7) await createDecks(d);
        if (from < 8) await addForTrade(d);
        if (from < 9) await addAlertLabels(d);
        if (from < 10) await createSealedProducts(d);
        if (from < 11) await createLotsAndSales(d, backfill: true);
        if (from < 12) await createBoxCompositions(d);
        if (from < 13) await markPromotionalPrintings(d);
      },
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  /// Opens the same database for reading only, without touching the schema.
  ///
  /// The automatic backup runs in its own isolate and may run while the app is
  /// open, so it must never migrate and must never write: read-only means it
  /// cannot block the app behind a write lock, and cannot corrupt a database it
  /// shares with a running app. It deliberately bypasses [_instance], because
  /// sharing one connection across two isolates is exactly what sqflite warns
  /// about.
  static Future<AppDatabase> openReadOnly() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, _fileName);
    try {
      return AppDatabase._(
        await openDatabase(
          path,
          readOnly: true,
          singleInstance: false,
          // sqflite opens a read-only database in a mode where only query and
          // rawQuery are permitted, and rejects execute() outright - so the
          // pragma has to be asked for as a query. The app may be mid-write
          // when this fires, and waiting is better than failing: the archive is
          // one SELECT per table and the lock clears.
          onConfigure: (Database d) => d.rawQuery('PRAGMA busy_timeout = 8000'),
        ),
      );
    } on DatabaseException {
      // Android refuses a read-only handle in a few legitimate situations -
      // a journal that needs replaying, a database the app is part-way through
      // creating. The job only ever issues SELECTs, so a normal handle is safe
      // here; it gives up the guarantee that this connection cannot write, and
      // keeps the backup working, which is the trade worth making.
      return AppDatabase._(
        await openDatabase(
          path,
          singleInstance: false,
          onConfigure: (Database d) => d.execute('PRAGMA busy_timeout = 8000'),
        ),
      );
    }
  }

  /// A database backed by memory, for tests.
  static Future<AppDatabase> openInMemory() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: _version,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, v) => _createSchema(d),
    );
    return AppDatabase._(db);
  }

  Future<void> close() async {
    await db.close();
    _instance = null;
  }

  // --------------------------------------------------------------- v2 schema

  static Future<void> _createSchema(Database d) async {
    final batch = d.batch();

    // ---------------------------------------------------------------- sets
    batch.execute('''
      CREATE TABLE sets (
        game             TEXT NOT NULL DEFAULT 'mtg',
        code             TEXT NOT NULL,
        id               TEXT NOT NULL,
        name             TEXT NOT NULL,
        set_type         TEXT NOT NULL,
        released_at      TEXT,
        card_count       INTEGER NOT NULL DEFAULT 0,
        printed_size     INTEGER,
        icon_svg_uri     TEXT,
        logo_uri         TEXT,
        series           TEXT,
        digital          INTEGER NOT NULL DEFAULT 0,
        foil_only        INTEGER NOT NULL DEFAULT 0,
        nonfoil_only     INTEGER NOT NULL DEFAULT 0,
        parent_set_code  TEXT,
        block_code       TEXT,
        block            TEXT,
        collector_number_start INTEGER,
        catalogued_at    INTEGER NOT NULL DEFAULT 0,
        fetched_at       INTEGER NOT NULL,
        PRIMARY KEY (game, code)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_sets_game_released ON sets(game, released_at DESC)',
    );
    batch.execute('CREATE INDEX idx_sets_type ON sets(game, set_type)');

    // --------------------------------------------------------------- cards
    batch.execute('''
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
    ''');
    batch.execute(
      'CREATE INDEX idx_cards_set ON cards(game, set_code, collector_sort, collector_number)',
    );
    batch.execute(
      'CREATE INDEX idx_cards_name ON cards(game, name COLLATE NOCASE)',
    );
    batch.execute('CREATE INDEX idx_cards_oracle ON cards(game, oracle_id)');
    batch.execute('CREATE INDEX idx_cards_rarity ON cards(game, rarity)');

    // ---------------------------------------------------------- collection
    batch.execute('''
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
    ''');
    batch.execute(
      'CREATE UNIQUE INDEX idx_entries_unique ON collection_entries(game, card_id, finish, condition, language, binder)',
    );
    batch.execute('CREATE INDEX idx_entries_game ON collection_entries(game)');
    batch.execute(
      'CREATE INDEX idx_entries_card ON collection_entries(card_id)',
    );
    batch.execute(
      'CREATE INDEX idx_entries_binder ON collection_entries(game, binder)',
    );

    // ---------------------------------------------------------- cost basis
    batch.execute(_lotsSql);
    batch.execute(_salesSql);
    batch.execute(
      'CREATE INDEX idx_lots_card ON card_lots(game, card_id, acquired_on)',
    );
    batch.execute('CREATE INDEX idx_lots_entry ON card_lots(entry_id)');
    batch.execute(
      'CREATE INDEX idx_sales_game ON card_sales(game, sold_on DESC)',
    );
    batch.execute('CREATE INDEX idx_sales_card ON card_sales(game, card_id)');

    // ------------------------------------------------------- price history
    batch.execute('''
      CREATE TABLE price_history (
        card_id TEXT NOT NULL,
        game    TEXT NOT NULL DEFAULT 'mtg',
        finish  TEXT NOT NULL,
        date    TEXT NOT NULL,
        price   REAL NOT NULL,
        source  TEXT NOT NULL DEFAULT 'snapshot',
        PRIMARY KEY (card_id, finish, date, source)
      ) WITHOUT ROWID
    ''');
    batch.execute(
      'CREATE INDEX idx_history_lookup ON price_history(card_id, finish, date DESC)',
    );
    batch.execute(
      'CREATE INDEX idx_history_game ON price_history(game, date DESC)',
    );

    // --------------------------------------------------- portfolio tracking
    batch.execute('''
      CREATE TABLE portfolio_snapshots (
        game         TEXT NOT NULL DEFAULT 'mtg',
        date         TEXT NOT NULL,
        total_value  REAL NOT NULL,
        unique_cards INTEGER NOT NULL,
        total_cards  INTEGER NOT NULL,
        PRIMARY KEY (game, date)
      )
    ''');

    // ------------------------------------------------------------- alerts
    batch.execute('''
      CREATE TABLE alerts (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        game         TEXT NOT NULL DEFAULT 'mtg',
        card_id      TEXT NOT NULL,
        finish       TEXT NOT NULL DEFAULT 'nonfoil',
        kind         TEXT NOT NULL,
        threshold    REAL NOT NULL,
        created_at   INTEGER NOT NULL,
        triggered_at INTEGER,
        baseline     REAL,
        last_value   REAL,
        -- Denormalised so an alert is readable where the catalogue is not:
        -- in a backup, and in a notification sent from the collector's own
        -- server. See addAlertLabels for the migration that added them.
        card_name    TEXT,
        set_code     TEXT
      )
    ''');
    batch.execute('CREATE INDEX idx_alerts_card ON alerts(game, card_id)');

    // --------------------------------------------------------------- wants
    batch.execute(_wantedCardsSql);
    batch.execute(
      'CREATE INDEX idx_wanted_game ON wanted_cards(game, created_at DESC)',
    );

    // --------------------------------------------------------------- decks
    for (final sql in _deckSql) {
      batch.execute(sql);
    }

    // ------------------------------------------------------ sealed product
    batch.execute(_sealedSql);
    batch.execute(
      'CREATE INDEX idx_sealed_game ON sealed_products(game, created_at DESC)',
    );
    batch.execute(_boxSql);
    batch.execute(
      'CREATE UNIQUE INDEX idx_box_set ON box_compositions(game, set_code)',
    );

    // ------------------------------------------------------------ metadata
    batch.execute('''
      CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  /// The wants table, shared by [_createSchema] and the v6 upgrade so a schema
  /// and its migration cannot drift into different shapes.
  static const _wantedCardsSql = '''
    CREATE TABLE wanted_cards (
      game       TEXT NOT NULL DEFAULT 'mtg',
      card_id    TEXT NOT NULL,
      note       TEXT,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (game, card_id)
    )
  ''';

  /// v6: the collector can mark a card as wanted before owning it.
  ///
  /// The table is created rather than converted from anything: before this
  /// version there was no way to record a want, so there is nothing to carry
  /// over, and a wants list that started empty is the truth.
  static Future<void> createWantedCards(DatabaseExecutor d) async {
    await d.execute(_wantedCardsSql);
    await d.execute(
      'CREATE INDEX idx_wanted_game ON wanted_cards(game, created_at DESC)',
    );
  }

  /// The deck tables, shared by [_createSchema] and the v7 upgrade.
  ///
  /// `deck_cards` references `decks` so that deleting a deck cannot leave its
  /// lines behind: the app opens its database with foreign keys on, and a
  /// cascade is one statement instead of two that can disagree.
  static const _deckSql = <String>[
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

  /// v8: a stack can be marked as up for trade.
  ///
  /// A column rather than a table: what is for trade is a fact about cards the
  /// collector already owns, and every existing row is correctly "not for
  /// trade" the moment the column appears.
  static Future<void> addForTrade(DatabaseExecutor d) async {
    await d.execute(
      'ALTER TABLE collection_entries '
      'ADD COLUMN for_trade INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// v9: alerts learn the name of what they are watching.
  ///
  /// The card name was always looked up from the catalogue at display time,
  /// which meant an alert was unreadable anywhere the catalogue was not - in a
  /// backup, in a notification sent from the collector's own server, and on a
  /// phone that had never downloaded the set. Existing alerts are filled in from
  /// the catalogue where it can answer.
  static Future<void> addAlertLabels(DatabaseExecutor d) async {
    await d.execute('ALTER TABLE alerts ADD COLUMN card_name TEXT');
    await d.execute('ALTER TABLE alerts ADD COLUMN set_code TEXT');
    await d.execute('''
      UPDATE alerts SET
        card_name = (
          SELECT cards.name FROM cards
          WHERE cards.id = alerts.card_id AND cards.game = alerts.game
          LIMIT 1
        ),
        set_code = (
          SELECT cards.set_code FROM cards
          WHERE cards.id = alerts.card_id AND cards.game = alerts.game
          LIMIT 1
        )
      WHERE card_name IS NULL
    ''');
  }

  /// The sealed product table, shared by the schema and the v10 upgrade.
  ///
  /// Sealed holdings are their own table rather than rows in
  /// collection_entries: a box has no finish, no condition and no printing, and
  /// every query over the card collection - totals, completion, decks, scans -
  /// would have to learn to exclude it. A separate table is a separate kind of
  /// thing, which is what it is.
  static const _sealedSql = '''
    CREATE TABLE sealed_products (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      game          TEXT NOT NULL DEFAULT 'mtg',
      set_code      TEXT NOT NULL DEFAULT '',
      set_name      TEXT NOT NULL DEFAULT '',
      name          TEXT NOT NULL,
      category      TEXT NOT NULL DEFAULT 'other',
      quantity      INTEGER NOT NULL DEFAULT 1,
      unit_cost     REAL,
      unit_value    REAL,
      value_as_of   INTEGER,
      location      TEXT NOT NULL DEFAULT '',
      note          TEXT NOT NULL DEFAULT '',
      product_id    TEXT NOT NULL DEFAULT '',
      created_at    INTEGER NOT NULL
    )
  ''';

  /// The cost-basis tables, shared by [_createSchema] and the v11 upgrade so
  /// there is one definition of them.
  static const _lotsSql = '''
    CREATE TABLE card_lots (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      game        TEXT NOT NULL DEFAULT 'mtg',
      card_id     TEXT NOT NULL,
      entry_id    INTEGER,
      quantity    INTEGER NOT NULL DEFAULT 0,
      unit_cost   REAL,
      acquired_on INTEGER,
      note        TEXT NOT NULL DEFAULT '',
      created_at  INTEGER NOT NULL
    )
  ''';

  static const _salesSql = '''
    CREATE TABLE card_sales (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      game       TEXT NOT NULL DEFAULT 'mtg',
      card_id    TEXT NOT NULL,
      quantity   INTEGER NOT NULL DEFAULT 1,
      unit_price REAL NOT NULL DEFAULT 0,
      fees       REAL NOT NULL DEFAULT 0,
      finish     TEXT NOT NULL DEFAULT 'nonfoil',
      condition  TEXT NOT NULL DEFAULT 'near_mint',
      sold_on    INTEGER NOT NULL,
      platform   TEXT NOT NULL DEFAULT '',
      note       TEXT NOT NULL DEFAULT '',
      entry_id   INTEGER,
      language   TEXT NOT NULL DEFAULT 'en',
      binder     TEXT NOT NULL DEFAULT '',
      matches    TEXT NOT NULL DEFAULT '[]',
      created_at INTEGER NOT NULL
    )
  ''';

  /// v11: what each purchase cost, and what each sale realised against it.
  ///
  /// The tables are created empty on a new install. An existing collection is
  /// converted rather than left behind: every stack becomes one lot at the
  /// price the stack already carries, which is exactly what the app knew about
  /// it - a stack bought in one go is one purchase, and one bought in two was
  /// already blended into a single average price before this version existed.
  /// A stack with no recorded price becomes a lot with no recorded price, and
  /// the tax sheet reports it as an unknown cost rather than as a gain.
  static Future<void> createLotsAndSales(
    DatabaseExecutor d, {
    bool backfill = false,
  }) async {
    await d.execute(_lotsSql);
    await d.execute(_salesSql);
    await d.execute(
      'CREATE INDEX idx_lots_card ON card_lots(game, card_id, acquired_on)',
    );
    await d.execute('CREATE INDEX idx_lots_entry ON card_lots(entry_id)');
    await d.execute(
      'CREATE INDEX idx_sales_game ON card_sales(game, sold_on DESC)',
    );
    await d.execute('CREATE INDEX idx_sales_card ON card_sales(game, card_id)');
    if (!backfill) return;
    await d.rawInsert(
      'INSERT INTO card_lots '
      '(game, card_id, entry_id, quantity, unit_cost, acquired_on, note, '
      'created_at) '
      'SELECT game, card_id, id, quantity, purchase_price, purchase_date, '
      "'', ? FROM collection_entries WHERE quantity > 0",
      <Object?>[DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// v12: what each set's boxes are assumed to hold.
  ///
  /// One row per set and not one per box: a print run is one print run, so two
  /// boxes of the same set hold the same thing, and a composition that had to be
  /// retyped for every box on the shelf would be retyped wrong. Created empty -
  /// the app has no source for pull rates and will not invent one, so a set with
  /// no composition is a set whose boxes are valued as boxes, not as cards.
  static const _boxSql = '''
    CREATE TABLE box_compositions (
      id             INTEGER PRIMARY KEY AUTOINCREMENT,
      game           TEXT NOT NULL DEFAULT 'mtg',
      set_code       TEXT NOT NULL DEFAULT '',
      packs          INTEGER NOT NULL DEFAULT 0,
      cards_per_pack INTEGER NOT NULL DEFAULT 0,
      slots          TEXT NOT NULL DEFAULT '[]',
      updated_at     INTEGER NOT NULL
    )
  ''';

  static Future<void> createBoxCompositions(DatabaseExecutor d) async {
    await d.execute(_boxSql);
    await d.execute(
      'CREATE UNIQUE INDEX idx_box_set ON box_compositions(game, set_code)',
    );
  }

  /// v10: sealed product is tracked as a holding.
  ///
  /// Created rather than converted: nothing before this version could record a
  /// box, so an empty shelf is the truth.
  static Future<void> createSealedProducts(DatabaseExecutor d) async {
    await d.execute(_sealedSql);
    await d.execute(
      'CREATE INDEX idx_sealed_game ON sealed_products(game, created_at DESC)',
    );
  }

  /// v7: decks, and the cards in them.
  ///
  /// Created rather than converted: nothing before this version recorded a
  /// deck, so there is nothing to move and an empty deck list is the truth.
  static Future<void> createDecks(DatabaseExecutor d) async {
    for (final sql in _deckSql) {
      await d.execute(sql);
    }
  }

  // -------------------------------------------------------------- migration

  /// v4: stores Lorcana set codes the way the rest of the app addresses them.
  ///
  /// Lorcast identifies a set by a case-sensitive code - `P1` answers and `p1`
  /// does not - while every query in this app compares set codes in lowercase.
  /// The first release to ship Lorcana kept the provider's casing in this table,
  /// so the lowercased code the app then asked for matched nothing and nine
  /// promo and event sets came back empty. Existing rows are folded to the
  /// casing the app now stores; no cards were ever downloadable for those sets,
  /// so there is nothing else to move.
  ///
  /// `OR REPLACE` because folding two rows onto one code would otherwise abort
  /// the upgrade and leave the database half-migrated.
  static Future<void> normaliseLorcanaCodes(DatabaseExecutor d) async {
    await d.execute(
      "UPDATE OR REPLACE sets SET code = lower(code) WHERE game = 'lorcana'",
    );
    await d.execute(
      "UPDATE OR REPLACE cards SET set_code = lower(set_code) "
      "WHERE game = 'lorcana'",
    );
  }

  /// v5: removes a pair of quotes Lorcast wrapped around a whole subtitle.
  ///
  /// Twenty printings are stored as `Ariel – "Spectacular Singer"`, an artefact
  /// of how those sets were entered rather than anything printed on the card.
  /// Names are cleaned as they are downloaded; this rewrites the rows already on
  /// disk, which would otherwise keep their quotes until the set happened to be
  /// downloaded again.
  ///
  /// The match is deliberately narrow. `Flotsam – Ursula's "Baby"` also holds
  /// two quotes and also ends in one, so the artefact is identified by its
  /// shape: two quotes in the name, a quote opening the subtitle, and a quote
  /// closing the name.
  static Future<void> unwrapQuotedSubtitles(DatabaseExecutor d) async {
    await d.execute(
      'UPDATE cards SET name = '
      "  replace(substr(name, 1, length(name) - 1), ' – \"', ' – ') "
      "WHERE game = 'lorcana' "
      "  AND name LIKE '% – \"%' "
      "  AND name LIKE '%\"' "
      "  AND length(name) - length(replace(name, '\"', '')) = 2",
    );
  }

  /// v13: marks the printings that came out of a promotional run.
  ///
  /// TCGplayer files a run of promotional cards as a group of its own, and the
  /// catalogue reads that group's name into [TcgSet.setType] - which is already
  /// on disk for every set, so the flag can be derived from it rather than
  /// needing a re-download. Only the five games that shop catalogues are
  /// touched: Magic's promotional printings are marked by Scryfall and always
  /// have been, and rewriting those rows from a set type would be guessing at a
  /// fact the catalogue already stated.
  ///
  /// Nothing is cleared. No printing of these five games carried the flag
  /// before this version, so setting it where the set is promotional is the
  /// whole of the correction.
  static Future<void> markPromotionalPrintings(DatabaseExecutor d) async {
    for (final String game in const <String>[
      'onepiece',
      'swu',
      'digimon',
      'dragonball',
      'gundam',
    ]) {
      await d.execute(
        'UPDATE cards SET promo = 1 '
        "WHERE game = ? AND set_code IN "
        '(SELECT code FROM sets WHERE game = ? AND set_type = ?)',
        <Object?>[game, game, 'promo'],
      );
    }
  }

  /// v2 -> v3: alerts learn the price they were armed at.
  ///
  /// Existing alerts adopt their last observed price as the baseline, which is
  /// the closest honest approximation available and keeps percentage rules
  /// meaningful rather than silently inert.
  static Future<void> _migrateV2ToV3(Database d) async {
    final batch = d.batch();
    batch.execute('ALTER TABLE alerts ADD COLUMN baseline REAL');
    batch.execute(
      'UPDATE alerts SET baseline = last_value WHERE baseline IS NULL',
    );
    await batch.commit(noResult: true);
  }

  /// Upgrades a Magic-only v1 database to the multi-game v2 schema.
  ///
  /// Existing rows become Magic rows, so an upgrade never loses a collection.
  /// `sets` and `portfolio_snapshots` need a table rebuild because SQLite cannot
  /// alter a primary key in place; the rest only need a column.
  static Future<void> _migrateV1ToV2(Database d) async {
    final batch = d.batch();

    // sets: primary key becomes (game, code).
    batch.execute('''
      CREATE TABLE sets_v2 (
        game             TEXT NOT NULL DEFAULT 'mtg',
        code             TEXT NOT NULL,
        id               TEXT NOT NULL,
        name             TEXT NOT NULL,
        set_type         TEXT NOT NULL,
        released_at      TEXT,
        card_count       INTEGER NOT NULL DEFAULT 0,
        printed_size     INTEGER,
        icon_svg_uri     TEXT,
        logo_uri         TEXT,
        series           TEXT,
        digital          INTEGER NOT NULL DEFAULT 0,
        foil_only        INTEGER NOT NULL DEFAULT 0,
        nonfoil_only     INTEGER NOT NULL DEFAULT 0,
        parent_set_code  TEXT,
        block_code       TEXT,
        block            TEXT,
        collector_number_start INTEGER,
        catalogued_at    INTEGER NOT NULL DEFAULT 0,
        fetched_at       INTEGER NOT NULL,
        PRIMARY KEY (game, code)
      )
    ''');
    batch.execute('''
      INSERT INTO sets_v2 (game, code, id, name, set_type, released_at, card_count,
                           printed_size, icon_svg_uri, digital, foil_only, nonfoil_only,
                           parent_set_code, block_code, block, catalogued_at, fetched_at)
      SELECT 'mtg', code, id, name, set_type, released_at, card_count,
             printed_size, icon_svg_uri, digital, foil_only, nonfoil_only,
             parent_set_code, block_code, block, catalogued_at, fetched_at
      FROM sets
    ''');
    batch.execute('DROP TABLE sets');
    batch.execute('ALTER TABLE sets_v2 RENAME TO sets');
    batch.execute(
      'CREATE INDEX idx_sets_game_released ON sets(game, released_at DESC)',
    );
    batch.execute('CREATE INDEX idx_sets_type ON sets(game, set_type)');

    // portfolio_snapshots: primary key becomes (game, date).
    batch.execute('''
      CREATE TABLE portfolio_snapshots_v2 (
        game         TEXT NOT NULL DEFAULT 'mtg',
        date         TEXT NOT NULL,
        total_value  REAL NOT NULL,
        unique_cards INTEGER NOT NULL,
        total_cards  INTEGER NOT NULL,
        PRIMARY KEY (game, date)
      )
    ''');
    batch.execute('''
      INSERT INTO portfolio_snapshots_v2 (game, date, total_value, unique_cards, total_cards)
      SELECT 'mtg', date, total_value, unique_cards, total_cards FROM portfolio_snapshots
    ''');
    batch.execute('DROP TABLE portfolio_snapshots');
    batch.execute(
      'ALTER TABLE portfolio_snapshots_v2 RENAME TO portfolio_snapshots',
    );

    // The remaining tables only gain columns.
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
    batch.execute(
      'ALTER TABLE cards ADD COLUMN foil INTEGER NOT NULL DEFAULT 0',
    );
    batch.execute(
      'ALTER TABLE cards ADD COLUMN nonfoil INTEGER NOT NULL DEFAULT 0',
    );
    batch.execute('ALTER TABLE cards ADD COLUMN prices_json TEXT');
    batch.execute('ALTER TABLE cards ADD COLUMN extras_json TEXT');

    // Refresh the indexes that now lead with the game column.
    batch.execute('DROP INDEX IF EXISTS idx_cards_set');
    batch.execute('DROP INDEX IF EXISTS idx_cards_name');
    batch.execute('DROP INDEX IF EXISTS idx_cards_oracle');
    batch.execute('DROP INDEX IF EXISTS idx_cards_rarity');
    batch.execute('DROP INDEX IF EXISTS idx_entries_unique');
    batch.execute('DROP INDEX IF EXISTS idx_entries_binder');
    batch.execute('DROP INDEX IF EXISTS idx_alerts_card');
    batch.execute(
      'CREATE INDEX idx_cards_set ON cards(game, set_code, collector_sort, collector_number)',
    );
    batch.execute(
      'CREATE INDEX idx_cards_name ON cards(game, name COLLATE NOCASE)',
    );
    batch.execute('CREATE INDEX idx_cards_oracle ON cards(game, oracle_id)');
    batch.execute('CREATE INDEX idx_cards_rarity ON cards(game, rarity)');
    batch.execute(
      'CREATE UNIQUE INDEX idx_entries_unique ON collection_entries(game, card_id, finish, condition, language, binder)',
    );
    batch.execute('CREATE INDEX idx_entries_game ON collection_entries(game)');
    batch.execute(
      'CREATE INDEX idx_entries_binder ON collection_entries(game, binder)',
    );
    batch.execute('CREATE INDEX idx_alerts_card ON alerts(game, card_id)');
    batch.execute(
      'CREATE INDEX IF NOT EXISTS idx_history_game ON price_history(game, date DESC)',
    );

    await batch.commit(noResult: true);
  }
}
