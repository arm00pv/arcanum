// What a collection that arrived without its catalogue does.
//
//   flutter test test/data/missing_cards_test.dart
//
// A collection travels as rows that name their cards by id, and the catalogue
// behind those ids is downloaded set by set. Signing in on a browser that has
// never opened a set therefore lands rows it cannot name, which is what a
// collection of "--" is. These tests cover the fetch that closes that gap:
// only what is missing, a few requests at a time, and never a failure that
// costs the rest of the collection.

import 'dart:async';

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

/// A provider that answers one printing at a time, counts what it was asked,
/// and can be made to wait - which is how "a few at a time" is checked rather
/// than assumed.
class _PacedCatalog implements CardCatalog {
  _PacedCatalog(this.game);

  @override
  final CardGame game;

  /// Every id asked for, in the order the requests were made.
  final List<String> asked = <String>[];

  /// How many requests have been started, and the most that were ever running
  /// at once.
  int started = 0;
  int peak = 0;

  /// Printings this provider answers with nothing, and ones it fails on.
  final Set<String> unknown = <String>{};
  final Set<String> failing = <String>{};

  /// Runs before a request answers, so a test can look at the database while
  /// the run is still going.
  Future<void> Function(String id)? onAsk;

  /// When true, a request waits for [release] instead of answering.
  bool holding = false;

  int _inFlight = 0;
  final List<Completer<void>> _gates = <Completer<void>>[];

  /// Lets every waiting request, and every one after it, answer.
  void release() {
    holding = false;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  @override
  String get sourceName => 'paced';

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    asked.add(id);
    started++;
    _inFlight++;
    if (_inFlight > peak) peak = _inFlight;

    await onAsk?.call(id);

    while (holding) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }

    _inFlight--;
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

/// Waits for the workers to reach a state, rather than guessing at a duration.
Future<void> _until(bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CatalogDao dao;
  late _PacedCatalog catalog;
  late CatalogRepository catalogs;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
    catalog = _PacedCatalog(CardGame.digimon);
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
    test('is not a few thousand requests at once', () async {
      catalog.holding = true;
      final ids = <String>[for (var i = 0; i < 12; i++) 'card-$i'];

      final pending = catalogs.resolveMissingCards(
        CardGame.digimon,
        ids,
        concurrency: 2,
      );

      await _until(() => catalog.started >= 2);
      expect(catalog.started, 2, reason: 'two workers, two requests');

      catalog.release();
      expect(await pending, 12);
      expect(catalog.peak, lessThanOrEqualTo(2));
    });

    test('is written as it arrives, not once at the end', () async {
      // Minutes of requests can end in a closed tab or an expired session, and
      // what did arrive should survive that.
      final ids = <String>[for (var i = 0; i < 250; i++) 'card-$i'];
      final storedWhenAsked = <int>[];
      catalog.onAsk = (String id) async =>
          storedWhenAsked.add(await dao.cardCount(CardGame.digimon));

      final resolved = await catalogs.resolveMissingCards(
        CardGame.digimon,
        ids,
        concurrency: 1,
      );

      expect(resolved, 250);
      expect(storedWhenAsked.first, 0);
      expect(
        storedWhenAsked[200],
        200,
        reason:
            'the first two hundred are on disk while the rest are asked for',
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
