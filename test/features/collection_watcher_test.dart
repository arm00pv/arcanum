// What a browser carries up after it has signed in.
//
//   flutter test test/features/collection_watcher_test.dart
//
// The report this exists for: a collector was signed in on one browser, added a
// card and removed another, opened an incognito window, signed in there and
// found the card they had removed still in the collection and the card they had
// added missing. Nothing carried a local change to the account, so the only
// thing a second browser could be shown was the account as it had been at the
// last sign-in - the removed card, and no knowledge at all of the new one.
//
// These tests are about the carrying: that it happens by itself while the
// browser is open, that a minute of changing things is not a request per
// change, that the edit made a moment before the tab goes away still travels,
// and that a change made here cannot undo a removal made somewhere else.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/data/sync/account_collection.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';
import 'package:arcanum/features/auth/collection_watcher.dart';
import 'package:arcanum/providers.dart';

/// An account that answers instantly, remembers what it was told, and takes a
/// repeated write the way the real table does.
///
/// The collision behaviour is not incidental to these tests. Every push here is
/// blind - an upsert that never asks what is already there - and a fake that
/// merged more cleverly than the real table would let a careless push look
/// harmless in a test the real account would fail.
class _Account implements AccountTable {
  /// One entry per write, so a test can weigh a minute of editing against the
  /// requests it caused.
  final List<List<Map<String, Object?>>> pushes =
      <List<Map<String, Object?>>>[];

  /// What the account holds.
  List<Map<String, Object?>> remote = <Map<String, Object?>>[];

  /// A connection that is down, which is the shape of every way a carry-up
  /// fails without anybody being told about it.
  bool unreachable = false;

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {
    if (unreachable) throw Exception('the account did not answer');
    pushes.add(List<Map<String, Object?>>.of(rows));
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
  Future<List<Map<String, Object?>>> fetch(CardGame game) async {
    if (unreachable) throw Exception('the account did not answer');
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in remote)
        if (row['game'] == game.id) row,
    ];
  }

  /// Whether the account holds this card as something its owner has.
  bool live(String cardId) => remote.any(
    (Map<String, Object?> row) =>
        row['card_id'] == cardId && row['deleted_at'] == null,
  );

  /// Whether the account holds the card as removed.
  bool tombstoned(String cardId) => remote.any(
    (Map<String, Object?> row) =>
        row['card_id'] == cardId && row['deleted_at'] != null,
  );

  /// Writes one holding straight to the account, as another browser's sync
  /// would - the only way a test can have a second browser and one database.
  Future<void> hears(
    String cardId, {
    bool removed = false,
    CardGame game = CardGame.mtg,
  }) => upsert(<Map<String, Object?>>[
    AccountCollection.row(
      CollectionEntry(
        cardId: cardId,
        createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        updatedAt: DateTime.now(),
        deletedAt: removed ? DateTime.now() : null,
      ),
      game,
    ),
  ]);

  static String _key(Map<String, Object?> row) => <Object?>[
    row['card_id'],
    row['finish'],
    row['condition'],
    row['language'],
    row['binder'],
  ].join('|');
}

/// A catalogue with nothing to say.
///
/// A sign-in resolves the cards behind a collection after it has the holdings,
/// and these tests are about the holdings: an answer from a real provider here
/// would be a test that needs a connection to say anything at all.
class _SilentCatalog extends CardCatalog {
  _SilentCatalog(this.game);

  @override
  final CardGame game;

