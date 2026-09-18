// What an open browser hears from the account while it stays open.
//
//   flutter test test/features/collection_listener_test.dart
//
// The report this exists for: a collection synced up to the account in about a
// second, and a second browser that was already signed in went on showing the
// collection as it had been at its own sign-in. Adding a card or removing one
// here did not reach there until the page was reloaded - and the reload worked,
// because it re-runs the sign-in, and a sign-in pulls. So the pull was never
// the broken half; nothing was asking for one.
//
// These tests are about the hearing: that another device's change lands without
// a reload, that a removal lands as a removal and hides the card, that an older
// row from the account does not overwrite newer work here, that a burst of
// changes is not a burst of rebuilds, that a change in a vault nobody is looking
// at does not disturb the vault they are, and that a row arriving with the id of
// a printing this browser has never downloaded is fetched as the card it names
// rather than left on the list as "--".
//
// None of it needs a websocket. The account announces changes through the same
// kind of seam AccountTable is - a fake that answers instantly and misbehaves on
// demand - because the merge and the coalescing are the parts that have to be
// right, and neither is a thing to leave to a live connection. The shop behind
// the collection is faked the same way, and the repository the app itself uses
// is given to that fake, so what is watched here is the fetch the app makes
// rather than a second way of making one written for the test.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/sync/account_changes.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/auth/collection_listener.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real table does.
///
/// The collision behaviour is the whole reason this is not a list of what it
/// was handed. The real table resolves a write through its unique index without
/// comparing timestamps, so a fake that merged more cleverly would let a sync
/// pass a test the real one would fail.
class _Account implements AccountTable {
  List<Map<String, Object?>> written = <Map<String, Object?>>[];
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

  static String _key(Map<String, Object?> row) => <Object?>[
    row['card_id'],
    row['finish'],
    row['condition'],
    row['language'],
    row['binder'],
  ].join('|');
}

/// The account's socket, as the listening side sees it.
///
/// The two things that are hard to arrange against a live service are both
/// here as one line: a change arriving, and a connection that dropped. A real
/// socket drops for reasons nobody can schedule - a laptop lid, a train
/// tunnel - and a catch-up that has only ever been reasoned about is a
/// catch-up that has never been run.
class _Socket implements AccountChanges {
  /// Which account the subscription was asked for, which is the filter it was
  /// asked with.
  String? subscribedTo;

  /// How many times a subscription has been asked for.
  int subscriptions = 0;

  /// An account that will not accept a subscription at all.
  bool refused = false;

  void Function(Map<String, Object?> row)? _row;
  void Function()? _live;
  void Function(Object error)? _lost;

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
    // the real thing: the join travels to the server and the verdict comes
    // back, and changes made in between are not replayed.
    scheduleMicrotask(onListening);
  }

  @override
  Future<void> stop() async {
    _row = null;
    _live = null;
    _lost = null;
  }

  /// Another browser's edit, as the socket would deliver it.
  void hears(Map<String, Object?> row) => _row?.call(row);

  /// The connection came back, and the subscription is live again.
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
    final AppDatabase db = await AppDatabase.openInMemory();
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
      sync: CollectionSync(table: account, db: db.db),
      socket: _Socket(),
      sources: sources,
      catalogDao: catalogDao,
      catalog: CatalogRepository(catalogs: sources, dao: catalogDao),
      events: events,
    );
    browser.listener = CollectionListener(
      sync: browser.sync,
      changes: browser.socket,
      catalog: browser.catalog,
      signedIn: () => browser.signedIn,
      accountId: () => browser.account,
      settle: settle,
      retry: retry,
      // What a test wants to see is how often the screens are told, and the
      // telling is the thing being coalesced - so it is counted here rather
      // than watched through a provider, which would measure the same fact
      // through a query. It is written to the log as well, because one test
      // needs to see the telling against the fetch rather than on its own.
      announce: (ProviderContainer scope, CardGame game) {
        browser.announced.add(game);
        events.add('announce:${game.id}');
      },
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final ProviderContainer scope;
  final CollectionSync sync;
  final _Socket socket;

  /// Each game's shop, which is what a fetch is made against.
  final Map<CardGame, _Source> sources;

  final CatalogDao catalogDao;
  final CatalogRepository catalog;

  /// Everything the browser did, in the order it did it: a request its shop was
  /// given, and a telling its screens were given.
  final List<String> events;

  /// The games the screens have been told about, in the order they were told.
  final List<CardGame> announced = <CardGame>[];

  late final CollectionListener listener;

  bool signedIn = true;
  String? account = 'account-1';

  CollectionDao get dao => CollectionDao(db.db);

  /// The shop this browser asks for a Magic card.
  _Source get shop => sources[CardGame.mtg]!;

  /// Signs in the way the gate does, and starts listening the way [main] does.
  void signIn() => listener.begin(scope);

  /// What this browser would show its owner, for one game.
  Future<Set<String>> owned({CardGame game = CardGame.mtg}) async => <String>{
    for (final CollectionEntry entry in await dao.all(game)) entry.cardId,
  };

  Future<void> close() async {
    listener.end();
    // A merge that was already queued when the tab went away would otherwise
    // finish against a database this is about to close.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    scope.dispose();
    await db.close();
  }
}

