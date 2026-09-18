import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real table does.
///
/// The collision behaviour is the whole reason this is not a list of what it
/// was handed. The real table resolves a push through its unique index -
/// whichever row arrives last is the row that is there - and it does not
/// compare timestamps while doing it. A fake that merged more cleverly than
/// that would let a sync pass a test the real one would fail: a device pushing
/// a stale copy of a card somebody else deleted would look harmless.
class FakeAccount implements AccountTable {
  final List<Map<String, Object?>> written = <Map<String, Object?>>[];
  List<Map<String, Object?>> remote = <Map<String, Object?>>[];

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {
    written.addAll(rows);
    for (final Map<String, Object?> row in rows) {
      final String key = _key(row);
      remote = <Map<String, Object?>>[
        for (final Map<String, Object?> held in remote)
          if (_key(held) != key) held,
        <String, Object?>{...row},
      ];
    }
  }

  @override
  Future<List<Map<String, Object?>>> fetch(CardGame game) async =>
      <Map<String, Object?>>[
        for (final Map<String, Object?> row in remote)
          if (row['game'] == game.id) row,
      ];

  /// Whether the account holds this card as something its owner has.
  bool live(String cardId) => remote.any(
    (Map<String, Object?> r) =>
        r['card_id'] == cardId && r['deleted_at'] == null,
  );

  /// Whether the account holds the card as removed.
  bool tombstoned(String cardId) => remote.any(
    (Map<String, Object?> r) =>
        r['card_id'] == cardId && r['deleted_at'] != null,
  );

  /// How many rows the account holds for one card.
  int rowsFor(String cardId) =>
      remote.where((Map<String, Object?> r) => r['card_id'] == cardId).length;

  /// The account's unique index, as AccountCollection.conflictTarget names it.
  static String _key(Map<String, Object?> row) => <Object?>[
    row['card_id'],
    row['finish'],
    row['condition'],
    row['language'],
    row['binder'],
  ].join('|');
}

