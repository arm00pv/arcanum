// What happens when two devices edit one deck, and what a collector sees.
//
//   flutter test test/data/deck_sync_test.dart
//
// The case the whole shape of the deck sync exists for: the laptop, offline in a
// hotel, renames a deck while the browser at home adds cards to it. A rule that
// resolves a deck as one row loses one of those two edits, and it loses it
// silently. These tests are the rule: the deck row is resolved per field, the
// contents per line, the later edit wins, a tie goes to the account, and a
// removal is an edit like any other.

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/sync/deck_sync.dart';
import 'package:arcanum/data/sync/deck_table.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real tables do.
///
/// The collision behaviour is the whole reason this is not a list of what it was
/// handed. The real account resolves a push through its keys - the deck's
/// `(user_id, sync_id)` and the line's `(user_id, deck_sync_id, card_id, board)`
/// - and it does not compare timestamps while doing it. A fake that merged more
/// cleverly than that would let a sync pass a test the real one would fail.
class FakeDeckAccount implements DeckTable {
  /// Every write, in the order the account was handed it, so a test can see that
  /// a deck is written before the lines that point at it.
  final List<String> order = <String>[];

  final List<Map<String, Object?>> writtenDecks = <Map<String, Object?>>[];
  final List<Map<String, Object?>> writtenLines = <Map<String, Object?>>[];

  /// What the account holds.
  List<Map<String, Object?>> deckRows = <Map<String, Object?>>[];
  List<Map<String, Object?>> lineRows = <Map<String, Object?>>[];

  @override
  Future<void> upsertDecks(List<Map<String, Object?>> rows) async {
    order.add('decks');
    writtenDecks.addAll(rows);
    for (final Map<String, Object?> row in rows) {
      deckRows = <Map<String, Object?>>[
        for (final Map<String, Object?> held in deckRows)
          if (held['sync_id'] != row['sync_id']) held,
        <String, Object?>{...row},
      ];
    }
  }

  @override
  Future<void> upsertLines(List<Map<String, Object?>> rows) async {
    order.add('lines');
    writtenLines.addAll(rows);
    for (final Map<String, Object?> row in rows) {
      final String key = _lineKey(row);
      lineRows = <Map<String, Object?>>[
        for (final Map<String, Object?> held in lineRows)
          if (_lineKey(held) != key) held,
        <String, Object?>{...row},
      ];
    }
  }

  @override
  Future<List<Map<String, Object?>>> fetchDecks(CardGame game) async =>
      <Map<String, Object?>>[
        for (final Map<String, Object?> row in deckRows)
          if (row['game'] == game.id) row,
      ];

  @override
  Future<List<Map<String, Object?>>> fetchLines(CardGame game) async =>
      <Map<String, Object?>>[
        for (final Map<String, Object?> row in lineRows)
          if (row['game'] == game.id) row,
      ];

  /// The account's row for one deck, or null.
  Map<String, Object?>? deck(String syncId) {
    for (final Map<String, Object?> row in deckRows) {
      if (row['sync_id'] == syncId) return row;
    }
    return null;
  }

  /// The account's row for one line, or null.
  Map<String, Object?>? line(String syncId, String cardId, [String board = 'main']) {
    for (final Map<String, Object?> row in lineRows) {
      if (row['deck_sync_id'] == syncId &&
          row['card_id'] == cardId &&
          row['board'] == board) {
        return row;
      }
    }
    return null;
  }

  /// How many rows the account holds for one line, which is how a revival is
  /// told from a second line.
  int rowsFor(String syncId, String cardId) => lineRows
      .where(
        (Map<String, Object?> r) =>
            r['deck_sync_id'] == syncId && r['card_id'] == cardId,
      )
      .length;

  static String _lineKey(Map<String, Object?> row) => <Object?>[
    row['deck_sync_id'],
    row['card_id'],
    row['board'],
  ].join('|');
}

/// One device: its own database and its own side of the sync.
class Device {
  Device(this.db, this.account) : sync = DeckSync(table: account, db: db.db);

  final AppDatabase db;
  final FakeDeckAccount account;
  final DeckSync sync;

  DeckDao get dao => DeckDao(db.db);

