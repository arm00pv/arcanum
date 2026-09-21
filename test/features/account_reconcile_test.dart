// What a sign-in does to the screens that were already drawn.
//
//   flutter test test/features/account_reconcile_test.dart
//
// The reconciliation is deliberately not awaited, so every screen drew itself
// against a database it had not touched yet - and a provider that has answered
// keeps that answer until somebody tells it the answer has moved. These tests
// are about that telling: a collection signed in to is shown without anybody
// pulling the list down, it is told when a game has landed rather than as its
// cards arrive, and a sync that failed leaves the screens exactly as they were.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/catalog_meta.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';
import 'package:arcanum/providers.dart';

/// One holding as the account sends it back.
Map<String, Object?> holding(
  String cardId, {
  CardGame game = CardGame.digimon,
  int quantity = 1,
}) => <String, Object?>{
  'card_id': cardId,
  'game': game.id,
  'finish': 'nonfoil',
  'condition': 'near_mint',
  'language': 'en',
  'quantity': quantity,
  'binder': '',
  'for_trade': false,
  'created_at': '2026-09-01T00:00:00.000Z',
  'updated_at': '2026-09-10T12:00:00.000Z',
};

/// An account that answers from memory, and can be told to stop answering.
class _Account implements AccountTable {
  _Account(this.steps);

  /// Every step of the sign-in this account took part in, in the order it
  /// started, shared with the catalogues: the order one sign-in works through
  /// the games is the whole question these tests ask, and a record each game
  /// keeps of itself cannot answer it.
  final List<String> steps;

  /// Everything this device has handed up, so a test can see that a browser's
  /// own cards travelled before the account's came down.
  final List<Map<String, Object?>> written = <Map<String, Object?>>[];

  /// What the account holds.
  List<Map<String, Object?>> remote = <Map<String, Object?>>[];

  /// A connection that dies between the sending and the receiving, which is the
  /// shape of most of the ways a sign-in's sync goes wrong.
  bool unreachable = false;

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async =>
      written.addAll(rows);

  @override
  Future<List<Map<String, Object?>>> fetch(CardGame game) async {
    steps.add('holdings:${game.id}');
    if (unreachable) throw Exception('the account did not answer');
    return <Map<String, Object?>>[
      for (final Map<String, Object?> row in remote)
        if (row['game'] == game.id) row,
    ];
  }
}

/// A catalogue with nothing clever to do with a list of ids: it asks about them
/// one at a time, which is what most of the games' sources do, and it answers
/// about every id it is given.
class _Catalog extends CardCatalog {
  _Catalog(this.game, this.steps);

  @override
  final CardGame game;

  /// The same log the account writes to, so a test can see a game's holdings
  /// and its cards against every other game's rather than only against its own.
  final List<String> steps;

  /// How many ids each request carried, in the order they were made.
  final List<List<String>> bulks = <List<String>>[];

  @override
  String get sourceName => 'test';

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) {
    steps.add('cards:${game.id}');
    bulks.add(List<String>.of(ids));
    return super.fetchCardsByIds(ids);
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async => TcgCard(
    game: game,
    id: id,
    setCode: 'BT26',
    setName: 'Timeless Bonds',
    name: 'Card $id',
    collectorNumber: '001',
    rarity: 'common',
  );

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

  /// The ids every price request carried, in the order the requests were made.
  ///
  /// Kept apart from [steps] rather than logged into it: the tests below count
  /// steps to say how many times a sign-in passed over the games, and a price
  /// request is not a pass - a game with holdings is priced and a game with none
  /// is not, and the count they assert is about the games.
  final List<List<String>> priced = <List<String>>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    priced.add(<String>[for (final TcgCard card in cards) card.id]);
    return cards;
  }
}

/// The server's `catalog_meta` table, as rows.
///
/// Handed to a browser that is to have the shared catalogue switched on, which
/// is what a row here means: the two are the same fact about a browser, and a
/// test that has a server to read from is a test of a browser that reads from it.
class _ServerMeta implements CatalogMetaTable {
  _ServerMeta(this.rows);

