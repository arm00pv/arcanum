// The default a catalogue is handed when it has nothing cheaper to offer.
//
//   flutter test test/catalog/card_catalog_test.dart
//
// Only the tcgcsv catalogue overrides fetchCardsByIds. The other four sources,
// and every test double in this repository, inherit the body on [CardCatalog],
// which asks one id at a time - and that body is what answers a browser's first
// sign-in for those games. These tests hold it to what its callers rely on:
// every id is asked about once, a printing nobody can answer for is left out
// rather than turned into a failure, and an empty list is not a request.
//
// The number lookup is the second body [CardCatalog] carries, and no source
// overrides it at all. It answers nothing, and the last group here is what says
// so: a provider that was asked for a collector number would answer a word
// search, and the phone's search has never taken that road.

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

/// A source whose ids share nothing it could exploit: one request per id, which
/// is exactly the case the inherited body exists for.
class _OneAtATimeCatalog extends CardCatalog {
  _OneAtATimeCatalog();

  @override
  final CardGame game = CardGame.mtg;

  @override
  String get sourceName => 'one-at-a-time';

  /// Every id asked about, in the order the requests were made.
  final List<String> asked = <String>[];

  /// Printings this source has no answer for, and ones it cannot answer for.
  final Set<String> unknown = <String>{};
  final Set<String> failing = <String>{};

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    asked.add(id);
    if (failing.contains(id)) throw const CatalogException('no answer');
    if (unknown.contains(id)) return null;
    return TcgCard(
      game: game,
      id: id,
      setCode: 'lea',
      setName: 'Limited Edition Alpha',
      name: 'Card $id',
      collectorNumber: '001',
      rarity: 'common',
    );
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
  late _OneAtATimeCatalog catalog;

  setUp(() => catalog = _OneAtATimeCatalog());

  group('a source that has to answer one id at a time', () {
    test('answers every id it is given, keyed by that id', () async {
      final cards = await catalog.fetchCardsByIds(<String>['a', 'b', 'c']);

      expect(catalog.asked, <String>['a', 'b', 'c']);
      expect(cards.keys, <String>['a', 'b', 'c']);
      expect(cards['b']!.name, 'Card b');
    });

    test('leaves out a printing it has no answer for', () async {
      catalog.unknown.add('b');

      final cards = await catalog.fetchCardsByIds(<String>['a', 'b', 'c']);

      // A printing nobody can answer for is absent rather than wrong: the ids
      // that were answered are the keys that are there, and all three were
      // still asked about.
      expect(cards.keys, <String>['a', 'c']);
      expect(catalog.asked, <String>['a', 'b', 'c']);
    });

    test('does not lose the rest when one id cannot be answered', () async {
      // A shop that fails one request has not failed the list, and the caller
      // is filling in rows that already exist: a card nobody could fetch is a
      // placeholder that stays a placeholder rather than a run that ends.
      catalog.failing.add('b');

      final cards = await catalog.fetchCardsByIds(<String>['a', 'b', 'c']);

      expect(cards.keys, <String>['a', 'c']);
    });

    test('is not asked anything at all for an empty list', () async {
      expect(await catalog.fetchCardsByIds(const <String>[]), isEmpty);
      expect(catalog.asked, isEmpty);
    });
  });

  group('a source whose search takes words', () {
    test(
      'answers a collector number with nothing, and makes no request',
      () async {
        // The phone's behaviour, and it is deliberate rather than unfinished:
        // CatalogDao.searchByNumber owns the number grammar and the local cache
        // owns the answer, so a provider is never asked a question it would
        // answer with every card that mentions "001".
        expect(
          await catalog.fetchCardsByNumber(CollectorQuery.parse('001')!),
          isEmpty,
        );
        expect(catalog.asked, isEmpty);
      },
    );

    test('does not become a name search when the query names a set', () async {
      final CollectorQuery? parsed = CollectorQuery.parse('BT-26-001');
      expect(parsed, isNotNull);

      expect(await catalog.fetchCardsByNumber(parsed!), isEmpty);
      expect(catalog.asked, isEmpty);
    });
  });
}
