// What an open browser hears about its decks from the account while it stays
// open.
//
//   flutter test test/features/deck_listener_test.dart
//
// The deck half of the report the collection listener was written for. A deck
// renamed in one browser reached that browser's database and no further, so a
// second browser that was already signed in went on showing the old name - and
// a card added to a deck here never appeared there at all - until the page was
// reloaded, which worked because a reload re-runs the sign-in and a sign-in
// pulls.
//
// These tests are about the hearing: that a deck renamed or edited on another
// browser lands without a reload, that it lands through the same merge a pull
// makes rather than through a second rule, that a deck deleted elsewhere leaves
// the list here while its cards stay, that a deck another browser edited back
// to life comes back whole, that a burst of changes is not a burst of rebuilds,
// and that a line arriving with the id of a printing this browser has never
// downloaded is fetched as the card it names rather than left as "--".
//
// None of it needs a websocket. The account announces changes through the same
// kind of seam AccountTable is - a fake that answers instantly and misbehaves on
// demand - because the merge and the coalescing are the parts that have to be
// right, and neither is a thing to leave to a live connection. The shop behind
// the catalogue is faked the same way, and the repository the app itself uses is
// given to that fake, so what is watched here is the fetch the app makes rather
// than a second way of making one written for the test.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/sync/account_changes.dart';
import 'package:arcanum/data/sync/deck_sync.dart';
import 'package:arcanum/data/sync/deck_table.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/auth/deck_listener.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real tables do.
///
/// The collision behaviour is the whole reason this is not a list of what it was
/// handed. The real account resolves a write through its keys - the deck's
/// `(user_id, sync_id)` and the line's `(user_id, deck_sync_id, card_id, board)`
/// - and it does not compare timestamps while doing it. A fake that merged more
/// cleverly than that would let a sync pass a test the real one would fail.
class _Account implements DeckTable {
  List<Map<String, Object?>> deckRows = <Map<String, Object?>>[];
  List<Map<String, Object?>> lineRows = <Map<String, Object?>>[];

  @override
  Future<void> upsertDecks(List<Map<String, Object?>> rows) async {
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

  static String _lineKey(Map<String, Object?> row) => <Object?>[
    row['deck_sync_id'],
    row['card_id'],
    row['board'],
  ].join('|');
}

/// One account table's socket, as the listening side sees it.
///
/// The two things that are hard to arrange against a live service are both here
/// as one line: a change arriving, and a connection that dropped. A real socket
/// drops for reasons nobody can schedule - a laptop lid, a train tunnel - and a
/// catch-up that has only ever been reasoned about is a catch-up that has never
/// been run.
class _Socket implements AccountChanges {
  /// Which account the subscription was asked for, which is the filter it was
  /// asked with.
  String? subscribedTo;

  /// How many times a subscription has been asked for, and how many times it
  /// has been given back.
  int subscriptions = 0;
  int stops = 0;

  /// A table the account will not announce at all.
  bool refused = false;

  void Function(Map<String, Object?> row)? _row;
  void Function()? _live;
  void Function(Object error)? _lost;

  bool get listening => _row != null;

  @override
  Future<void> listen({
    required String accountId,
    required void Function(Map<String, Object?> row) onRow,
    required void Function() onListening,
    required void Function(Object error) onLost,
  }) async {
    subscriptions++;
    if (refused) throw Exception('the account will not announce changes');
    subscribedTo = accountId;
    _row = onRow;
    _live = onListening;
    _lost = onLost;
    // Accepted a moment later rather than on the spot, which is the shape of
    // the real thing: the join travels to the server and the verdict comes back.
    scheduleMicrotask(onListening);
  }

  @override
  Future<void> stop() async {
    stops++;
    _row = null;
    _live = null;
    _lost = null;
  }

  /// Another browser's change, as the socket would deliver it.
  void hears(Map<String, Object?> row) => _row?.call(row);

  /// The subscription is live.
  void liveNow() => _live?.call();

  /// The connection went away underneath a subscription that was live.
  void dropped([Object error = 'the wire went away']) => _lost?.call(error);
}

/// One game's shop, as the browser sees it.
///
/// A source with nothing clever to do with a list of ids - it asks about them
/// one at a time, which is what every catalogue does that has no set to read a
/// whole bulk out of - and it records what it was asked, so that a test can see
/// whether a fetch happened at all and how the ids were sliced rather than
/// assume either.
class _Source extends CardCatalog {
  _Source(this.game, this.events);

