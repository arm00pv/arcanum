// What a browser carries up about its decks after it has signed in.
//
//   flutter test test/features/deck_watcher_test.dart
//
// The deck half of the report the collection watcher was written for: a deck
// built or edited in one browser reached that browser's database and no further,
// so signing in on a second browser showed the decks as they had been at the
// first one's last sign-in. These tests are about the carrying: that it happens
// by itself while the browser is open, that a minute of working on a deck is not
// a request per card, that the edit made a moment before the tab goes away still
// travels, and that a change made here cannot undo a removal made somewhere else.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/sync/deck_sync.dart';
import 'package:arcanum/data/sync/deck_table.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/auth/deck_watcher.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real tables do.
///
/// The collision behaviour is not incidental to these tests. Every push here is
/// blind - an upsert that never asks what is already there - and a fake that
/// merged more cleverly than the real account would let a careless push look
/// harmless in a test the real one would fail.
class _Account implements DeckTable {
  /// One entry per write, so a test can weigh a minute of editing against the
  /// requests it caused.
  final List<List<Map<String, Object?>>> pushes = <List<Map<String, Object?>>>[];

  final List<Map<String, Object?>> writtenLines = <Map<String, Object?>>[];

  List<Map<String, Object?>> deckRows = <Map<String, Object?>>[];
  List<Map<String, Object?>> lineRows = <Map<String, Object?>>[];

  /// A connection that is down, which is the shape of every way a carry-up
  /// fails without anybody being told about it.
  bool unreachable = false;

  @override
  Future<void> upsertDecks(List<Map<String, Object?>> rows) async {
    if (unreachable) throw Exception('the account did not answer');
    pushes.add(List<Map<String, Object?>>.of(rows));
    for (final Map<String, Object?> row in rows) {
      final String key = row['sync_id']! as String;
      deckRows = <Map<String, Object?>>[
        for (final Map<String, Object?> held in deckRows)
          if (held['sync_id'] != key) held,
        <String, Object?>{...row},
      ];
    }
  }

  @override
  Future<void> upsertLines(List<Map<String, Object?>> rows) async {
    if (unreachable) throw Exception('the account did not answer');
    writtenLines.addAll(rows);
    for (final Map<String, Object?> row in rows) {
      final String key = <Object?>[
        row['deck_sync_id'],
        row['card_id'],
        row['board'],
      ].join('|');
      lineRows = <Map<String, Object?>>[
        for (final Map<String, Object?> held in lineRows)
          if (<Object?>[
                held['deck_sync_id'],
                held['card_id'],
                held['board'],
              ].join('|') !=
              key)
            held,
        <String, Object?>{...row},
      ];
    }
  }

  @override
  Future<List<Map<String, Object?>>> fetchDecks(CardGame game) async {
    if (unreachable) throw Exception('the account did not answer');
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in deckRows)
        if (row['game'] == game.id) row,
    ];
  }

  @override
  Future<List<Map<String, Object?>>> fetchLines(CardGame game) async {
    if (unreachable) throw Exception('the account did not answer');
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in lineRows)
        if (row['game'] == game.id) row,
    ];
  }

  /// Whether the account holds this deck as something its owner has.
  bool live(String syncId) => deckRows.any(
    (Map<String, Object?> row) =>
        row['sync_id'] == syncId && row['deleted_at'] == null,
  );

  /// Whether the account holds the deck as deleted.
  bool tombstoned(String syncId) => deckRows.any(
    (Map<String, Object?> row) =>
        row['sync_id'] == syncId && row['deleted_at'] != null,
  );

  /// Whether the account holds this line as one the deck contains.
  bool holds(String syncId, String cardId) => lineRows.any(
    (Map<String, Object?> row) =>
        row['deck_sync_id'] == syncId &&
        row['card_id'] == cardId &&
        row['deleted_at'] == null,
  );

  /// Writes one deck straight to the account, as another browser's sync would -
  /// the only way a test can have a second browser and one database.
  Future<void> hears(String syncId, {bool removed = false}) => upsertDecks(
    <Map<String, Object?>>[
      <String, Object?>{
        'game': 'mtg',
        'sync_id': syncId,
        'name': 'Krenko',
        'format_id': 'commander',
        'notes': null,
        'name_at': '2026-09-10T12:00:00.000Z',
        'format_at': '2026-09-10T12:00:00.000Z',
        'notes_at': null,
        'deleted_at': removed
            ? DateTime.now().toUtc().toIso8601String()
            : null,
        'created_at': '2026-09-01T00:00:00.000Z',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
    ],
  );
}