  /// The rows the table holds. A game absent from them is a game the table has
  /// no row for - which is how a game whose price import has never run looks,
  /// and is not the same as a row whose `prices_revision` is zero.
  final List<Map<String, Object?>> rows;

  @override
  Future<List<Map<String, Object?>>> meta() async => rows;
}

/// One row of `catalog_meta`, in the shape PostgREST answers `?select=*` with.
Map<String, Object?> metaRowFor(CardGame game, {int prices = 1}) =>
    <String, Object?>{
      'game': game.id,
      'sets_revision': 1,
      'prices_revision': prices,
      'set_count': 0,
      'card_count': 0,
      'sets_updated_at': null,
      'prices_observed_on': prices > 0 ? '2026-09-21' : null,
      'last_import_ok': true,
      'last_import_note': null,
      'source': 'lorcast',
    };

/// A screen that was already drawn when the account began to arrive.
///
/// It listens the way a screen does - which is what keeps the provider alive
/// and what a stale answer is a stale answer to - and remembers every answer it
/// has been handed since. Being handed the answer it already has is a refresh
/// and not a new one, so it is not counted: what is counted here is how often
/// the list a collector is looking at is rebuilt.
class _Screen<T> {
  _Screen(ProviderContainer scope, FutureProvider<T> provider) {
    _watch = scope.listen(provider, (
      AsyncValue<T>? previous,
      AsyncValue<T> next,
    ) {
      final T? answer = next.value;
      if (answer == null) return;
      if (answers.isNotEmpty && identical(answers.last, answer)) return;
      answers.add(answer);
    });
  }

  /// Every answer the screen has been given, oldest first.
  final List<T> answers = <T>[];

  late final ProviderSubscription<AsyncValue<T>> _watch;

  /// What the screen is showing now.
  T get showing => answers.last;

  void close() => _watch.close();
}

/// One browser: its own database, a catalogue that answers, the account it is
/// signed in to, and the providers a screen would be reading.
class _Browser {
  _Browser({
    required this.db,
    required this.bootstrap,
    required this.sync,
    required this.account,
    required this.catalogs,
    required this.steps,
    required this.scope,
  });