  @override
  final CardGame game;

  /// The browser's log of everything that happened, in order. A request is
  /// written to it as well as the tellings, because one of these tests asks
  /// something no log of its own could answer: whether the cards were here by
  /// the time the screens heard about the row.
  final List<String> events;

  /// The ids of every request, in the order the requests were made.
  final List<List<String>> bulks = <List<String>>[];

  /// A shop that will not answer at all - one that is down, a network that
  /// refuses it.
  bool failing = false;

  @override
  String get sourceName => 'test';

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    events.add('cards:${game.id}');
    bulks.add(List<String>.of(ids));
    if (failing) throw const CatalogException('the shop did not answer');
    return super.fetchCardsByIds(ids);
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async => printing(id, game: game);

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
  Future<List<TcgCard>> search(String query, {int limit = 100}) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async => cards;
}

/// One browser: its own database, the account it is signed in to, the shop it
/// asks for cards, and the listener that hears from that account.
class _Browser {
  _Browser({
    required this.db,
    required this.scope,
    required this.sync,
    required this.socket,
    required this.sources,
    required this.catalogDao,
    required this.catalog,
    required this.events,
  });

  /// Opens a browser, signed in to nothing yet.
  static Future<_Browser> open(
    _Account account, {
    Duration settle = const Duration(milliseconds: 25),
    Duration retry = const Duration(seconds: 2),
  }) async {
    // A database of its own: sqflite would otherwise hand this browser the same
    // in-memory database another test's browser is using - and one of these
    // tests opens two browsers to compare what each of them makes of one row.
    final AppDatabase db = await AppDatabase.openInMemory(own: true);
    final List<String> events = <String>[];
    // Every game gets a source, because a browser has a shop to ask for any of
    // them; a game with nothing to ask is a different file's question.
    final Map<CardGame, _Source> sources = <CardGame, _Source>{
      for (final CardGame game in CardGame.values) game: _Source(game, events),
    };
    final CatalogDao catalogDao = CatalogDao(db.db);
    final _Browser browser = _Browser(
      db: db,
      scope: ProviderContainer(),
      sync: DeckSync(table: account, db: db.db),
      socket: _Socket(),
      sources: sources,
      catalogDao: catalogDao,
      catalog: CatalogRepository(catalogs: sources, dao: catalogDao),
      events: events,
    );
    browser.listener = DeckListener(
      sync: browser.sync,
      changes: browser.socket,
      catalog: browser.catalog,
      signedIn: () => browser.signedIn,
      accountId: () => browser.account,
      settle: settle,
      retry: retry,
      // What a test wants to see is how often the screens are told, and the
      // telling is the thing being coalesced - so it is counted here rather than
      // watched through a provider, which would measure the same fact through a
      // query. It is written to the log as well, because two tests need to see
      // the telling against the fetch rather than on its own.
      announce: (ProviderContainer scope) {
        browser.announced++;
        events.add('announce');
      },
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final ProviderContainer scope;
  final DeckSync sync;
  final _Socket socket;

  /// Each game's shop, which is what a fetch is made against.
  final Map<CardGame, _Source> sources;

  final CatalogDao catalogDao;
  final CatalogRepository catalog;

  /// Everything the browser did, in the order it did it: a request its shop was
  /// given, and a telling its screens were given.
  final List<String> events;

  /// How many times the screens have been told the decks moved.
  int announced = 0;

  late final DeckListener listener;

  bool signedIn = true;
  String? account = 'account-1';

  DeckDao get dao => DeckDao(db.db);

  /// The shop this browser asks for a Magic card.
  _Source get shop => sources[CardGame.mtg]!;

  /// Signs in the way the gate does, and starts listening the way [main] does.
  void signIn() => listener.begin(scope);

  /// What this browser would show its owner, for one game.
  Future<List<Deck>> decks([CardGame game = CardGame.mtg]) =>
      dao.decks(game);

  /// The lines of one deck, as this browser would show them.
  Future<List<DeckEntry>> entries(int id, [CardGame game = CardGame.mtg]) =>
      dao.entries(id, game);

  /// One raw row of a local table, which is how a mark is seen at all: the
  /// reads filter marks out, and a test about a deletion has to look past them.
  Future<Map<String, Object?>> row(String table, int id) async =>
      (await db.db.query(table, where: 'id = ?', whereArgs: <Object?>[id]))
          .single;

  Future<void> close() async {
    listener.end();
    // A merge that was already queued when the tab went away would otherwise
    // finish against a database this is about to close.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    scope.dispose();
    await db.close();
  }
}

/// A deck row as PostgREST and Realtime both render it.
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

/// A printing as this browser's own catalogue holds one.
TcgCard printing(String id, {CardGame game = CardGame.mtg}) => TcgCard(
  game: game,
  id: id,
  setCode: 'BLB',
  setName: 'Bloomburrow',
  name: 'Card $id',
  collectorNumber: '001',
  rarity: 'common',
);

/// An instant in the account's own spelling, [ago] before now.
String stamp(Duration ago) =>
    DateTime.now().toUtc().subtract(ago).toIso8601String();

/// An instant [ago] before now, in the milliseconds both local tables count.
int millis(Duration ago) =>
    DateTime.now().subtract(ago).millisecondsSinceEpoch;

/// A deck written straight into a device, with the clocks a test wants rather
/// than the clock the machine happens to have.
Future<int> putDeck(
  Database db, {
  required String syncId,
  String game = 'mtg',
  String name = 'Krenko',
  String formatId = 'commander',
  String? notes,
  int? nameAt,
  int? formatAt,
  int? notesAt,
  int? deletedAt,
  int updatedAt = 1000,
  int createdAt = 1000,
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
  int updatedAt = 1000,
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

/// Waits for something the app reaches on its own.
///
/// The alternative is a test that asserts against a machine's speed: a fixed
/// sleep is either a race or a waste, and this is neither.
Future<void> waitFor(Future<bool> Function() done, String what) async {
  for (var i = 0; i < 400; i++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('$what never happened');
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('a deck renamed on another browser arrives while this one is open', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await putDeck(
      one.db.db,
      syncId: 'mine',
      name: 'Krenko',
      nameAt: millis(const Duration(hours: 2)),
      updatedAt: millis(const Duration(hours: 2)),
    );
    one.signIn();

    one.socket.hears(
      accountDeck(
        syncId: 'mine',
        name: 'Krenko (v2)',
        nameAt: stamp(const Duration(minutes: 1)),
        updated: stamp(const Duration(minutes: 1)),
      ),
    );

    await waitFor(
      () async => (await one.decks()).single.name == 'Krenko (v2)',
      'the rename made on the other browser',
    );
    await waitFor(
      () async => one.announced > 0,
      'the screen being told',
    );
    // The row is this browser's own copy, in its own table, and it kept the
    // identity it came with rather than minting one.
    final Map<String, Object?> row = await one.row('decks', (await one.decks()).single.id);
    expect(row['sync_id'], 'mine');
  });

  test('a row heard on its own merges exactly as a pulled one does', () async {
    // The design's rule, and the reason the listener has no rule of its own:
    // there is one place where two copies of a deck are weighed, and a change
    // that arrives on its own goes through it. Two browsers hold the same deck,
    // one hears the row and the other pulls it, and what comes out of the two
    // has to be the same answer - for a row that wins and for a row that loses.
    final _Account account = _Account();
    final _Browser heard = await _Browser.open(account);
    final _Browser pulled = await _Browser.open(account);
    final int older = millis(const Duration(hours: 2));
    for (final _Browser browser in <_Browser>[heard, pulled]) {
      await putDeck(
        browser.db.db,
        syncId: 'mine',
        name: 'Mine',
        formatId: 'modern',
        nameAt: older,
        updatedAt: older,
      );
    }

    final Map<String, Object?> newer = accountDeck(
      syncId: 'mine',
      name: 'Theirs',
      formatId: 'commander',
      notes: 'goblins',
      nameAt: stamp(const Duration(hours: 1)),
      formatAt: stamp(const Duration(hours: 1)),
      notesAt: stamp(const Duration(hours: 1)),
      updated: stamp(const Duration(minutes: 30)),
    );
    heard.signIn();
    heard.socket.hears(newer);
    account.deckRows = <Map<String, Object?>>[newer];
    await pulled.sync.pull(CardGame.mtg);

    await waitFor(
      () async => (await heard.decks()).single.name == 'Theirs',
      'the row heard on its own',
    );

    final Map<String, Object?> heardRow =
        await heard.row('decks', (await heard.decks()).single.id);
    final Map<String, Object?> pulledRow =
        await pulled.row('decks', (await pulled.decks()).single.id);
    for (final String column in <String>[
      'name',
      'format_id',
      'notes',
      'name_at',
      'format_at',
      'notes_at',
      'deleted_at',
      'updated_at',
    ]) {
      expect(
        heardRow[column],
        pulledRow[column],
        reason: '$column: a heard row and a pulled row are the same merge',
      );
    }
    expect(heardRow['name'], 'Theirs');

    // And the other half of the rule, which is the half that loses somebody's
    // evening when it is wrong: a row the account is behind on changes nothing
    // here, whether it arrives on a socket or in a pull.
    final Map<String, Object?> stale = accountDeck(
      syncId: 'mine',
      name: 'Stale',
      nameAt: stamp(const Duration(days: 2)),
      updated: stamp(const Duration(days: 2)),
    );
    heard.socket.hears(stale);
    account.deckRows = <Map<String, Object?>>[stale];
    await pulled.sync.pull(CardGame.mtg);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect((await heard.decks()).single.name, 'Theirs');
    expect((await pulled.decks()).single.name, 'Theirs');
  });

  test('a card added on another browser arrives in the deck', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    final int id = await putDeck(one.db.db, syncId: 'mine');
    one.signIn();

    one.socket.hears(
      accountLine(
        deckSyncId: 'mine',
        cardId: 'goblin-chieftain',
        quantity: 4,
      ),
    );

    await waitFor(
      () async => (await one.decks()).single.cardCount == 4,
      'the card added on the other browser',
    );
    expect((await one.entries(id)).single.cardId, 'goblin-chieftain');
  });

  test('a line naming an undownloaded card is fetched as a card', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await putDeck(one.db.db, syncId: 'mine');
    one.signIn();

    one.socket.hears(
      accountLine(deckSyncId: 'mine', cardId: 'goblin-chieftain'),
    );

    await waitFor(() async => one.announced > 0, 'the screen being told');
    // The report this exists for: the line names a printing whose set this
    // browser has never opened, so the deck would draw it as nothing but "--".
    // The fetch comes first, which is what makes the rebuild the collector sees
    // a deck with a card in it rather than a placeholder that a second rebuild
    // then takes away.
    expect(one.events, <String>['cards:mtg', 'announce']);
    expect(one.shop.bulks.single, <String>['goblin-chieftain']);
    final TcgCard? fetched = await one.catalogDao.cardById(
      CardGame.mtg,
      'goblin-chieftain',
    );
    expect(fetched?.name, 'Card goblin-chieftain');
  });

  test('a deck row needs no catalogue at all', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    one.socket.hears(
      accountDeck(syncId: 'theirs', nameAt: stamp(const Duration(minutes: 1))),
    );

    await waitFor(() async => one.announced > 0, 'the screen being told');
    // A deck with no lines names no printing, so nothing is asked for: the one
    // question worth a request - is this card missing - has nothing to ask
    // about.
    expect(one.events, <String>['announce']);
    expect(one.shop.bulks, isEmpty);
  });

  test('a burst of arrivals is one fetch and one telling, not one a row', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(
      account,
      settle: const Duration(milliseconds: 250),
    );
    await putDeck(one.db.db, syncId: 'mine');
    one.signIn();

    // An import on the other device: one event per line, arriving together.
    for (var i = 0; i < 50; i++) {
      one.socket.hears(accountLine(deckSyncId: 'mine', cardId: 'card-$i'));
    }

    await waitFor(
      () async => (await one.entries((await one.decks()).single.id)).length == 50,
      'the import to land',
    );
    // Every line landed, and no screen was rebuilt to say so: the telling waits
    // for the run of them to finish rather than following each one.
    expect(
      one.announced,
      0,
      reason: 'the rebuild waits for the burst to settle',
    );

    await waitFor(() async => one.announced > 0, 'the screen being told once');
    // One tick of the clock later, and still one telling.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(one.announced, 1);
    expect(one.events, <String>['cards:mtg', 'announce']);
    expect(one.shop.bulks.single, hasLength(50));
  });