/// One browser: its own database, its own sync, the account it is signed in to,
/// and the watcher that keeps that account current.
class _Browser {
  _Browser({
    required this.db,
    required this.sync,
    required this.watcher,
    required this.scope,
  });

  /// Opens a browser, signed in to nothing yet.
  ///
  /// The interval is a parameter because two tests want opposite things from it:
  /// one wants to see the carrying happen on its own and so makes it short, and
  /// the rest want to make a change and then say exactly when it travels.
  static Future<_Browser> open(
    _Account account, {
    Duration interval = const Duration(seconds: 10),
  }) async {
    // A database of its own: sqflite would otherwise hand this browser the same
    // in-memory database another test's browser is using.
    final AppDatabase db = await AppDatabase.openInMemory(own: true);
    final DeckSync sync = DeckSync(table: account, db: db.db);
    final _Browser browser = _Browser(
      db: db,
      sync: sync,
      watcher: DeckWatcher(
        sync: sync,
        signedIn: () => true,
        interval: interval,
      ),
      scope: ProviderContainer(),
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final DeckSync sync;
  final DeckWatcher watcher;
  final ProviderContainer scope;

  DeckDao get dao => DeckDao(db.db);

  bool _givenUp = false;

  /// Signs in the way the gate does when a session appears, and then starts
  /// watching the way `main` does once that sign-in has settled.
  Future<void> signIn() async {
    for (final CardGame game in CardGame.values) {
      await sync.sync(game);
    }
    watcher.begin(scope);
  }

  /// Creates a deck, which is the door a collector uses most.
  Future<int> deck(String name) => dao.createDeck(
    game: CardGame.mtg,
    name: name,
    formatId: 'commander',
  );

  /// The identity of one deck of this browser.
  Future<String> syncIdOf(int id) async =>
      (await db.db.query(
            'decks',
            columns: <String>['sync_id'],
            where: 'id = ?',
            whereArgs: <Object?>[id],
          )).first['sync_id']
          as String;

  Future<void> close() async {
    if (_givenUp) return;
    _givenUp = true;
    watcher.end();
    // A pass that was already running when the tab went away would otherwise
    // finish against a database this is about to close.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    scope.dispose();
    await db.close();
  }
}

/// Waits for something the app reaches on its own.
///
/// A fixed sleep is either a race or a waste, and this is neither.
Future<void> waitFor(bool Function() done, String what) async {
  for (var i = 0; i < 400; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('the account never heard about $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('a deck made here and a card added to it reach the account on their own', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(
      account,
      interval: const Duration(milliseconds: 20),
    );
    await one.signIn();

    final int id = await one.deck('Krenko');
    final String syncId = await one.syncIdOf(id);
    await waitFor(
      () => account.live(syncId),
      'the deck that was just made',
    );

    await one.dao.addCard(id, 'goblin-chieftain', quantity: 4);

    await waitFor(
      () => account.holds(syncId, 'goblin-chieftain'),
      'the card added to it',
    );

    // The incognito window: a second database, the same account, and a sign-in
    // that is the only thing it has ever been told.
    final _Browser incognito = await _Browser.open(account);
    await incognito.signIn();

    final Deck deck = (await incognito.dao.decks(CardGame.mtg)).single;
    expect(deck.name, 'Krenko');
    expect(deck.cardCount, 4);
    expect(
      (await incognito.dao.entries(deck.id, CardGame.mtg)).single.cardId,
      'goblin-chieftain',
    );
  });

  test('a minute of working on a deck is one trip, not a request a card', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    await one.watcher.flush();
    final int before = account.pushes.length;

    for (var i = 0; i < 20; i++) {
      await one.dao.addCard(id, 'card-$i');
    }
    expect(
      account.pushes.length,
      before,
      reason: 'twenty changes on their own sent nothing',
    );

    await one.watcher.flush();

    expect(account.pushes.length, before + 1, reason: 'one trip for twenty');
    expect(
      account.writtenLines.length,
      20,
      reason: 'every line carried once, in one request',
    );
  });