  /// Opens a browser that has just signed in to an empty account.
  ///
  /// [server] is the shared catalogue's own table, and passing one is what
  /// makes this browser a browser with the shared catalogue switched on: the
  /// revision reads are gated by that switch, so a test of what the server's
  /// revisions do has to say the browser may read them.
  static Future<_Browser> open({_ServerMeta? server}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // A memory store rather than the keystore: the real one is a plugin, and a
    // plugin call in a test is a wait with nothing on the other end.
    final AppSettings settings = await AppSettings.load(
      secrets: MemorySecretStore(),
    );
    final AppDatabase db = await AppDatabase.openInMemory();
    final List<String> steps = <String>[];
    final _Account account = _Account(steps);
    // Every game gets a catalogue, because a browser has a source to ask for
    // any of them and a game with no source at all is another test's question.
    final Map<CardGame, _Catalog> catalogs = <CardGame, _Catalog>{
      for (final CardGame game in CardGame.values) game: _Catalog(game, steps),
    };
    final Bootstrap bootstrap = Bootstrap.create(
      database: db,
      settings: settings,
      catalogs: catalogs,
      sharedCatalogMeta: server,
      sharedCatalogAllowed: server == null ? null : () => true,
    );
    final ProviderContainer scope = ProviderContainer(
      overrides: [bootstrapProvider.overrideWithValue(bootstrap)],
    );
    final _Browser browser = _Browser(
      db: db,
      bootstrap: bootstrap,
      sync: CollectionSync(table: account, db: db.db),
      account: account,
      catalogs: catalogs,
      steps: steps,
      scope: scope,
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final Bootstrap bootstrap;
  final CollectionSync sync;
  final _Account account;

  /// What each game's source had to answer, so a test can see how a run was
  /// sliced rather than assume it.
  final Map<CardGame, _Catalog> catalogs;

  /// Every step of the sign-in so far, in the order it started, as
  /// "holdings:gundam" and "cards:gundam". Two steps per game at most, so a
  /// game that ran twice - the thing a reordered loop can quietly do - says so
  /// twice here.
  final List<String> steps;

  final ProviderContainer scope;

  bool _givenUp = false;

  /// Gives the browser up, so that a test weighing two of them gets two.
  /// sqflite hands the same in-memory database to a second open of the same
  /// path while the first is still open, and a comparison against the browser
  /// that just signed in would be a comparison against itself.
  Future<void> close() async {
    if (_givenUp) return;
    _givenUp = true;
    scope.dispose();
    await db.close();
  }

  /// Reconciles the way the gate does when a session appears - started and not
  /// waited for, which is how it runs in the app.
  Future<void> signIn() =>
      reconcileAccount(sync: sync, bootstrap: bootstrap, scope: scope);

  /// Puts [printings] holdings of one game straight into the browser, which is
  /// what a browser that has used the app before already has.
  Future<void> holds(CardGame game, int printings) async {
    final Batch batch = db.db.batch();
    for (var i = 0; i < printings; i++) {
      batch.insert('collection_entries', <String, Object?>{
        'game': game.id,
        'card_id': 'card-$i',
        'finish': 'nonfoil',
        'condition': 'near_mint',
        'language': 'en',
        'quantity': 1,
        'binder': '',
        'created_at': 1,
        'updated_at': 1,
      });
    }
    await batch.commit(noResult: true);
  }

  /// Waits for one game's collection, and for whatever a screen was told about
  /// it to have reached the screen.
  Future<void> settleCollection(CardGame game) async {
    await scope.read(collectionOverviewProvider(game).future);
    await Future<void>.delayed(Duration.zero);
  }

  /// The same for the card data behind a game's collection.
  Future<void> settleCards(CardGame game) async {
    await scope.read(ownedCardsProvider(game).future);
    await Future<void>.delayed(Duration.zero);
  }
}

/// What a collection of [printings] cards costs the list showing it: how many
/// chunks the catalogue had to answer it in, how many times the list was handed
/// a new answer while it did, and how much of the collection it can name at the
/// end.
///
/// The browser already holds every one of those printings and none of their
/// catalogue data, which is the browser that has just signed in.
Future<({int chunks, int rebuilds, int named})> rebuildsFor(
  int printings,
) async {
  final _Browser browser = await _Browser.open();
  await browser.holds(CardGame.digimon, printings);
  final _Screen<Map<String, TcgCard>> list = _Screen<Map<String, TcgCard>>(
    browser.scope,
    ownedCardsProvider(CardGame.digimon),
  );
  await browser.settleCards(CardGame.digimon);
  final int drawn = list.answers.length;

  await browser.signIn();
  await browser.settleCards(CardGame.digimon);

  final int rebuilt = list.answers.length - drawn;
  final int chunks = browser.catalogs[CardGame.digimon]!.bulks.length;
  final int named = list.showing.length;
  list.close();
  await browser.close();
  return (chunks: chunks, rebuilds: rebuilt, named: named);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('a collection that arrives on sign-in', () {
    test('is shown without anybody pulling the list down', () async {
      final _Browser browser = await _Browser.open();
      // The screen drew itself before any of the account had landed, so what it
      // is holding is the empty vault this browser had a moment ago.
      final _Screen<CollectionOverview> digimon = _Screen<CollectionOverview>(
        browser.scope,
        collectionOverviewProvider(CardGame.digimon),
      );
      final _Screen<CollectionOverview> magic = _Screen<CollectionOverview>(
        browser.scope,
        collectionOverviewProvider(CardGame.mtg),
      );
      await browser.settleCollection(CardGame.digimon);
      await browser.settleCollection(CardGame.mtg);
      expect(digimon.showing.totalCards, 0);

      browser.account.remote = <Map<String, Object?>>[
        holding('card-a', quantity: 2),
        holding('card-b', game: CardGame.mtg),
      ];
      await browser.signIn();
      await browser.settleCollection(CardGame.digimon);
      await browser.settleCollection(CardGame.mtg);

      expect(digimon.showing.totalCards, 2, reason: 'nobody pulled it down');
      expect(digimon.showing.entries.single.entry.cardId, 'card-a');
      // Every game and not only the one that was on screen: a collector who
      // switches games finds the account there too.
      expect(magic.showing.totalCards, 1);
    });

    test('is named once the cards behind it arrive', () async {
      // The report this whole thing exists for: rows that arrive from the
      // account name their cards by id, and a browser that has never downloaded
      // those sets can only show them as "--".
      final _Browser browser = await _Browser.open();
      browser.account.remote = <Map<String, Object?>>[
        holding('card-a'),
        holding('card-b'),
        holding('card-c'),
      ];
      final _Screen<Map<String, TcgCard>> list = _Screen<Map<String, TcgCard>>(
        browser.scope,
        ownedCardsProvider(CardGame.digimon),
      );
      await browser.settleCards(CardGame.digimon);
      expect(list.showing, isEmpty);

      await browser.signIn();
      await browser.settleCards(CardGame.digimon);

      expect(list.showing.keys, containsAll(<String>['card-a', 'card-c']));
      expect(list.showing['card-a']!.name, 'Card card-a');
    });

    test('is rebuilt when a game lands, not as its cards arrive', () async {
      // A collection arrives in chunks of a couple of hundred, and a list
      // rebuilt for each of them is a list nobody can read while it flickers.
      // What a screen is told must therefore not grow with the collection.
      final ({int chunks, int rebuilds, int named}) light = await rebuildsFor(
        250,
      );
      final ({int chunks, int rebuilds, int named}) heavy = await rebuildsFor(
        2500,
      );

      expect(
        heavy.chunks,
        greaterThan(light.chunks),
        reason: 'the heavier collection really did arrive in more chunks',
      );
      expect(light.named, 250);
      expect(heavy.named, 2500, reason: 'and is named in the end either way');
      expect(
        heavy.rebuilds,
        light.rebuilds,
        reason: 'the same few answers, however many chunks it came in',
      );
      expect(
        light.rebuilds,
        lessThan(4),
        reason: 'a couple, not one per chunk',
      );
    });

    test('asks for the prices the server has moved, and only there', () async {
      // Section 6's client trigger. A launch on which the server has rewritten a
      // game's prices has to reach the screens without waiting for the
      // dashboard's daily snapshot, which is one game, one day, and only for a
      // collector who opened that screen - so a browser that never opened it
      // never learned about a moved price at all.
      //
      // That the request happens at all is also the ordering: a price is written
      // onto a row, the rows here arrived from the download above in this same
      // pass, and a refresh asked for before that download would have found
      // nothing to ask about.
      final _Browser browser = await _Browser.open(
        server: _ServerMeta(<Map<String, Object?>>[
          metaRowFor(CardGame.lorcana, prices: 4),
        ]),
      );
      await browser.holds(CardGame.lorcana, 3);
      await browser.holds(CardGame.gundam, 2);
      await browser.holds(CardGame.mtg, 1);

      await browser.signIn();
      for (final CardGame game in <CardGame>[
        CardGame.lorcana,
        CardGame.gundam,
        CardGame.mtg,
      ]) {
        await browser.settleCards(game);
      }

      expect(
        browser.catalogs[CardGame.lorcana]!.priced.expand((ids) => ids),
        containsAll(<String>['card-0', 'card-1', 'card-2']),
        reason: 'the rows were there because the download had stored them',
      );
      // Two ways of being a game a launch does not price, and both are the
      // server's own answer rather than a guess about it: Gundam is a game the
      // server holds and quotes no price for, and Magic is a game the server
      // does not hold at all. Asking either one's provider is what the daily
      // snapshot is for; asking on every page load is the storm the price read
      // warns callers about, and a browser holds cards in several games at once.
      expect(
        browser.catalogs[CardGame.gundam]!.priced,
        isEmpty,
        reason: 'no revision for a game the server quotes no prices for',
      );
      expect(
        browser.catalogs[CardGame.mtg]!.priced,
        isEmpty,
        reason: 'the server does not hold Magic, so a launch does not price it',
      );
    });

    test('is left exactly as it was when the sync fails', () async {
      final _Browser browser = await _Browser.open();
      await browser.holds(CardGame.digimon, 2);
      final _Screen<CollectionOverview> digimon = _Screen<CollectionOverview>(
        browser.scope,
        collectionOverviewProvider(CardGame.digimon),
      );
      await browser.settleCollection(CardGame.digimon);
      expect(digimon.showing.totalCards, 2);

      browser.account.unreachable = true;
      // Not thrown, either: there is nothing a collector could usefully do
      // about a sync that did not happen, and a vault that still opens is the
      // whole point of keeping one on the device.
      await browser.signIn();
      await browser.settleCollection(CardGame.digimon);

      expect(digimon.showing.totalCards, 2, reason: 'what it already held');
      // The account is merged in before anything is pushed, so a push waits for
      // the connection it needs rather than racing one. Nothing is written here
      // - and nothing is lost either: the rows are still on this browser, and
      // the first sync that reaches the account carries them up.
      expect(
        browser.account.written.length,
        0,
        reason: 'a push waits for a connection rather than racing one',
      );
      expect(
        browser.scope.read(collectionOverviewProvider(CardGame.digimon)),
        isA<AsyncData<CollectionOverview>>(),
        reason: 'a sync that failed is not a collection that failed',
      );
    });
  });

  group('the order a sign-in works through the games', () {
    /// One holding for every game, which is the account a collector signs in to
    /// when they own cards in more than one.
    List<Map<String, Object?>> holdingInEveryGame() => <Map<String, Object?>>[
      for (final CardGame game in CardGame.values)
        holding('card-${game.id}', game: game),
    ];

    test('begins with the game on screen, wherever it sits in the list', () async {
      // The report this exists for: Gundam is last in CardGame.values and Magic
      // is first, so a Gundam collector signing in on a browser that had never
      // seen their cards watched the account's holdings for eight other games
      // land - and then eight other catalogue downloads finish - with nothing
      // on their own screen the whole time.
      final _Browser browser = await _Browser.open();
      browser.bootstrap.settings.activeGame = CardGame.gundam;
      browser.account.remote = holdingInEveryGame();

      await browser.signIn();

      expect(
        browser.steps.first,
        'holdings:gundam',
        reason: 'the first question the sign-in asked was about Gundam',
      );
      final int cards = browser.steps.indexOf('cards:gundam');
      expect(
        browser.steps.firstWhere((step) => step.startsWith('cards:')),
        'cards:gundam',
        reason: 'and the first download it started was Gundam\'s',
      );
      for (final CardGame other in CardGame.values) {
        if (other == CardGame.gundam) continue;
        expect(
          browser.steps.indexOf('cards:${other.id}'),
          greaterThan(cards),
          reason: '${other.id} waited behind the game on screen',
        );
      }
    });

    test('is two passes over every game and no game twice', () async {
      // A rotation and not a second list: leading with one game is worth
      // nothing if it means fetching another game twice, and a collector whose
      // account is a few thousand cards notices a game reconciled twice.
      final _Browser browser = await _Browser.open();
      browser.bootstrap.settings.activeGame = CardGame.gundam;
      browser.account.remote = holdingInEveryGame();

      await browser.signIn();

      expect(
        browser.steps.length,
        CardGame.values.length * 2,
        reason: 'every game in both passes, and nothing besides',
      );
      expect(
        browser.steps.toSet().length,
        browser.steps.length,
        reason: 'no game was worked through twice for leading the queue',
      );
    });

    test(
      'is left alone when the collector is already on the first game',
      () async {
        // Magic is the default, so the common case must be exactly what it was:
        // nine games' holdings in the catalogue's own order, then nine games'
        // cards in the same order.
        final _Browser browser = await _Browser.open();
        expect(
          browser.bootstrap.settings.activeGame,
          CardGame.mtg,
          reason: 'the game an install that has never chosen one is on',
        );
        browser.account.remote = holdingInEveryGame();

        await browser.signIn();

        expect(browser.steps, <String>[
          for (final CardGame game in CardGame.values) 'holdings:${game.id}',
          for (final CardGame game in CardGame.values) 'cards:${game.id}',
        ]);
      },
    );
  });
}