  test('a deck deleted on another browser leaves the list and keeps its cards', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    final int id = await putDeck(
      one.db.db,
      syncId: 'mine',
      updatedAt: millis(const Duration(hours: 1)),
    );
    await putLine(one.db.db, id, cardId: 'goblin-chieftain', quantity: 4);
    one.signIn();
    expect(await one.decks(), hasLength(1));

    // Another device deletes it: the same row with a deletion stamped on it and
    // a later updated_at, which is all a deletion is.
    one.socket.hears(
      accountDeck(
        syncId: 'mine',
        deleted: stamp(Duration.zero),
        updated: stamp(Duration.zero),
      ),
    );

    await waitFor(() async => (await one.decks()).isEmpty, 'the deck to go');
    // Gone from the list and still in the table, because the row is what
    // carries the removal - a row that simply vanished would be a deck the next
    // push puts back on every device.
    final Map<String, Object?> deck = await one.row('decks', id);
    expect(deck['deleted_at'], isNotNull);
    // And its lines are untouched, which is what makes a revival whole rather
    // than a one-card deck with the same name.
    final List<Map<String, Object?>> lines = await one.db.db.query(
      'deck_cards',
      where: 'deck_id = ?',
      whereArgs: <Object?>[id],
    );
    expect(lines, hasLength(1));
    expect(lines.single['deleted_at'], isNull);
    expect(lines.single['quantity'], 4);
  });

