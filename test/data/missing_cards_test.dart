// What a collection that arrived without its catalogue does.
//
//   flutter test test/data/missing_cards_test.dart
//
// A collection travels as rows that name their cards by id, and the catalogue
// behind those ids is downloaded set by set. Signing in on a browser that has
// never opened a set therefore lands rows it cannot name, which is what a
// collection of "--" is. These tests cover the fetch that closes that gap:
// only what is missing, handed to the catalogue in bulks rather than one card
// at a time, and never a failure that costs the rest of the collection.

import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TcgCard _card(String id) => TcgCard(
  game: CardGame.digimon,
  id: id,
  setCode: 'BT26',
  setName: 'Timeless Bonds',
  name: 'Card $id',
  collectorNumber: '001',
  rarity: 'common',
);

/// A provider with nothing cheaper to offer for a list of ids than one request
/// per id, which is exactly what the body [CardCatalog] gives it does with
/// them. It records what it was asked, and in what bulks, so that a test can
/// see how a run was sliced rather than assume it.
class _OneAtATimeCatalog extends CardCatalog {
  _OneAtATimeCatalog(this.game);

  @override
  final CardGame game;

  /// Every id asked for, in the order the requests were made.
  final List<String> asked = <String>[];

  /// The ids of every bulk call, in the order the run made them.
  final List<List<String>> bulks = <List<String>>[];

  /// Printings this provider answers with nothing, and ones it fails on.
  final Set<String> unknown = <String>{};
  final Set<String> failing = <String>{};

  /// Runs before a request answers, so a test can look at the database while
  /// the run is still going.
  Future<void> Function(String id)? onAsk;

  @override
  String get sourceName => 'one-at-a-time';

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) {
    bulks.add(List<String>.of(ids));
    return super.fetchCardsByIds(ids);
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    asked.add(id);
    await onAsk?.call(id);

    if (failing.contains(id)) throw const CatalogException('no answer');
    if (unknown.contains(id)) return null;
    return _card(id);
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

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CatalogDao dao;
  late _OneAtATimeCatalog catalog;
  late CatalogRepository catalogs;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
    catalog = _OneAtATimeCatalog(CardGame.digimon);
    catalogs = CatalogRepository(
      catalogs: <CardGame, CardCatalog>{CardGame.digimon: catalog},
      dao: dao,
    );
  });

  tearDown(() async => db.close());

  group('a collection whose cards are not on this device', () {
    test('is fetched, and can be named afterwards', () async {
      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        <String>['card-a', 'card-b', 'card-c'],
      );

      expect(resolved, 3);
      final stored = await dao.cardsByIds(CardGame.digimon, <String>[
        'card-a',
        'card-b',
        'card-c',
      ]);
      expect(stored.keys.toSet(), <String>{'card-a', 'card-b', 'card-c'});
      expect(stored['card-a']!.name, 'Card card-a');
      expect(catalog.asked.toSet(), <String>{'card-a', 'card-b', 'card-c'});
    });

    test(
      'is asked about once per printing, however often it is named',
      () async {
        // A collection holds the same printing in several finishes, binders and
        // conditions, and every one of those rows names the same card.
        final resolved = await catalogs.resolveMissingCards(
          CardGame.digimon,
          <String>['card-a', 'card-a', 'card-b'],
        );

        expect(resolved, 2);
        expect(catalog.asked.length, 2);
      },
    );

    test('leaves the printings it already has alone', () async {
      await dao.upsertCards(CardGame.digimon, <TcgCard>[_card('card-a')]);

      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        <String>['card-a', 'card-b'],
      );

      expect(resolved, 1);
      expect(catalog.asked, <String>['card-b']);
    });

    test('is not asked about at all when nothing is missing', () async {
      await dao.upsertCards(CardGame.digimon, <TcgCard>[_card('card-a')]);

      expect(
        await catalogs.resolveMissingCards(CardGame.digimon, <String>[
          'card-a',
        ]),
        0,
      );
      expect(
        await catalogs.resolveMissingCards(CardGame.digimon, <String>[]),
        0,
      );
      expect(catalog.asked, isEmpty, reason: 'no request was worth making');
    });

    test('is left alone for a game with no catalogue to ask', () async {
      // The account is per game and the browser may hold holdings for one
      // Arcanum has no source for; that is not a failure, it is nothing to do.
      expect(
        await catalogs.resolveMissingCards(CardGame.mtg, <String>['lotus-1']),
        0,
      );
      expect(catalog.asked, isEmpty);
    });
  });

  group('a collection of a few thousand cards', () {
    test('is handed to the catalogue in bulks, not a card at a time', () async {
      final ids = <String>[for (var i = 0; i < 250; i++) 'card-$i'];

      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        ids,
      );

      expect(resolved, 250);
      // What a bulk costs is the catalogue's to decide - a set at a time for
      // the games whose ids carry their set - and it can only decide it if it
      // is handed more than one id. Two hundred is where a run is written, so
      // it is also where a run is asked.
      expect(catalog.bulks.map((List<String> bulk) => bulk.length), <int>[
        200,
        50,
      ]);
      expect(catalog.bulks.first.first, 'card-0');
      expect(catalog.bulks.last.last, 'card-249');
      // Every one of them still reaches the source, in the order the collection
      // held them.
      expect(catalog.asked.length, 250);
    });

    test('is written as it arrives, not once at the end', () async {
      // Minutes can end in a closed tab or an expired session, and what did
      // arrive should survive that.
      final ids = <String>[for (var i = 0; i < 250; i++) 'card-$i'];
      final storedWhenAsked = <int>[];
      catalog.onAsk = (String id) async =>
          storedWhenAsked.add(await dao.cardCount(CardGame.digimon));

      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        ids,
      );

      expect(resolved, 250);
      expect(storedWhenAsked.first, 0);
      expect(
        storedWhenAsked[200],
        200,
        reason: 'the first bulk is on disk before the second is asked for',
      );
    });

    test('keeps the cards that did resolve when one cannot', () async {
      catalog.unknown.add('card-b');
      catalog.failing.add('card-c');

      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        <String>['card-a', 'card-b', 'card-c', 'card-d'],
      );

      expect(resolved, 2);
      final stored = await dao.cardsByIds(CardGame.digimon, <String>[
        'card-a',
        'card-b',
        'card-c',
        'card-d',
      ]);
      expect(stored.keys.toSet(), <String>{'card-a', 'card-d'});
      // A card nobody could answer for is asked again next time rather than
      // remembered as unanswerable.
      expect(catalog.asked.toSet(), <String>{
        'card-a',
        'card-b',
        'card-c',
        'card-d',
      });
    });
  });

  group('what the catalogue says it is missing', () {
    test('is right across the boundary the query is chunked at', () async {
      final ids = <String>[for (var i = 0; i < 500; i++) 'card-$i'];
      await dao.upsertCards(CardGame.digimon, <TcgCard>[
        for (var i = 100; i < 160; i++) _card('card-$i'),
      ]);

      final missing = await dao.missingCardIds(CardGame.digimon, ids);

      expect(missing.length, 440);
      expect(missing.first, 'card-0');
      expect(missing.contains('card-100'), isFalse);
      expect(missing.contains('card-499'), isTrue);
    });
  });
}
