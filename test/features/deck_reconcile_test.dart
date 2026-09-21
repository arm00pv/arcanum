// What a sign-in does with decks, and what it does without them.
//
//   flutter test test/features/deck_reconcile_test.dart
//
// Two facts, and the second is the one the whole design turns on. A browser that
// signs in gets its decks and its deck's cards: the lines name printings the
// device may never have downloaded, and the same catalogue pass that resolves a
// collection resolves them. A device with no deck sync - a phone, which has no
// account and keeps its decks to itself - gets nothing at all: the deck half of
// the reconciliation is absent there rather than present and skipped, so nothing
// about the account's decks can reach it.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/data/sync/collection_sync.dart';
import 'package:arcanum/data/sync/deck_sync.dart';
import 'package:arcanum/data/sync/deck_table.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/auth/account_reconcile.dart';
import 'package:arcanum/providers.dart';

/// The account's decks, as a browser that has just signed in would find them.
class _DeckAccount implements DeckTable {
  final List<Map<String, Object?>> deckRows = <Map<String, Object?>>[];
  final List<Map<String, Object?>> lineRows = <Map<String, Object?>>[];

  @override
  Future<void> upsertDecks(List<Map<String, Object?>> rows) async {}

  @override
  Future<void> upsertLines(List<Map<String, Object?>> rows) async {}

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
}

/// A collection the account does not have, so that the pass under test is the
/// deck one.
class _EmptyCollection implements AccountTable {
  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {}

  @override
  Future<List<Map<String, Object?>>> fetch(CardGame game) async =>
      const <Map<String, Object?>>[];
}

/// A catalogue that answers nothing and remembers what it was asked about.
///
/// A real provider here would be a test that needs a connection to say anything,
/// and what is being asked is not what a card is - it is whether the printings a
/// pulled line names had their cards fetched at all.
class _Catalog extends CardCatalog {
  _Catalog(this.game);

  @override
  final CardGame game;

  final List<String> asked = <String>[];

  @override
  String get sourceName => 'silent';

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    asked.addAll(ids);
    return const <String, TcgCard>{};
  }

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

/// The account's copy of one deck and two lines of it.
_DeckAccount _deckedAccount() => _DeckAccount()
  ..deckRows.add(<String, Object?>{
    'game': 'mtg',
    'sync_id': 'deck-uuid',
    'name': 'Krenko',
    'format_id': 'commander',
    'notes': null,
    'name_at': '2026-09-10T12:00:00.000Z',
    'format_at': '2026-09-10T12:00:00.000Z',
    'notes_at': null,
    'deleted_at': null,
    'created_at': '2026-09-01T00:00:00.000Z',
    'updated_at': '2026-09-10T12:00:00.000Z',
  })
  ..lineRows.addAll(<Map<String, Object?>>[
    <String, Object?>{
      'game': 'mtg',
      'deck_sync_id': 'deck-uuid',
      'card_id': 'goblin-chieftain',
      'board': 'main',
      'quantity': 4,
      'sort': 0,
      'category': '',
      'deleted_at': null,
      'updated_at': '2026-09-10T12:00:00.000Z',
    },
    <String, Object?>{
      'game': 'mtg',
      'deck_sync_id': 'deck-uuid',
      'card_id': 'mogg-war-marshal',
      'board': 'side',
      'quantity': 1,
      'sort': 1,
      'category': '',
      'deleted_at': null,
      'updated_at': '2026-09-10T12:00:00.000Z',
    },
  ]);

/// One browser, opened the way `main` opens it.
class _Browser {
  _Browser(this.db, this.bootstrap, this.catalogs, this.scope);

  static Future<_Browser> open() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // A memory store rather than the keystore: the real one is a plugin, and a
    // plugin call in a test is a wait with nothing on the other end.
    final AppSettings settings = await AppSettings.load(
      secrets: MemorySecretStore(),
    );
    final AppDatabase db = await AppDatabase.openInMemory(own: true);
    final Map<CardGame, _Catalog> catalogs = <CardGame, _Catalog>{
      for (final CardGame game in CardGame.values) game: _Catalog(game),
    };
    final Bootstrap bootstrap = Bootstrap.create(
      database: db,
      settings: settings,
      catalogs: catalogs,
    );
    final _Browser browser = _Browser(
      db,
      bootstrap,
      catalogs,
      ProviderContainer(
        overrides: [bootstrapProvider.overrideWithValue(bootstrap)],
      ),
    );
    addTearDown(browser.close);
    return browser;
  }

  final AppDatabase db;
  final Bootstrap bootstrap;
  final Map<CardGame, _Catalog> catalogs;
  final ProviderContainer scope;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    scope.dispose();
    await db.close();
  }

  /// The cards the catalogue was asked about for one game.
  List<String> askedFor(CardGame game) => catalogs[game]!.asked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('a sign-in brings the decks down and fetches the cards they name', () async {
    final _Browser browser = await _Browser.open();
    final _EmptyCollection collection = _EmptyCollection();
    final DeckSync decks = DeckSync(
      table: _deckedAccount(),
      db: browser.db.db,
    );

    await reconcileAccount(
      sync: CollectionSync(table: collection, db: browser.db.db),
      decks: decks,
      bootstrap: browser.bootstrap,
      scope: browser.scope,
    );

    final Deck deck = (await DeckDao(browser.db.db).decks(CardGame.mtg)).single;
    expect(deck.name, 'Krenko');
    expect(deck.cardCount, 4);
    expect(deck.sideboardCount, 1);
    expect(
      browser.askedFor(CardGame.mtg),
      containsAll(<String>['goblin-chieftain', 'mogg-war-marshal']),
      reason: 'a line names a printing, and a screen can only draw a card',
    );
  });

  test('a device with no deck sync is handed nothing, whatever the account holds', () async {
    // The phone. It has no account, it is handed no DeckSync, and the branch
    // that would have pulled the account's decks is one it does not enter - so
    // no deck of anybody else's can appear in its list, and no deck of its own
    // can leave it.
    final _Browser browser = await _Browser.open();
    final _DeckAccount account = _deckedAccount();
    expect(account.deckRows, hasLength(1), reason: 'the account does hold one');

    await reconcileAccount(
      sync: CollectionSync(table: _EmptyCollection(), db: browser.db.db),
      bootstrap: browser.bootstrap,
      scope: browser.scope,
    );

    expect(await DeckDao(browser.db.db).decks(CardGame.mtg), isEmpty);
    expect(browser.askedFor(CardGame.mtg), isEmpty);
  });
}