  test('a deck another browser edited back to life comes back whole', () async {
    // The design's revival, heard rather than reasoned about: a deletion is an
    // edit made at a moment, so it beats an older edit and loses to a newer one
    // - and an edit made on a device that never heard about the deletion is the
    // newer one. What the collector sees is the deck back on the list, with
    // everything that was in it.
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    final int id = await putDeck(
      one.db.db,
      syncId: 'mine',
      name: 'Krenko',
      deletedAt: millis(const Duration(hours: 1)),
      updatedAt: millis(const Duration(hours: 1)),
    );
    await putLine(one.db.db, id, cardId: 'mogg-war-marshal', quantity: 1);
    one.signIn();
    expect(await one.decks(), isEmpty, reason: 'it is deleted here');

    one.socket.hears(
      accountDeck(
        syncId: 'mine',
        name: 'Krenko',
        nameAt: stamp(const Duration(hours: 2)),
        deleted: null,
        updated: stamp(Duration.zero),
      ),
    );

    await waitFor(() async => (await one.decks()).isNotEmpty, 'the deck to come back');
    final Deck deck = (await one.decks()).single;
    expect(deck.cardCount, 1, reason: 'and whole, not empty');
    await waitFor(() async => one.announced > 0, 'the screen being told');
  });

  test('a change in another vault is filed in that vault', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    one.socket.hears(
      accountDeck(
        syncId: 'gundam-1',
        game: 'gundam',
        nameAt: stamp(const Duration(minutes: 1)),
      ),
    );

    await waitFor(
      () async => (await one.decks(CardGame.gundam)).isNotEmpty,
      'the deck in the other vault',
    );
    expect(await one.decks(CardGame.mtg), isEmpty);
    await waitFor(() async => one.announced > 0, 'the telling');
  });

  test('a row for a game this build does not know is dropped', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    // A game shipped on the account by a release this browser does not have.
    // Nine games exist today and this is not one of them. CardGame.fromId
    // answers Magic for anything it does not recognise, which would file this
    // deck into the Magic vault - a deck in a place it is not, and one the next
    // push would carry up as Magic's.
    one.socket.hears(accountDeck(syncId: 'future', game: 'zz-not-a-game'));

    await Future<void>.delayed(const Duration(milliseconds: 80));
    for (final CardGame game in CardGame.values) {
      expect(await one.decks(game), isEmpty, reason: 'nothing in ${game.id}');
    }
    expect(one.announced, 0);
  });

  test('a connection that came back catches up on what it missed', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    // What the account took while this browser was not listening. Nothing
    // announces it - Realtime has no memory, and the change happened while there
    // was no subscription to hear it.
    account.deckRows = <Map<String, Object?>>[
      accountDeck(syncId: 'theirs', nameAt: stamp(const Duration(minutes: 1))),
    ];
    account.lineRows = <Map<String, Object?>>[
      accountLine(deckSyncId: 'theirs', cardId: 'lightning-bolt', quantity: 4),
    ];
    one.socket.dropped();

    await waitFor(
      () async => (await one.decks()).isNotEmpty,
      'the deck made while the wire was down',
    );
    expect((await one.decks()).single.cardCount, 4);
    await waitFor(() async => one.announced > 0, 'the screen being told');
  });

  test('an account that will not announce changes is asked again', () async {
    final _Account account = _Account();
    account.deckRows = <Map<String, Object?>>[
      accountDeck(syncId: 'theirs', nameAt: stamp(const Duration(minutes: 1))),
    ];
    final _Browser one = await _Browser.open(
      account,
      retry: const Duration(milliseconds: 20),
    );

    // Realtime unavailable: a network that refuses websockets, a project with
    // it switched off. The app goes on working - it just stops hearing.
    one.socket.refused = true;
    one.signIn();
    await waitFor(() async => one.socket.subscriptions >= 1, 'the first try');
    expect(
      await one.decks(),
      isEmpty,
      reason: 'nothing is being announced, so nothing has arrived',
    );

    one.socket.refused = false;

    // And without anybody reloading anything, the next attempt subscribes and
    // the catch-up brings down what arrived in the meantime.
    await waitFor(
      () async => (await one.decks()).isNotEmpty,
      'the catch-up after the connection came back',
    );
    expect(one.socket.subscribedTo, 'account-1');
  });

  test('a browser with no account asks for nothing', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signedIn = false;
    one.account = null;

    one.signIn();

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      one.socket.subscriptions,
      0,
      reason: 'a phone keeps its decks to itself and holds no socket',
    );
  });

  group('two tables heard as one subscription', () {
    test('a row from either half reaches the one callback', () async {
      final _Socket decks = _Socket();
      final _Socket lines = _Socket();
      final List<Map<String, Object?>> heard = <Map<String, Object?>>[];
      await JoinedChanges(decks, lines).listen(
        accountId: 'account-1',
        onRow: heard.add,
        onListening: () {},
        onLost: (_) {},
      );

      decks.hears(accountDeck(syncId: 'mine'));
      lines.hears(accountLine(deckSyncId: 'mine', cardId: 'bolt'));

      expect(heard, hasLength(2));
      expect(heard.first['sync_id'], 'mine');
      expect(heard.last['card_id'], 'bolt');
      expect(decks.subscribedTo, 'account-1');
      expect(lines.subscribedTo, 'account-1');
    });

    test('the pair is live only once both halves are, and only once', () async {
      final _Socket decks = _Socket();
      final _Socket lines = _Socket();
      var live = 0;
      await JoinedChanges(decks, lines).listen(
        accountId: 'account-1',
        onRow: (_) {},
        onListening: () => live++,
        onLost: (_) {},
      );
      // Both fakes report themselves live on a microtask, so by now the pair
      // has said so once - and a second report from a half that never dropped
      // is not a second live subscription.
      await Future<void>.delayed(Duration.zero);
      expect(live, 1);

      decks.liveNow();
      await Future<void>.delayed(Duration.zero);
      expect(live, 1, reason: 'the pair was already live');

      // A half that dropped and came back is the pair live again, which is what
      // makes a reconnection run a catch-up. The other half is still up, so
      // this is the moment both are.
      decks.dropped();
      decks.liveNow();
      await Future<void>.delayed(Duration.zero);
      expect(live, 2);
    });

    test('a half that dropped takes the pair with it', () async {
      final _Socket decks = _Socket();
      final _Socket lines = _Socket();
      final List<Object> lost = <Object>[];
      await JoinedChanges(decks, lines).listen(
        accountId: 'account-1',
        onRow: (_) {},
        onListening: () {},
        onLost: lost.add,
      );
      await Future<void>.delayed(Duration.zero);

      lines.dropped('the wire went away');
      expect(lost, <Object>['the wire went away']);
    });

    test('stopping stops both', () async {
      final _Socket decks = _Socket();
      final _Socket lines = _Socket();
      final JoinedChanges changes = JoinedChanges(decks, lines);
      await changes.listen(
        accountId: 'account-1',
        onRow: (_) {},
        onListening: () {},
        onLost: (_) {},
      );

      await changes.stop();

      expect(decks.stops, 1);
      expect(lines.stops, 1);
      expect(decks.listening, isFalse);
      expect(lines.listening, isFalse);
    });
  });
}
