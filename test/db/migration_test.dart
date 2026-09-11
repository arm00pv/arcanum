import 'dart:io';

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
  batch.execute('ALTER TABLE portfolio_snapshots_v2 RENAME TO portfolio_snapshots');

  for (final table in ['cards', 'collection_entries', 'price_history', 'alerts']) {
    batch.execute("ALTER TABLE $table ADD COLUMN game TEXT NOT NULL DEFAULT 'mtg'");
  }
  batch.execute('ALTER TABLE cards ADD COLUMN flavor_text TEXT');
  batch.execute('ALTER TABLE cards ADD COLUMN booster INTEGER NOT NULL DEFAULT 0');
  batch.execute('ALTER TABLE cards ADD COLUMN foil INTEGER NOT NULL DEFAULT 0');
  batch.execute('ALTER TABLE cards ADD COLUMN nonfoil INTEGER NOT NULL DEFAULT 0');
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
    expect(entries.first['game'], 'mtg',
        reason: 'pre-existing rows become Magic rows');

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
    expect(both, hasLength(2),
        reason: 'the same set code must be allowed in both games');

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
        "SELECT COALESCE(SUM(quantity),0) AS n FROM collection_entries WHERE game = 'mtg'");
    final pkTotal = await v2.rawQuery(
        "SELECT COALESCE(SUM(quantity),0) AS n FROM collection_entries WHERE game = 'pokemon'");

    expect(mtgTotal.first['n'], 3);
    expect(pkTotal.first['n'], 0,
        reason: 'a Pokémon query must not see Magic holdings');
    await v2.close();
  });
}