  test('a deck nobody has touched sends nothing at all', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    await one.watcher.flush();
    final int settled = account.pushes.length;

    await one.watcher.flush();
    await one.watcher.flush();

    expect(
      account.pushes.length,
      settled,
      reason: 'a pass with nothing to carry is a query and no request',
    );
    expect(await one.syncIdOf(id), isNotEmpty);
  });

  test('an edit made a moment before the tab goes away still travels', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    final String syncId = await one.syncIdOf(id);
    await one.dao.addCard(id, 'goblin-chieftain');

    // The framework's own path: the browser is told the tab is going away, and a
    // watcher that only knew about its timer would lose the work made in the
    // seconds before this.
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );

    await waitFor(
      () => account.holds(syncId, 'goblin-chieftain'),
      'the last edit before the tab went',
    );
  });

  test('a deck deleted here is a mark on the account, not an absence', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    await one.watcher.flush();
    final String syncId = await one.syncIdOf(id);

    await one.dao.deleteDeck(id);
    await one.watcher.flush();

    expect(account.tombstoned(syncId), isTrue);
    expect(account.live(syncId), isFalse);
    expect(
      account.deckRows.where((Map<String, Object?> r) => r['sync_id'] == syncId),
      hasLength(1),
      reason: 'a row that vanished would be a row the next pull hands back',
    );
  });

  test('an edit here revives a deck another browser deleted', () async {
    // The design's revival, walked through, and it is deliberate rather than an
    // accident of the shape: a deletion is an edit made at a moment, so it beats
    // an older edit and loses to a newer one - and adding a card to the deck is
    // a newer edit. The alternative, a deletion that always wins, is the
    // failure this whole design refuses to ship: it drops the other device's
    // work without a word.
    //
    // It is also where a deck differs from a card in the collection. A card's
    // mark is on the row that was removed, so an edit to a different row cannot
    // clear it; a deck's mark is on the row every content edit stamps, so a card
    // added here is a newer edit to the marked row and the deck comes back -
    // with the card in it, and with every other card still there.
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    await one.dao.addCard(id, 'mogg-war-marshal');
    await one.watcher.flush();
    final String mine = await one.syncIdOf(id);

    // Another browser, gone from this test but not from the account: it deleted
    // the deck this one is still holding and has not heard about it.
    await account.hears(mine, removed: true);
    expect(account.tombstoned(mine), isTrue);

    await one.dao.addCard(id, 'goblin-chieftain');
    await one.watcher.flush();

    expect(account.live(mine), isTrue, reason: 'the newer edit is an edit');
    expect(account.holds(mine, 'goblin-chieftain'), isTrue);
    expect(
      account.holds(mine, 'mogg-war-marshal'),
      isTrue,
      reason: 'and the deck came back whole, not empty',
    );
  });

  test('a carry-up that failed reconciles before it writes again', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int id = await one.deck('Krenko');
    await one.watcher.flush();
    final String mine = await one.syncIdOf(id);

    account.unreachable = true;
    await one.dao.addCard(id, 'goblin-chieftain');
    await one.watcher.flush();
    expect(
      account.holds(mine, 'goblin-chieftain'),
      isFalse,
      reason: 'this browser could not reach the account',
    );

    account.unreachable = false;
    // What the other browser did while this one was not listening: it deleted
    // the deck this browser is still sitting on.
    await account.hears(mine, removed: true);

    await one.watcher.flush();

    expect(await one.dao.decks(CardGame.mtg), isEmpty);
    expect(
      account.tombstoned(mine),
      isTrue,
      reason: 'and the removal it never saw was not written over',
    );
  });
}