  @override
  String get sourceName => 'silent';

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async =>
      const <String, TcgCard>{};

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

/// One browser: its own database, its own sync, the account it is signed in to,
/// and the watcher that keeps that account current.
class _Browser {
  _Browser({
    required this.db,
    required this.bootstrap,
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
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // A memory store rather than the keystore: the real one is a plugin, and a
    // plugin call in a test is a wait with nothing on the other end.
    final AppSettings settings = await AppSettings.load(
      secrets: MemorySecretStore(),
    );
    final AppDatabase db = await AppDatabase.openInMemory();
    final Bootstrap bootstrap = Bootstrap.create(
      database: db,
      settings: settings,
      catalogs: <CardGame, CardCatalog>{
        for (final CardGame game in CardGame.values) game: _SilentCatalog(game),
      },
    );
    final ProviderContainer scope = ProviderContainer(
      overrides: [bootstrapProvider.overrideWithValue(bootstrap)],
    );
    final CollectionSync sync = CollectionSync(table: account, db: db.db);
    final _Browser browser = _Browser(
      db: db,
      bootstrap: bootstrap,
      sync: sync,
      watcher: CollectionWatcher(
        sync: sync,
        signedIn: () => true,
        interval: interval,
      ),
      scope: scope,
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final Bootstrap bootstrap;
  final CollectionSync sync;
  final CollectionWatcher watcher;
  final ProviderContainer scope;

  CollectionDao get dao => CollectionDao(db.db);

  bool _givenUp = false;

  /// Signs in the way the gate does when a session appears, and then starts
  /// watching the way [main] does once that sign-in has settled.
  Future<void> signIn() async {
    await reconcileAccount(sync: sync, bootstrap: bootstrap, scope: scope);
    watcher.begin(scope);
  }

  /// Adds a stack, which is the door a collector uses most.
  Future<void> add(String cardId, {CardGame game = CardGame.mtg}) =>
      dao.addOrMerge(
        game: game,
        cardId: cardId,
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 1,
      );

  /// Removes every stack of a printing, which is the door the report came
  /// through the second time.
  Future<void> remove(String cardId, {CardGame game = CardGame.mtg}) async =>
      dao.deleteAllForCard(game, cardId);

  /// What this browser would show its owner.
  Future<Set<String>> owned({CardGame game = CardGame.mtg}) async => <String>{
    for (final CollectionEntry entry in await dao.all(game)) entry.cardId,
  };

  Future<void> close() async {
    if (_givenUp) return;
    _givenUp = true;
    watcher.end();
    // A pass that was already running when the tab went away would otherwise
    // finish against a database this is about to close. Ending the watch stops
    // new ones, and this is the moment the running one gets.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    scope.dispose();
    await db.close();
  }
}

/// Waits for something the app reaches on its own.
///
/// The alternative is a test that asserts against a machine's speed: a fixed
/// sleep is either a race or a waste, and this is neither.
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

  test('a card added here and a card removed here are both waiting on the '
      'account, without anybody signing out', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(
      account,
      interval: const Duration(milliseconds: 20),
    );
    await one.signIn();
    // The card the collector already had, so that there is one to remove.
    await one.add('lotus-1');
    await waitFor(
      () => account.live('lotus-1'),
      'the card that was already in the collection',
    );

    // Everything from here on is what the collector does with the browser they
    // are already signed in to. Nothing tells the app to sync.
    await one.add('bolt-1');
    await one.remove('lotus-1');

    await waitFor(() => account.live('bolt-1'), 'the card that was added');
    await waitFor(
      () => account.tombstoned('lotus-1'),
      'the card that was removed',
    );

    // The incognito window: a second database, the same account, and a sign-in
    // that is the only thing it has ever been told.
    final _Browser incognito = await _Browser.open(account);
    await incognito.signIn();

    expect(await incognito.owned(), <String>{
      'bolt-1',
    }, reason: 'the added card arrived and the removed one did not come back');
  });

  test('a minute of changing things is one trip, not a request a card', () async {
    // A collector sorting a box makes dozens of changes in a minute, and the
    // account they are signed in to must not hear about each of them - nor hear
    // nothing at all until they stop, since that would be the same bug with a
    // longer fuse for anybody watching a second browser.
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    final int before = account.pushes.length;

    for (var i = 0; i < 20; i++) {
      await one.add('card-$i');
    }
    expect(
      account.pushes.length,
      before,
      reason: 'twenty changes on their own sent nothing',
    );

    await one.watcher.flush();

    expect(account.pushes.length, before + 1, reason: 'one trip for twenty');
    expect(
      account.pushes.last.length,
      20,
      reason: 'carrying every one of them',
    );
  });

  test('a collection nobody has touched sends nothing at all', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    await one.add('lotus-1');
    await one.watcher.flush();
    final int settled = account.pushes.length;

    await one.watcher.flush();
    await one.watcher.flush();

    expect(
      account.pushes.length,
      settled,
      reason: 'a pass with nothing to carry is a query and no request',
    );
  });

  test('an edit made a moment before the tab goes away still travels', () async {
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    await one.add('bolt-1');

    // The framework's own path: the browser is told the tab is going away, and
    // a watcher that only knew about its timer would lose the work made in the
    // seconds before this.
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.hidden,
    );

    await waitFor(
      () => account.live('bolt-1'),
      'the last edit before the tab went',
    );
  });

  test('an edit here does not put back a card another browser removed', () async {
    // A whole-game push is blind, so a browser that has been sitting on a stale
    // copy of a card and then pushes everything clears the removal somebody
    // else made. Only the rows this device has actually changed travel, which
    // is what makes that impossible rather than unlikely.
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    await one.add('lotus-1');
    await one.watcher.flush();
    expect(account.live('lotus-1'), isTrue);

    // Another browser, gone from this test but not from the account: it removed
    // the card this one is still holding.
    await account.hears('lotus-1', removed: true);

    await one.add('bolt-1');
    await one.watcher.flush();

    expect(
      account.tombstoned('lotus-1'),
      isTrue,
      reason: 'the removal survived a push that had nothing to do with it',
    );
    expect(account.live('bolt-1'), isTrue);
  });

  test('a carry-up that failed reconciles before it writes again', () async {
    // A push that did not happen is a device that has stopped hearing what the
    // account holds, and the other browser may have changed the very card it is
    // about to write. The pass after a failure reads the account's copy first,
    // the way a sign-in does.
    final _Account account = _Account();
    final _Browser one = await _Browser.open(account);
    await one.signIn();
    await one.add('lotus-1');
    await one.watcher.flush();

    account.unreachable = true;
    await one.add('bolt-1');
    await one.watcher.flush();
    expect(
      account.live('bolt-1'),
      isFalse,
      reason: 'this browser could not reach the account',
    );

    account.unreachable = false;
    // What the other browser did while this one was not listening: it was never
    // offline, and it removed the card this one is still sitting on.
    await account.hears('lotus-1', removed: true);

    await one.watcher.flush();

    expect(account.live('bolt-1'), isTrue, reason: 'the work still arrived');
    expect(
      account.tombstoned('lotus-1'),
      isTrue,
      reason: 'and the removal it never saw was not written over',
    );
    expect(await one.owned(), isNot(contains('lotus-1')));
  });
}