Map<String, Object?> accountRow({
  required String cardId,
  int quantity = 1,
  String updated = '2026-09-10T12:00:00.000Z',
  String? deleted,
}) => <String, Object?>{
  'card_id': cardId,
  'game': 'mtg',
  'finish': 'nonfoil',
  'condition': 'near_mint',
  'language': 'en',
  'quantity': quantity,
  'binder': '',
  'for_trade': false,
  'deleted_at': deleted,
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

/// A holding this device has been carrying for a while.
///
/// Dated minutes ago rather than at a fixed moment, because removing a card
/// stamps it with the clock and a deletion has to be the later edit for any of
/// this to mean anything.
CollectionEntry held(String cardId, {int quantity = 1}) => CollectionEntry(
  cardId: cardId,
  quantity: quantity,
  createdAt: DateTime.now().subtract(const Duration(hours: 1)),
  updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
);

Future<int> idOf(Database db, String cardId) async =>
    (await db.query(
          'collection_entries',
          columns: <String>['id'],
          where: 'card_id = ?',
          whereArgs: <Object?>[cardId],
        )).first['id']
        as int;

/// Everything this device would show its owner, in the order it would show it.
Future<Set<Object?>> owned(Database db) async => <Object?>{
  for (final CollectionEntry e in await CollectionDao(db).all(CardGame.mtg))
    e.cardId,
};

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

  test('every push names deleted_at, even when there is nothing to say', () async {
    // The account takes an upsert as an insert ... on conflict do update of the
    // columns the payload names. A key left out of the payload therefore means
    // "leave what is there", and what is there for a card being added back after
    // a removal is the tombstone that would keep it removed for good.
    await putLocal(db, held('lotus-1'));

    await sync.push(CardGame.mtg);

    expect(account.written.single.containsKey('deleted_at'), isTrue);
    expect(account.written.single['deleted_at'], isNull);
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

  test('a full sync sends this device\'s work and brings the rest back', () async {
    await putLocal(db, held('mine'));
    account.remote = <Map<String, Object?>>[accountRow(cardId: 'theirs')];

    await sync.sync(CardGame.mtg);

    // The account's copy is merged in first and therefore travels back up with
    // this device's own work. It is one request either way, and the row it
    // writes is the row that is already there.
    expect(
      account.written.map((Map<String, Object?> r) => r['card_id']).toSet(),
      <Object?>{'mine', 'theirs'},
    );
    expect(await owned(db), <Object?>{'mine', 'theirs'});
  });

  group('a card that was removed', () {
    /// The collector's second device, sharing the one account.
    late AppDatabase other;
    late Database theirs;
    late CollectionSync theirSync;

    setUp(() async {
      other = await AppDatabase.openInMemory();
      theirs = other.db;
      theirSync = CollectionSync(table: account, db: theirs);
    });

    tearDown(() => theirs.close());

    /// Puts one card on both devices, through the account, the way two phones
    /// that have both synced get to a shared collection.
    Future<void> share(String cardId) async {
      await putLocal(db, held(cardId));
      await sync.sync(CardGame.mtg);
      await theirSync.sync(CardGame.mtg);
    }

    test('is a tombstone on the account, not an absence', () async {
      await share('lotus-1');
      expect(account.live('lotus-1'), isTrue);

      await CollectionDao(db).delete(await idOf(db, 'lotus-1'));
      await sync.push(CardGame.mtg);

      expect(account.live('lotus-1'), isFalse);
      expect(account.tombstoned('lotus-1'), isTrue);
      // The row keeps its place. A row that simply vanished would be a row the
      // account still holds, and the next pull would hand the card back.
      expect(account.rowsFor('lotus-1'), 1);
      expect(account.written.last['deleted_at'], isNotNull);
    });

    test('stays removed on the other device, which never heard the edit', () async {
      // The headline. The second device is not party to the deletion and is
      // holding its own copy of the card, an older one. If the sync pushed
      // before it pulled, that stale copy would arrive at the account and clear
      // the tombstone on the way through.
      await share('lotus-1');
      await CollectionDao(db).delete(await idOf(db, 'lotus-1'));
      await sync.sync(CardGame.mtg);

      await theirSync.sync(CardGame.mtg);

      expect(await owned(theirs), isEmpty);
      expect(await owned(db), isEmpty);
      expect(account.tombstoned('lotus-1'), isTrue);
      expect(account.live('lotus-1'), isFalse);
      expect(account.rowsFor('lotus-1'), 1);
      // And the removal is still visible to the sync as a holding, which is how
      // the second device heard about it at all.
      expect(await theirSync.pull(CardGame.mtg), 1);
    });

    test(
      'comes back once when it is added again on the other device',
      () async {
        await share('lotus-1');
        await CollectionDao(db).delete(await idOf(db, 'lotus-1'));
        await sync.sync(CardGame.mtg);
        await theirSync.sync(CardGame.mtg);

        await CollectionDao(theirs).addOrMerge(
          game: CardGame.mtg,
          cardId: 'lotus-1',
          finish: CardFinish.nonfoil,
          condition: CardCondition.nearMint,
          language: 'en',
          quantity: 2,
        );
        await theirSync.sync(CardGame.mtg);

        expect(account.live('lotus-1'), isTrue);
        expect(
          account.rowsFor('lotus-1'),
          1,
          reason:
              'the account already had the row; this is that row coming back',
        );

        await sync.sync(CardGame.mtg);

        final List<CollectionEntry> back = await CollectionDao(db)
            .all(CardGame.mtg);
        expect(back.single.cardId, 'lotus-1');
        expect(back.single.quantity, 2);
        expect(back.single.isDeleted, isFalse);
        expect(
          (await db.query('collection_entries')).length,
          1,
          reason: 'revived in place, not inserted beside the tombstone',
        );
        expect((await theirs.query('collection_entries')).length, 1);
      },
    );

    test('is not offered as owned while it is removed', () async {
      await share('lotus-1');
      await CollectionDao(db).delete(await idOf(db, 'lotus-1'));
      await sync.sync(CardGame.mtg);

      final CollectionDao dao = CollectionDao(db);
      expect(await dao.all(CardGame.mtg), isEmpty);
      expect(await dao.forCard(CardGame.mtg, 'lotus-1'), isEmpty);
      expect(await dao.ownedCardIds(CardGame.mtg), isEmpty);
      expect(await dao.totalCardCount(CardGame.mtg), 0);
      expect(await dao.uniqueCount(CardGame.mtg), 0);
      // The row is still in the table: that is what carries the removal.
      expect(await db.query('collection_entries'), hasLength(1));
    });
  });

  group('what this device has already carried up', () {
    test('a device that has just pushed has nothing left to carry', () async {
      await putLocal(db, held('lotus-1'));
      await sync.sync(CardGame.mtg);

      expect(await sync.ahead(), isEmpty);
      // And nothing is asked of the account again. A watch that pushed the
      // whole game every time it looked would be a request per ten seconds
      // that nobody's collection ever asked for.
      account.written.clear();
      expect(await sync.pushAhead(CardGame.mtg), 0);
      expect(account.written, isEmpty);
    });

    test('only what has changed since the last push travels', () async {
      await putLocal(db, held('lotus-1'));
      await putLocal(db, held('bolt-1'));
      await sync.sync(CardGame.mtg);
      account.written.clear();

      await CollectionDao(db).addOrMerge(
        game: CardGame.mtg,
        cardId: 'bolt-2',
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 1,
      );

      expect(await sync.ahead(), <CardGame>[CardGame.mtg]);
      expect(await sync.pushAhead(CardGame.mtg), 1);
      expect(account.written.single['card_id'], 'bolt-2');
      // The two cards nobody touched were not sent, and that is the point of
      // sending only the changes: a push carrying a row this device has no news
      // about is a push that can clear a removal made on another browser.
      expect(account.written.single['quantity'], 1);
      expect(await sync.ahead(), isEmpty);
    });

    test('a removal made since the last push travels as the removal', () async {
      await putLocal(db, held('lotus-1'));
      await sync.sync(CardGame.mtg);
      account.written.clear();

      await CollectionDao(db).delete(await idOf(db, 'lotus-1'));

      expect(await sync.pushAhead(CardGame.mtg), 1);
      expect(account.written.single['deleted_at'], isNotNull);
      expect(account.tombstoned('lotus-1'), isTrue);
    });
  });
}
