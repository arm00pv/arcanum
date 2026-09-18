import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An account that answers instantly and remembers what it was told.
class FakeAccount implements AccountTable {
  final List<Map<String, Object?>> written = <Map<String, Object?>>[];
  List<Map<String, Object?>> remote = <Map<String, Object?>>[];

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {
    written.addAll(rows);
  }

  @override
  Future<List<Map<String, Object?>>> fetch(CardGame game) async => remote;
}

Map<String, Object?> accountRow({
  required String cardId,
  int quantity = 1,
  String updated = '2026-09-10T12:00:00.000Z',
}) => <String, Object?>{
  'card_id': cardId,
  'game': 'mtg',
  'finish': 'nonfoil',
  'condition': 'near_mint',
  'language': 'en',
  'quantity': quantity,
  'binder': '',
  'for_trade': false,
  'created_at': '2026-09-01T00:00:00.000Z',
  'updated_at': updated,
};

Future<void> putLocal(
  Database db,
  CollectionEntry entry, {
  String game = 'mtg',
}) => db.insert('collection_entries', <String, Object?>{
  ...entry.toRow(),
  'game': game,
});

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase app;
  late Database db;
  late FakeAccount account;
  late CollectionSync sync;

  setUp(() async {
    app = await AppDatabase.openInMemory();
    db = app.db;
    account = FakeAccount();
    sync = CollectionSync(table: account, db: db);
  });

  tearDown(() => db.close());

  test('a device with cards hands them to the account', () async {
    await putLocal(
      db,
      CollectionEntry(
        cardId: 'lotus-1',
        quantity: 4,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 10, 12),
      ),
    );

    expect(await sync.push(CardGame.mtg), 1);
    expect(account.written.single['card_id'], 'lotus-1');
    expect(account.written.single['quantity'], 4);
    // The owner is the account's to fill in, never the client's to claim.
    expect(account.written.single.containsKey('user_id'), isFalse);
  });

  test('a device with nothing sends nothing', () async {
    // Not an empty upsert: a request that can only do nothing is a request
    // worth not making.
    expect(await sync.push(CardGame.mtg), 0);
    expect(account.written, isEmpty);
  });

  test('only the game being synced travels', () async {
    await putLocal(
      db,
      CollectionEntry(
        cardId: 'mtg-card',
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 10),
      ),
    );
    await putLocal(
      db,
      CollectionEntry(
        cardId: 'digimon-card',
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 10),
      ),
      game: 'digimon',
    );

    await sync.push(CardGame.mtg);
    expect(account.written.single['card_id'], 'mtg-card');
  });

  test('a holding the device has never seen arrives', () async {
    account.remote = <Map<String, Object?>>[accountRow(cardId: 'bolt-1')];

    expect(await sync.pull(CardGame.mtg), 1);
    final List<Map<String, Object?>> rows = await db.query(
      'collection_entries',
    );
    expect(rows.single['card_id'], 'bolt-1');
    expect(rows.single['game'], 'mtg');
  });

  test('the later edit wins, wherever it was made', () async {
    await putLocal(
      db,
      CollectionEntry(
        cardId: 'lotus-1',
        quantity: 4,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 10, 12),
      ),
    );
    account.remote = <Map<String, Object?>>[
      accountRow(
        cardId: 'lotus-1',
        quantity: 9,
        updated: '2026-09-10T13:00:00.000Z',
      ),
    ];

    await sync.pull(CardGame.mtg);
    final List<Map<String, Object?>> rows = await db.query(
      'collection_entries',
    );
    expect(rows.single['quantity'], 9);
    // Still one holding, not two: the account's row replaced it.
    expect(rows.length, 1);
  });

  test('an older account copy does not overwrite newer work here', () async {
    // The device was used offline and is holding the newer edit. Pulling the
    // account's stale copy over it is how a sync silently loses a collector's
    // evening.
    await putLocal(
      db,
      CollectionEntry(
        cardId: 'lotus-1',
        quantity: 4,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 11, 12),
      ),
    );
    account.remote = <Map<String, Object?>>[
      accountRow(
        cardId: 'lotus-1',
        quantity: 1,
        updated: '2026-09-10T12:00:00.000Z',
      ),
    ];

    await sync.pull(CardGame.mtg);
    final List<Map<String, Object?>> rows = await db.query(
      'collection_entries',
    );
    expect(rows.single['quantity'], 4);
  });

  test('a row with no card id is skipped rather than invented', () async {
    account.remote = <Map<String, Object?>>[
      <String, Object?>{'quantity': 3},
      accountRow(cardId: 'bolt-1'),
    ];

    await sync.pull(CardGame.mtg);
    final List<Map<String, Object?>> rows = await db.query(
      'collection_entries',
    );
    expect(rows.length, 1);
    expect(rows.single['card_id'], 'bolt-1');
  });

  test(
    'a full sync sends this device\'s work and brings the rest back',
    () async {
      await putLocal(
        db,
        CollectionEntry(
          cardId: 'mine',
          quantity: 2,
          createdAt: DateTime(2026, 9, 1),
          updatedAt: DateTime.utc(2026, 9, 10, 12),
        ),
      );
      account.remote = <Map<String, Object?>>[accountRow(cardId: 'theirs')];

      await sync.sync(CardGame.mtg);

      expect(account.written.single['card_id'], 'mine');
      final List<Map<String, Object?>> rows = await db.query(
        'collection_entries',
      );
      final Set<Object?> ids = rows
          .map((Map<String, Object?> r) => r['card_id'])
          .toSet();
      expect(ids, <Object?>{'mine', 'theirs'});
    },
  );
}