/// One row of the account's table, as PostgREST and Realtime both render it.
Map<String, Object?> accountRow({
  required String cardId,
  String game = 'mtg',
  int quantity = 1,
  String updated = '2026-09-10T12:00:00.000Z',
  String? deleted,
}) => <String, Object?>{
  'card_id': cardId,
  'game': game,
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

/// A holding this device has been carrying for a while.
CollectionEntry held(String cardId, {int quantity = 1}) => CollectionEntry(
  cardId: cardId,
  quantity: quantity,
  createdAt: DateTime.now().subtract(const Duration(hours: 1)),
  updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
);

/// An instant in the account's own spelling, [ago] before now.
String stamp(Duration ago) =>
    DateTime.now().toUtc().subtract(ago).toIso8601String();

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

  test(
    'a card added on another browser arrives while this one is open',
    () async {
      final _Account account = _Account();
      final _Browser one = await _Browser.open(account);
      one.signIn();

      one.socket.hears(accountRow(cardId: 'bolt-1'));

      await waitFor(
        () async => (await one.owned()).contains('bolt-1'),
        'the card added on the other browser',
      );
      // The row is this browser's own copy, in its own table, filed under the
      // game the account says it belongs to.
      expect(
        (await one.db.db.query('collection_entries')).single['game'],
        'mtg',
      );
      await waitFor(
        () async => one.announced.isNotEmpty,
        'the screen being told',
      );
    },
  );

  test('a row naming an undownloaded card is fetched as a card', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    one.socket.hears(accountRow(cardId: 'bolt-1'));

    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told',
    );
    // The report this exists for. The row names a printing whose set this
    // browser has never opened, so the list can draw it as nothing but "--" -
    // and the fetch comes first, which is what makes the rebuild the collector
    // sees a list with a card on it rather than a placeholder that a second
    // rebuild then takes away.
    expect(one.events, <String>['cards:mtg', 'announce:mtg']);
    expect(one.shop.bulks.single, <String>['bolt-1']);
    final TcgCard? fetched = await one.catalogDao.cardById(
      CardGame.mtg,
      'bolt-1',
    );
    expect(fetched?.name, 'Card bolt-1');
  });

  test('a card this browser already has is not asked for again', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    // The browser that has everything: it opened this set for another printing,
    // or fetched this one for another holding a moment ago, and is only now
    // hearing about this holding.
    await one.catalogDao.upsertCards(CardGame.mtg, <TcgCard>[
      printing('bolt-1'),
    ]);
    one.signIn();

    one.socket.hears(accountRow(cardId: 'bolt-1'));

    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told',
    );
    // The holding is new here and is announced like any other; the card behind
    // it is not asked for, because the only question worth a request - is this
    // printing missing - was answered out of the local catalogue.
    expect(await one.owned(), contains('bolt-1'));
    expect(one.events, <String>['announce:mtg']);
    expect(one.shop.bulks, isEmpty);
  });

  test('a burst of arrivals is one fetch, not one a row', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(
      account,
      settle: const Duration(milliseconds: 250),
    );
    one.signIn();

    // A bulk import on the other device: one event per card, arriving together.
    for (var i = 0; i < 50; i++) {
      one.socket.hears(accountRow(cardId: 'card-$i'));
    }

    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told once',
    );
    // One request for the whole import and one telling, which is the gathering
    // the merges already wait for carried through to the fetch. A request per
    // row would be fifty of each, against a shop that pays for every one - and
    // a list rebuilt fifty times, which is the flicker the settle window is
    // there to prevent.
    expect(one.events, <String>['cards:mtg', 'announce:mtg']);
    expect(one.shop.bulks.single, hasLength(50));
    expect(one.announced, <CardGame>[CardGame.mtg]);
  });

  test('a fetch that failed still leaves the holding on the list', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    // A shop that is down, or a network that will not carry the request.
    one.shop.failing = true;
    one.signIn();

    one.socket.hears(accountRow(cardId: 'bolt-1'));

    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told',
    );
    // The row is what the list is made of, and it is in the collection and on
    // the screen whether or not the card behind it came back. A card nobody
    // could fetch costs the collector the name of a card - the placeholder this
    // browser showed before any of this existed - and never the card itself.
    expect(await one.owned(), contains('bolt-1'));
    expect(one.announced, <CardGame>[CardGame.mtg]);
    expect(await one.catalogDao.cardById(CardGame.mtg, 'bolt-1'), isNull);
  });

  test('a removal made on another browser hides the card here', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await putLocal(one.db.db, held('lotus-1'));
    one.signIn();
    expect(await one.owned(), <String>{'lotus-1'});

    // Another device removes it: the same row with a deletion stamped on it, a
    // later edit than this browser's copy.
    one.socket.hears(
      accountRow(
        cardId: 'lotus-1',
        deleted: stamp(Duration.zero),
        updated: stamp(Duration.zero),
      ),
    );

    await waitFor(() async => (await one.owned()).isEmpty, 'the card to go');
    // Gone from the collection and still in the table, because the row is what
    // carries the removal - a row that simply vanished would be a card the next
    // push puts back on every device.
    expect(
      (await one.db.db.query('collection_entries')).single['deleted_at'],
      isNotNull,
    );
  });

  test('an older row from the account loses to newer work here', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    // Edited here a moment ago - a quantity set at the table - against a copy
    // of the same holding the account has not been told about yet.
    await putLocal(
      one.db.db,
      CollectionEntry(
        cardId: 'lotus-1',
        quantity: 4,
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        updatedAt: DateTime.now(),
      ),
    );
    one.signIn();

    one.socket.hears(
      accountRow(
        cardId: 'lotus-1',
        quantity: 1,
        updated: stamp(const Duration(minutes: 30)),
      ),
    );

    // Nothing is announced, because nothing changed: a screen rebuilt for a row
    // that lost its comparison is a rebuild nobody can account for.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(
      (await one.dao.all(CardGame.mtg)).single.quantity,
      4,
      reason: 'the account had the older copy',
    );
    expect(one.announced, isEmpty);
  });

  test('a burst of changes announces once, not once a row', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(
      account,
      settle: const Duration(milliseconds: 250),
    );
    one.signIn();

    // A bulk import on the other device: one event per card, arriving together.
    for (var i = 0; i < 50; i++) {
      one.socket.hears(accountRow(cardId: 'card-$i'));
    }

    await waitFor(
      () async => (await one.owned()).length == 50,
      'the import to land',
    );
    // Every row landed, and no screen was rebuilt to say so: the telling waits
    // for the run of them to finish rather than following each one.
    expect(
      one.announced,
      isEmpty,
      reason: 'the rebuild waits for the burst to settle',
    );

    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told once',
    );
    // One tick of the clock later, and still one telling.
    await Future<void>.delayed(const Duration(milliseconds: 260));
    expect(one.announced, <CardGame>[CardGame.mtg]);
  });

  test(
    'a change in another vault does not disturb the one on screen',
    () async {
      final _Account account = _Account();
      final _Browser one = await _Browser.open(account);
      one.signIn();

      one.socket.hears(accountRow(cardId: 'gundam-1', game: 'gundam'));

      await waitFor(() async => one.announced.isNotEmpty, 'the telling');
      // Merged, because the collection is the account's and this browser holds
      // every vault it owns...
      expect(await one.owned(game: CardGame.gundam), <String>{'gundam-1'});
      // ...and told about on its own, because a game's screens are its own
      // screens: announcing all nine would rebuild the vault being looked at to
      // show it exactly what it is already showing.
      expect(one.announced, <CardGame>[CardGame.gundam]);
    },
  );

  test('a connection that came back catches up on what it missed', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    one.signIn();

    // What the account took while this browser was not listening. Nothing
    // announces it - Realtime has no memory, and the change happened while
    // there was no subscription to hear it.
    account.remote = <Map<String, Object?>>[accountRow(cardId: 'bolt-9')];
    one.socket.dropped();

    await waitFor(
      () async => (await one.owned()).contains('bolt-9'),
      'the change made while the wire was down',
    );
    await waitFor(
      () async => one.announced.isNotEmpty,
      'the screen being told',
    );
  });

  test('an account that will not announce changes is asked again', () async {
    final _Account account = _Account();
    account.remote = <Map<String, Object?>>[accountRow(cardId: 'bolt-1')];
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
      await one.owned(),
      isEmpty,
      reason: 'nothing is being announced, so nothing has arrived',
    );

    one.socket.refused = false;

    // And without anybody reloading anything, the next attempt subscribes and
    // the catch-up brings down what arrived in the meantime.
    await waitFor(
      () async => (await one.owned()).contains('bolt-1'),
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
      reason: 'a phone keeps its vault to itself and holds no socket',
    );
  });
}