  Future<void> close() => db.close();

  /// The decks this device would show its owner, newest first.
  Future<List<Deck>> decks() => dao.decks(CardGame.mtg);

  /// What this device would show inside one deck: the lines that are in it.
  Future<List<DeckEntry>> entries(int id) => dao.entries(id, CardGame.mtg);

  /// The card ids in one deck, sorted, for a comparison between two devices.
  Future<List<String>> cardsIn(int id) async =>
      (await entries(id)).map((DeckEntry e) => e.cardId).toList()..sort();

  /// The deck's identity on the wire.
  Future<String> syncIdOf(int id) async =>
      (await db.db.query(
            'decks',
            columns: <String>['sync_id'],
            where: 'id = ?',
            whereArgs: <Object?>[id],
          )).first['sync_id']
          as String;

  /// The one deck this device holds, which is the one every test works on.
  Future<int> onlyDeck() async => (await decks()).single.id;
}

/// A device, in a database of its own.
///
/// `own: true` matters here and is not tidiness: sqflite answers a second open
/// of the in-memory path with the same database, so a test that opened two
/// devices the obvious way would be comparing a device with itself - and the
/// headline of this file is two devices editing one deck.
Future<Device> openDevice(FakeDeckAccount account) async =>
    Device(await AppDatabase.openInMemory(own: true), account);

/// Waits a moment, so that an edit made after another edit is stamped after it.
///
/// The clocks are the rule - the later edit wins - so a test that made two edits
/// in the same millisecond would be testing the tie-break instead of the rule it
/// meant to test.
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 5));

/// A deck row as the account sends one.
Map<String, Object?> accountDeck({
  required String syncId,
  String game = 'mtg',
  String name = 'Krenko',
  String formatId = 'commander',
  String? notes,
  String? nameAt,
  String? formatAt,
  String? notesAt,
  String? deleted,
  String created = '2026-09-01T00:00:00.000Z',
  String updated = '2026-09-10T12:00:00.000Z',
}) => <String, Object?>{
  'game': game,
  'sync_id': syncId,
  'name': name,
  'format_id': formatId,
  'notes': notes,
  'name_at': nameAt,
  'format_at': formatAt,
  'notes_at': notesAt,
  'deleted_at': deleted,
  'created_at': created,
  'updated_at': updated,
};

/// A line as the account sends one.
Map<String, Object?> accountLine({
  required String deckSyncId,
  required String cardId,
  String game = 'mtg',
  String board = 'main',
  int quantity = 1,
  int sort = 0,
  String category = '',
  String? deleted,
  String updated = '2026-09-10T12:00:00.000Z',
}) => <String, Object?>{
  'game': game,
  'deck_sync_id': deckSyncId,
  'card_id': cardId,
  'board': board,
  'quantity': quantity,
  'sort': sort,
  'category': category,
  'deleted_at': deleted,
  'updated_at': updated,
};

/// A deck written straight into a device, with the clocks a test wants rather
/// than the clock the machine happens to have.
Future<int> putDeck(
  Database db, {
  required String syncId,
  String name = 'Krenko',
  String formatId = 'commander',
  String? notes,
  int createdAt = 1755000000000,
  int updatedAt = 1755000000000,
  int? nameAt,
  int? formatAt,
  int? notesAt,
  int? deletedAt,
  String game = 'mtg',
}) => db.insert('decks', <String, Object?>{
  'game': game,
  'sync_id': syncId,
  'name': name,
  'format_id': formatId,
  'notes': notes,
  'created_at': createdAt,
  'updated_at': updatedAt,
  'name_at': nameAt,
  'format_at': formatAt,
  'notes_at': notesAt,
  'deleted_at': deletedAt,
});

/// A line written straight into a device, with its own clock.
Future<void> putLine(
  Database db,
  int deckId, {
  required String cardId,
  String board = 'main',
  int quantity = 1,
  int sort = 0,
  int updatedAt = 1755000000000,
  int? deletedAt,
}) => db.insert('deck_cards', <String, Object?>{
  'deck_id': deckId,
  'card_id': cardId,
  'board': board,
  'quantity': quantity,
  'sort': sort,
  'category': '',
  'updated_at': updatedAt,
  'deleted_at': deletedAt,
});

/// A moment in the account's own spelling, so a test can say exactly when
/// something was edited.
String at(int millis) =>
    DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toIso8601String();

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late FakeDeckAccount account;

  setUp(() => account = FakeDeckAccount());

  group('a device with decks hands them to the account', () {
    test('the deck and its cards travel, and the owner does not', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain', quantity: 4);

      expect(await one.sync.push(CardGame.mtg), 2, reason: 'one deck, one line');
      expect(account.writtenDecks.single['name'], 'Krenko');
      expect(account.writtenDecks.single['format_id'], 'commander');
      expect(account.writtenDecks.single['sync_id'], await one.syncIdOf(id));
      expect(account.writtenDecks.single.containsKey('user_id'), isFalse);
      expect(account.writtenLines.single['card_id'], 'goblin-chieftain');
      expect(account.writtenLines.single['quantity'], 4);
      expect(account.writtenLines.single.containsKey('user_id'), isFalse);
    });

    test('the deck is written before the lines that point at it', () async {
      // The account's foreign key from a line to its deck refuses a line whose
      // deck is not there, so the order is not a preference.
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain');

      await one.sync.push(CardGame.mtg);

      expect(account.order, <String>['decks', 'lines']);
    });

    test('a device with no decks sends nothing', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);

      expect(await one.sync.push(CardGame.mtg), 0);
      expect(account.writtenDecks, isEmpty);
      expect(account.writtenLines, isEmpty);
    });

    test('only the game being synced travels', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'A',
        formatId: 'modern',
      );
      await one.dao.createDeck(
        game: CardGame.lorcana,
        name: 'B',
        formatId: 'lorcana-core',
      );

      await one.sync.push(CardGame.mtg);

      expect(account.writtenDecks.single['name'], 'A');
    });

    test('every push names the marks, even when there is nothing to say', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain');

      await one.sync.push(CardGame.mtg);

      expect(account.writtenDecks.single.containsKey('deleted_at'), isTrue);
      expect(account.writtenDecks.single['deleted_at'], isNull);
      expect(account.writtenLines.single.containsKey('deleted_at'), isTrue);
      expect(account.writtenLines.single['deleted_at'], isNull);
    });
  });

  group('a deck the device has never seen', () {
    test('arrives with its cards', () async {
      account.deckRows = <Map<String, Object?>>[
        accountDeck(syncId: 'theirs', name: 'Mono-Red'),
      ];
      account.lineRows = <Map<String, Object?>>[
        accountLine(deckSyncId: 'theirs', cardId: 'lightning-bolt', quantity: 4),
      ];
      final Device one = await openDevice(account);
      addTearDown(one.close);

      expect(await one.sync.pull(CardGame.mtg), 2);

      final Deck deck = (await one.decks()).single;
      expect(deck.name, 'Mono-Red');
      expect(deck.formatId, 'commander');
      expect(deck.cardCount, 4);
      expect(await one.cardsIn(deck.id), <String>['lightning-bolt']);
    });

    test('lands under the identity it came with, not a new one', () async {
      // Two devices must agree about which deck is which before either has seen
      // the other's, or the second pull would make a second deck of it.
      account.deckRows = <Map<String, Object?>>[accountDeck(syncId: 'theirs')];
      final Device one = await openDevice(account);
      addTearDown(one.close);

      await one.sync.pull(CardGame.mtg);
      await one.sync.pull(CardGame.mtg);

      expect(await one.decks(), hasLength(1));
      expect(await one.syncIdOf(await one.onlyDeck()), 'theirs');
    });

    test('a duplicated name is two decks and nothing is merged', () async {
      // Two browsers, both offline, both create a deck called "Mono-Red". Each
      // mints its own identity at the moment of creation, so they are two decks
      // and the account holds two rows. Nothing is guessed and nothing is lost.
      account.deckRows = <Map<String, Object?>>[
        accountDeck(syncId: 'first', name: 'Mono-Red'),
        accountDeck(syncId: 'second', name: 'Mono-Red'),
      ];
      final Device one = await openDevice(account);
      addTearDown(one.close);

      await one.sync.pull(CardGame.mtg);

      expect(await one.decks(), hasLength(2));
    });

    test('a row with no identity is skipped rather than invented', () async {
      account.deckRows = <Map<String, Object?>>[
        <String, Object?>{'name': 'nothing', 'game': 'mtg'},
        accountDeck(syncId: 'theirs'),
      ];
      final Device one = await openDevice(account);
      addTearDown(one.close);

      await one.sync.pull(CardGame.mtg);

      expect(await one.decks(), hasLength(1));
      expect((await one.decks()).single.name, 'Krenko');
    });
  });

  group('two copies of one deck', () {
    test('the later edit wins per field', () async {
      // One clock for the row would make these two edits one, and the losing one
      // would be gone without a word. Three clocks keep them apart.
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(
        one.db.db,
        syncId: 'mine',
        name: 'Mine',
        formatId: 'modern',
        nameAt: 2000,
        formatAt: 1000,
        updatedAt: 2000,
      );

      await one.sync.mergeDeck(CardGame.mtg, <String, Object?>{
        ...accountDeck(
          syncId: 'mine',
          name: 'Theirs',
          formatId: 'commander',
          notes: 'goblins',
          nameAt: at(1000),
          formatAt: at(3000),
          notesAt: at(3000),
        ),
      });

      final Map<String, Object?> row =
          (await one.db.db.query('decks', where: 'id = ?', whereArgs: <Object?>[id]))
              .single;
      expect(row['name'], 'Mine', reason: 'the rename here is the newer edit');
      expect(row['name_at'], 2000);
      expect(
        row['format_id'],
        'commander',
        reason: 'the format was edited later on the other device',
      );
      expect(row['format_at'], 3000);
      expect(row['notes'], 'goblins');
    });

    test('a field never edited here loses to one that was', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(one.db.db, syncId: 'mine', name: 'Old name');

      await one.sync.mergeDeck(
        CardGame.mtg,
        accountDeck(syncId: 'mine', name: 'New name', nameAt: at(2000)),
      );

      final Map<String, Object?> row =
          (await one.db.db.query('decks', where: 'id = ?', whereArgs: <Object?>[id]))
              .single;
      expect(row['name'], 'New name');
      expect(row['name_at'], 2000);
    });

    test('a tie goes to the account', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(
        one.db.db,
        syncId: 'mine',
        name: 'Mine',
        nameAt: 2000,
      );

      await one.sync.mergeDeck(
        CardGame.mtg,
        accountDeck(syncId: 'mine', name: 'Theirs', nameAt: at(2000)),
      );

      expect(
        (await one.db.db.query('decks', where: 'id = ?', whereArgs: <Object?>[id]))
            .single['name'],
        'Theirs',
      );
    });

    test('an older account copy does not overwrite newer work here', () async {
      // The device was used offline and is holding the newer edit. Pulling the
      // account's stale copy over it is how a sync silently loses a collector's
      // evening.
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(
        one.db.db,
        syncId: 'mine',
        name: 'Krenko (v2)',
        nameAt: 9000,
        updatedAt: 9000,
      );
      account.deckRows = <Map<String, Object?>>[
        accountDeck(syncId: 'mine', name: 'Krenko', nameAt: at(1000), updated: at(1000)),
      ];

      await one.sync.pull(CardGame.mtg);

      final Map<String, Object?> row =
          (await one.db.db.query('decks', where: 'id = ?', whereArgs: <Object?>[id]))
              .single;
      expect(row['name'], 'Krenko (v2)');
      expect(row['updated_at'], 9000);
    });
  });

  group('the contents of one deck', () {
    test('are resolved one line at a time', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(one.db.db, syncId: 'mine', updatedAt: 1000);
      await putLine(one.db.db, id, cardId: 'chieftain', quantity: 4, updatedAt: 5000);
      await putLine(one.db.db, id, cardId: 'sol-ring', quantity: 1, updatedAt: 1000);

      account.lineRows = <Map<String, Object?>>[
        accountLine(
          deckSyncId: 'mine',
          cardId: 'chieftain',
          quantity: 9,
          updated: at(4000),
        ),
        accountLine(
          deckSyncId: 'mine',
          cardId: 'sol-ring',
          quantity: 2,
          updated: at(6000),
        ),
        accountLine(deckSyncId: 'mine', cardId: 'prospector', quantity: 2),
      ];

      await one.sync.pull(CardGame.mtg);

      final List<DeckEntry> lines = await one.entries(id);
      expect(
        lines.map((DeckEntry e) => '${e.cardId}:${e.quantity}').toList()..sort(),
        <String>['chieftain:4', 'prospector:2', 'sol-ring:2'],
        reason: 'each line against its own clock, not against the deck',
      );
    });

    test('a line the deck has never held arrives', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      await putDeck(one.db.db, syncId: 'mine');

      expect(
        await one.sync.mergeLine(
          CardGame.mtg,
          accountLine(deckSyncId: 'mine', cardId: 'bolt', board: 'side', quantity: 3),
        ),
        isTrue,
      );

      final DeckEntry line = (await one.entries(await one.onlyDeck())).single;
      expect(line.cardId, 'bolt');
      expect(line.board, DeckBoard.side);
      expect(line.quantity, 3);
    });

    test('a line whose deck is not here is not a line', () async {
      // Nothing to be part of, and a local row pointing at nothing has nowhere
      // to be shown. Decks are pulled before their lines, so this is a row for a
      // deck the account has not offered.
      final Device one = await openDevice(account);
      addTearDown(one.close);

      expect(
        await one.sync.mergeLine(
          CardGame.mtg,
          accountLine(deckSyncId: 'nowhere', cardId: 'bolt'),
        ),
        isFalse,
      );
      expect(await one.db.db.query('deck_cards'), isEmpty);
    });
  });

  group('two devices, one deck, offline', () {
    /// The design's own case, walked through: the laptop renames a deck to
    /// "Krenko (v2)" and adds four Goblin Chieftains, the browser at home adds
    /// two Skirk Prospectors and removes a Mogg War Marshal, and both come back
    /// online. One deck, named "Krenko (v2)", holding four Chieftains, two
    /// Prospectors, and no War Marshal - whichever order they sync in.
    ///
    /// The devices sync twice each, and that is not a workaround: a device that
    /// pushed before the other one pulled cannot have heard what the other one
    /// did, and hears it on its next pull. The account's copy is repaired the
    /// same way, which the design states as the accepted residue of a sync whose
    /// push is an upsert (docs/deck-sync.md section 3.5).
    Future<void> renameHereAddCardsThere(List<String> order) async {
      final Device laptop = await openDevice(account);
      final Device home = await openDevice(account);
      addTearDown(laptop.close);
      addTearDown(home.close);

      // The deck as both devices already have it: one they have both synced.
      final int id = await laptop.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await laptop.dao.addCard(id, 'mogg-war-marshal');
      await laptop.sync.sync(CardGame.mtg);
      await home.sync.sync(CardGame.mtg);
      final int homeId = await home.onlyDeck();
      expect(await home.cardsIn(homeId), <String>['mogg-war-marshal']);

      // The evening, both offline.
      await tick();
      await laptop.dao.updateDeck(id, name: 'Krenko (v2)');
      await laptop.dao.addCard(id, 'goblin-chieftain', quantity: 4);
      await tick();
      await home.dao.addCard(homeId, 'skirk-prospector', quantity: 2);
      await home.dao.removeCard(homeId, 'mogg-war-marshal', DeckBoard.main);

      // Both come back online, in the order the test is named for.
      for (final String device in <String>[...order, ...order]) {
        if (device == 'laptop') {
          await laptop.sync.sync(CardGame.mtg);
        } else {
          await home.sync.sync(CardGame.mtg);
        }
      }

      for (final Device device in <Device>[laptop, home]) {
        final List<Deck> decks = await device.decks();
        expect(decks, hasLength(1), reason: 'one deck, not two');
        expect(
          decks.single.name,
          'Krenko (v2)',
          reason: 'the rename survived the afternoon of adding cards',
        );
        expect(decks.single.formatId, 'commander');
        expect(decks.single.cardCount, 6);
        expect(
          await device.cardsIn(decks.single.id),
          <String>['goblin-chieftain', 'skirk-prospector'],
          reason: 'both devices kept what they did, and the removal stuck',
        );
      }

      final String syncId = await laptop.syncIdOf(await laptop.onlyDeck());
      expect(account.deck(syncId)!['name'], 'Krenko (v2)');
      expect(account.line(syncId, 'goblin-chieftain')!['quantity'], 4);
      expect(account.line(syncId, 'skirk-prospector')!['quantity'], 2);
      expect(
        account.line(syncId, 'mogg-war-marshal')!['deleted_at'],
        isNotNull,
        reason: 'a removal is a mark on the row, not an absence',
      );
    }

    test('both keep what they did, whichever syncs first', () async {
      await renameHereAddCardsThere(<String>['laptop', 'home']);
    });

    test('and the same the other way round', () async {
      await renameHereAddCardsThere(<String>['home', 'laptop']);
    });
  });

  group('a card that was removed', () {
    /// Two devices sharing one deck, through the account.
    late Device one;
    late Device two;

    setUp(() async {
      one = await openDevice(account);
      two = await openDevice(account);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'mogg-war-marshal', quantity: 1);
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);
    });

    tearDown(() async {
      await one.close();
      await two.close();
    });

    test('is a mark on the account, not an absence', () async {
      final String syncId = await one.syncIdOf(await one.onlyDeck());
      expect(account.line(syncId, 'mogg-war-marshal')!['deleted_at'], isNull);

      await one.dao.removeCard(await one.onlyDeck(), 'mogg-war-marshal', DeckBoard.main);
      await one.sync.push(CardGame.mtg);

      expect(account.line(syncId, 'mogg-war-marshal')!['deleted_at'], isNotNull);
      expect(
        account.rowsFor(syncId, 'mogg-war-marshal'),
        1,
        reason: 'the row keeps its place, or the next pull hands the card back',
      );
    });

    test('stays removed on the other device, which never heard the edit', () async {
      // The headline. The second device is not party to the removal and is
      // holding its own copy of the line, an older one. If the sync pushed before
      // it pulled, that stale copy would arrive at the account and clear the mark
      // on the way through.
      await one.dao.removeCard(await one.onlyDeck(), 'mogg-war-marshal', DeckBoard.main);
      await one.sync.sync(CardGame.mtg);

      await two.sync.sync(CardGame.mtg);

      expect(await two.cardsIn(await two.onlyDeck()), isEmpty);
      expect(await one.cardsIn(await one.onlyDeck()), isEmpty);
      final String syncId = await two.syncIdOf(await two.onlyDeck());
      expect(account.line(syncId, 'mogg-war-marshal')!['deleted_at'], isNotNull);
      expect(account.rowsFor(syncId, 'mogg-war-marshal'), 1);
    });

    test('comes back in place with the new count when it is added again', () async {
      // Not a sum. The collector removed four Chieftains and then added one, so
      // they own one - the row is revived where it is, with what they just asked
      // for, and the unique key is what makes that one row rather than two.
      final int id = await one.onlyDeck();
      await one.dao.addCard(id, 'goblin-chieftain', quantity: 4);
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);

      await one.dao.removeCard(id, 'goblin-chieftain', DeckBoard.main);
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);
      expect(await two.cardsIn(await two.onlyDeck()), isNot(contains('goblin-chieftain')));

      await one.dao.addCard(id, 'goblin-chieftain');
      await one.sync.sync(CardGame.mtg);

      final DeckEntry back = (await one.entries(id)).firstWhere(
        (DeckEntry e) => e.cardId == 'goblin-chieftain',
      );
      expect(back.quantity, 1, reason: 'the new count, not four plus one');
      expect(
        (await one.db.db.query(
          'deck_cards',
          where: 'card_id = ?',
          whereArgs: <Object?>['goblin-chieftain'],
        )).length,
        1,
        reason: 'revived in place rather than inserted beside the mark',
      );

      await two.sync.sync(CardGame.mtg);
      final DeckEntry there = (await two.entries(await two.onlyDeck())).firstWhere(
        (DeckEntry e) => e.cardId == 'goblin-chieftain',
      );
      expect(there.quantity, 1);
      final String syncId = await two.syncIdOf(await two.onlyDeck());
      expect(account.rowsFor(syncId, 'goblin-chieftain'), 1);
      expect(account.line(syncId, 'goblin-chieftain')!['deleted_at'], isNull);
    });

    test('a card added back on the other device revives it there too', () async {
      await one.dao.removeCard(await one.onlyDeck(), 'mogg-war-marshal', DeckBoard.main);
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);

      final int twoId = await two.onlyDeck();
      await two.dao.addCard(twoId, 'mogg-war-marshal', quantity: 2);
      await two.sync.sync(CardGame.mtg);
      await one.sync.sync(CardGame.mtg);

      final DeckEntry back = (await one.entries(await one.onlyDeck())).single;
      expect(back.cardId, 'mogg-war-marshal');
      expect(back.quantity, 2);
    });
  });

  group('a deck that was deleted', () {
    late Device one;
    late Device two;

    setUp(() async {
      one = await openDevice(account);
      two = await openDevice(account);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain', quantity: 4);
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);
    });

    tearDown(() async {
      await one.close();
      await two.close();
    });

    test('is a mark on the deck, and its lines are left alone', () async {
      // The lines are what makes a revival whole. A cascade here would hand the
      // collector a one-card deck with the same name.
      final int id = await one.onlyDeck();
      await one.dao.deleteDeck(id);

      expect(await one.decks(), isEmpty, reason: 'gone from the list');
      expect(
        (await one.db.db.query(
          'deck_cards',
          where: 'deck_id = ?',
          whereArgs: <Object?>[id],
        )).length,
        1,
        reason: 'the lines are still there, unmarked',
      );

      await one.sync.push(CardGame.mtg);

      final String syncId = await one.syncIdOf(id);
      expect(account.deck(syncId)!['deleted_at'], isNotNull);
      expect(account.line(syncId, 'goblin-chieftain')!['deleted_at'], isNull);
    });

    test('disappears from the other device after a sync', () async {
      await one.dao.deleteDeck(await one.onlyDeck());
      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);

      expect(await two.decks(), isEmpty);
      expect(
        await two.dao.cardIdsInDecks(CardGame.mtg),
        isEmpty,
        reason: 'a card screen must not name a deck the collector deleted',
      );
      expect(await two.dao.decksHolding(CardGame.mtg, 'goblin-chieftain'), 0);
      expect(await two.dao.decksContaining(CardGame.mtg, 'goblin-chieftain'), isEmpty);
    });

    test('is revived whole by a newer edit on a device that never heard', () async {
      // A deletion is an edit made at a moment, so it beats an older edit and
      // loses to a newer one - and adding a card to the deck is a newer edit.
      final int id = await one.onlyDeck();
      await one.dao.deleteDeck(id);
      await one.sync.sync(CardGame.mtg);
      expect(account.deck(await one.syncIdOf(id))!['deleted_at'], isNotNull);

      await tick();
      final int twoId = await two.onlyDeck();
      await two.dao.addCard(twoId, 'skirk-prospector', quantity: 2);
      await two.sync.sync(CardGame.mtg);
      await one.sync.sync(CardGame.mtg);

      for (final Device device in <Device>[one, two]) {
        final Deck deck = (await device.decks()).single;
        expect(deck.name, 'Krenko');
        expect(
          await device.cardsIn(deck.id),
          <String>['goblin-chieftain', 'skirk-prospector'],
          reason: 'revived with everything that was in it, and the new card',
        );
      }
      expect(account.deck(await one.syncIdOf(id))!['deleted_at'], isNull);
    });

    test('a deck whose lines are all gone is still a deck', () async {
      final int id = await one.onlyDeck();
      await one.dao.clearDeck(id);

      expect((await one.decks()).single.cardCount, 0);
      expect(await one.entries(id), isEmpty);
      expect(
        (await one.db.db.query(
          'deck_cards',
          where: 'deck_id = ?',
          whereArgs: <Object?>[id],
        )).length,
        1,
        reason: 'the line is marked, not dropped',
      );

      await one.sync.sync(CardGame.mtg);
      await two.sync.sync(CardGame.mtg);

      for (final Device device in <Device>[one, two]) {
        final List<Deck> decks = await device.decks();
        expect(decks, hasLength(1));
        expect(decks.single.name, 'Krenko');
        expect(decks.single.cardCount, 0);
        expect(await device.entries(decks.single.id), isEmpty);
      }
      final String syncId = await one.syncIdOf(id);
      expect(account.deck(syncId)!['deleted_at'], isNull);
      expect(account.line(syncId, 'goblin-chieftain')!['deleted_at'], isNotNull);
    });
  });

  group('what this device has already carried up', () {
    test('a device that has just pushed has nothing left to carry', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain');
      await one.sync.sync(CardGame.mtg);

      expect(await one.sync.ahead(), isEmpty);
      account.writtenDecks.clear();
      account.writtenLines.clear();
      expect(await one.sync.pushAhead(CardGame.mtg), 0);
      expect(account.writtenDecks, isEmpty);
      expect(account.writtenLines, isEmpty);
    });

    test('only what has changed since the last push travels', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int first = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      final int second = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Mono-Red',
        formatId: 'modern',
      );
      await one.dao.addCard(first, 'goblin-chieftain');
      await one.dao.addCard(second, 'lightning-bolt');
      await one.sync.sync(CardGame.mtg);
      account.writtenDecks.clear();
      account.writtenLines.clear();

      await one.dao.addCard(second, 'monastery-swiftspear');

      expect(await one.sync.ahead(), <CardGame>[CardGame.mtg]);
      expect(await one.sync.pushAhead(CardGame.mtg), 2, reason: 'the deck and its new line');
      expect(
        account.writtenLines.single['card_id'],
        'monastery-swiftspear',
        reason: 'the lines nobody touched were not sent',
      );
      expect(account.writtenDecks.single['name'], 'Mono-Red');
      expect(await one.sync.ahead(), isEmpty);
    });

    test('a removal made since the last push travels as the removal', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain');
      await one.sync.sync(CardGame.mtg);
      account.writtenLines.clear();

      await one.dao.removeCard(id, 'goblin-chieftain', DeckBoard.main);

      expect(await one.sync.pushAhead(CardGame.mtg), 2);
      expect(account.writtenLines.single['deleted_at'], isNotNull);
    });
  });

  group('a full sync', () {
    test('sends this device work and brings the rest back', () async {
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await one.dao.createDeck(
        game: CardGame.mtg,
        name: 'Mine',
        formatId: 'commander',
      );
      await one.dao.addCard(id, 'goblin-chieftain');
      account.deckRows = <Map<String, Object?>>[
        accountDeck(syncId: 'theirs', name: 'Theirs'),
      ];
      account.lineRows = <Map<String, Object?>>[
        accountLine(deckSyncId: 'theirs', cardId: 'lightning-bolt'),
      ];

      await one.sync.sync(CardGame.mtg);

      expect(
        (await one.decks()).map((Deck d) => d.name).toSet(),
        <String>{'Mine', 'Theirs'},
        reason: 'the account deck arrived and this device one stayed',
      );
      expect(
        account.writtenDecks.map((Map<String, Object?> r) => r['name']).toSet(),
        <String>{'Mine', 'Theirs'},
        reason: 'the account copy travels back up, as the collection does',
      );
    });

    test('a deck from an archive written before v16 gets an identity', () async {
      // A restore copies whole rows, and an archive from before this version has
      // no sync_id in it. The account refuses a deck without one rather than
      // minting a fresh identity per push, which would be one duplicate per
      // attempt, so the identity is minted here before the deck travels.
      final Device one = await openDevice(account);
      addTearDown(one.close);
      final int id = await putDeck(one.db.db, syncId: 'placeholder');
      await one.db.db.update(
        'decks',
        <String, Object?>{'sync_id': null},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );

      await one.sync.push(CardGame.mtg);

      final String minted = await one.syncIdOf(id);
      expect(minted, isNotEmpty);
      expect(account.writtenDecks.single['sync_id'], minted);
      expect(account.deck(minted), isNotNull);
    });
  });
}
