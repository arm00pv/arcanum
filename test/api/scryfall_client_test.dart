// Real-network verification tests for the Scryfall API client.
//
//   flutter test test/api
//
// These hit https://api.scryfall.com for real. If the machine has no network
// access to api.scryfall.com they are reported as skipped instead of failing.
// (`dart test` cannot run this file: the project depends on flutter_test, not
// package:test - see the report accompanying this change.)

import 'dart:io';

import 'package:arcanum/data/api/scryfall_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Oracle id of "The Legend of Yangchen // Avatar Yangchen" (tla/27).
const String kYangchenOracleId = '521a63cf-5e83-4649-9800-c62b2fc474d6';

Future<bool> hasNetwork() async {
  try {
    final Socket socket = await Socket.connect(
      'api.scryfall.com',
      443,
      timeout: const Duration(seconds: 10),
    );
    socket.destroy();
    return true;
  } on Object {
    return false;
  }
}

Future<void> main() async {
  final bool online = await hasNetwork();
  final Object skip = online
      ? false
      : 'no network access to api.scryfall.com';

  late final ScryfallClient client;
  setUpAll(() {
    client = ScryfallClient();
  });
  tearDownAll(() {
    client.close(force: true);
  });

  // -------------------------------------------------------------------------
  // Pure model tests - these run offline.
  // -------------------------------------------------------------------------

  group('models', () {
    test('single-faced card round-trips through fromJson/toJson', () {
      final Map<String, dynamic> json = <String, dynamic>{
        'object': 'card',
        'id': '5e51f727-5a9b-4bc7-83a9-dbcf1c933e15',
        'oracle_id': 'ddf461b9-a205-4dc7-a9c3-c047b1ff709f',
        'name': "Aang's Journey",
        'lang': 'en',
        'released_at': '2025-11-21',
        'layout': 'normal',
        'mana_cost': '{2}',
        'cmc': 2.0,
        'type_line': 'Sorcery - Lesson',
        'oracle_text': 'Search your library for a basic land card.',
        'colors': <String>[],
        'color_identity': <String>[],
        'set': 'tla',
        'set_name': 'Avatar: The Last Airbender',
        'collector_number': '1',
        'digital': false,
        'rarity': 'common',
        'artist': 'Kotakan',
        'full_art': false,
        'booster': true,
        'reprint': false,
        'reserved': false,
        'promo': false,
        'foil': true,
        'nonfoil': true,
        'edhrec_rank': 4599,
        'scryfall_uri': 'https://scryfall.com/card/tla/1/aangs-journey',
        'uri': 'https://api.scryfall.com/cards/5e51f727-5a9b-4bc7-83a9-dbcf1c933e15',
        'set_uri': 'https://api.scryfall.com/sets/118f7e64-5caa-4cb7-99a8-184f4d3a7422',
        'rulings_uri':
            'https://api.scryfall.com/cards/5e51f727-5a9b-4bc7-83a9-dbcf1c933e15/rulings',
        'image_uris': <String, String>{
          'small': 'https://cards.scryfall.io/small/front/5/e/x.jpg',
          'normal': 'https://cards.scryfall.io/normal/front/5/e/x.jpg',
          'large': 'https://cards.scryfall.io/large/front/5/e/x.jpg',
          'png': 'https://cards.scryfall.io/png/front/5/e/x.png',
          'art_crop': 'https://cards.scryfall.io/art_crop/front/5/e/x.jpg',
          'border_crop': 'https://cards.scryfall.io/border_crop/front/5/e/x.jpg',
        },
        'prices': <String, dynamic>{
          'usd': '0.23',
          'usd_foil': '0.29',
          'usd_etched': null,
          'eur': '0.07',
          'eur_foil': '0.20',
          'tix': '0.03',
        },
      };

      final ScryfallCard card = ScryfallCard.fromJson(json);
      expect(card.id, '5e51f727-5a9b-4bc7-83a9-dbcf1c933e15');
      expect(card.name, "Aang's Journey");
      expect(card.setCode, 'tla');
      expect(card.setName, 'Avatar: The Last Airbender');
      expect(card.collectorNumber, '1');
      expect(card.collectorNumberSortKey, 1);
      expect(card.rarity, 'common');
      expect(card.layout, 'normal');
      expect(card.cmc, 2.0);
      expect(card.releasedAt, DateTime(2025, 11, 21));
      expect(card.edhrecRank, 4599);
      expect(card.faces, isEmpty);
      expect(card.prices.usd, 0.23);
      expect(card.prices.usdEtched, isNull);
      expect(card.imageUrl(), 'https://cards.scryfall.io/normal/front/5/e/x.jpg');
      expect(card.imageUrl(size: 'png'), 'https://cards.scryfall.io/png/front/5/e/x.png');
      expect(card.imageUrl(size: 'art_crop'), contains('art_crop'));

      final Map<String, dynamic> encoded = card.toJson();
      expect(encoded['set'], 'tla');
      expect(encoded['collector_number'], '1');
      expect(encoded['released_at'], '2025-11-21');

      final ScryfallCard again = ScryfallCard.fromJson(encoded);
      expect(again.id, card.id);
      expect(again.name, card.name);
      expect(again.setCode, card.setCode);
      expect(again.collectorNumber, card.collectorNumber);
      expect(again.prices.usd, card.prices.usd);
      expect(again.imageUris, card.imageUris);
      expect(again.colors, card.colors);
      expect(again.releasedAt, card.releasedAt);
    });

    test('multi-faced card keeps image_uris empty and falls back to faces', () {
      // Shape copied from the real GET /cards/tla/27 response.
      final Map<String, dynamic> json = <String, dynamic>{
        'object': 'card',
        'id': 'a60e8f23-90b2-4bc6-bd54-a95055556389',
        'oracle_id': kYangchenOracleId,
        'name': 'The Legend of Yangchen // Avatar Yangchen',
        'layout': 'transform',
        'cmc': 5.0,
        'type_line': 'Enchantment - Saga // Legendary Creature - Avatar',
        'color_identity': <String>['W'],
        'set': 'tla',
        'set_name': 'Avatar: The Last Airbender',
        'collector_number': '27',
        'rarity': 'mythic',
        'digital': false,
        'artist': 'Kuno',
        'prices': <String, dynamic>{'usd': '4.44', 'usd_foil': '5.46'},
        'card_faces': <Map<String, dynamic>>[
          <String, dynamic>{
            'object': 'card_face',
            'name': 'The Legend of Yangchen',
            'mana_cost': '{3}{W}{W}',
            'type_line': 'Enchantment - Saga',
            'oracle_text': 'I - ...',
            'colors': <String>['W'],
            'artist': 'Kuno',
            'image_uris': <String, String>{
              'small': 'https://cards.scryfall.io/small/front/a/6/y.jpg',
              'normal': 'https://cards.scryfall.io/normal/front/a/6/y.jpg',
              'large': 'https://cards.scryfall.io/large/front/a/6/y.jpg',
              'png': 'https://cards.scryfall.io/png/front/a/6/y.png',
            },
          },
          <String, dynamic>{
            'object': 'card_face',
            'name': 'Avatar Yangchen',
            'mana_cost': '',
            'type_line': 'Legendary Creature - Avatar',
            'oracle_text': 'Flying',
            'flavor_text': 'Selfless duty calls you.',
            'colors': <String>[],
            'artist': 'Kuno',
            'image_uris': <String, String>{
              'small': 'https://cards.scryfall.io/small/back/a/6/y.jpg',
              'normal': 'https://cards.scryfall.io/normal/back/a/6/y.jpg',
              'large': 'https://cards.scryfall.io/large/back/a/6/y.jpg',
            },
          },
        ],
      };

      final ScryfallCard card = ScryfallCard.fromJson(json);
      expect(card.layout, 'transform');
      expect(card.isMultiFaced, isTrue);
      expect(card.imageUris, isEmpty, reason: 'DFCs have no top-level image_uris');
      expect(card.faces, hasLength(2));
      expect(card.manaCost, isNull, reason: 'mana cost lives on the faces');
      expect(card.oracleText, isNull);
      expect(card.colors, <String>['W'], reason: 'rolled up from the faces');

      expect(card.imageUrl(), contains('/front/'));
      expect(card.imageUrl(face: 1), contains('/back/'));
      expect(card.imageUrl(size: 'png'), contains('/front/'));
      expect(card.imageUrl(face: 1, size: 'large'), contains('/back/'));
      // Unknown face index falls back to the front rather than crashing.
      expect(card.imageUrl(face: 9), contains('/front/'));
      // A size that only exists on the back face is still found.
      expect(card.faces[1].imageUrl(size: 'normal'), contains('/back/'));
    });

    test('prices fall back usd -> usd_foil -> usd_etched', () {
      const ScryfallPrices all = ScryfallPrices(
        usd: 1,
        usdFoil: 2,
        usdEtched: 3,
      );
      expect(all.priceFor(), 1);
      expect(all.priceFor(foil: true), 2);
      expect(all.priceFor(etched: true), 3);

      const ScryfallPrices foilOnly = ScryfallPrices(usdFoil: 2, usdEtched: 3);
      expect(foilOnly.priceFor(), 2, reason: 'falls back to the foil price');
      expect(foilOnly.priceFor(foil: true), 2);
      expect(foilOnly.priceFor(etched: true), 3);

      const ScryfallPrices etchedOnly = ScryfallPrices(usdEtched: 3);
      expect(etchedOnly.priceFor(), 3);
      expect(etchedOnly.priceFor(foil: true), 3);
      expect(etchedOnly.priceFor(etched: true), 3);

      expect(ScryfallPrices.empty.priceFor(), isNull);
      expect(ScryfallPrices.empty.isEmpty, isTrue);
      expect(
        ScryfallPrices.fromJson(<String, dynamic>{'usd': '0.23', 'tix': null}).usd,
        0.23,
      );
      expect(
        ScryfallPrices.fromJson(<String, dynamic>{'usd': ''}).usd,
        isNull,
      );
    });

    test('non-numeric collector numbers sort to the end', () {
      const ScryfallCard numeric = ScryfallCard(
        id: 'a',
        name: 'A',
        setCode: 'tla',
        setName: 'T',
        collectorNumber: '42',
        rarity: 'common',
        layout: 'normal',
      );
      const ScryfallCard starred = ScryfallCard(
        id: 'b',
        name: 'B',
        setCode: 'tla',
        setName: 'T',
        collectorNumber: '★',
        rarity: 'common',
        layout: 'normal',
      );
      const ScryfallCard suffixed = ScryfallCard(
        id: 'c',
        name: 'C',
        setCode: 'tla',
        setName: 'T',
        collectorNumber: '1a',
        rarity: 'common',
        layout: 'normal',
      );

      expect(numeric.collectorNumberSortKey, 42);
      expect(starred.collectorNumberSortKey,
          ScryfallCard.nonNumericCollectorNumberSortKey);
      expect(suffixed.collectorNumberSortKey,
          ScryfallCard.nonNumericCollectorNumberSortKey);

      final List<ScryfallCard> cards = <ScryfallCard>[starred, numeric, suffixed];
      cards.sort((ScryfallCard a, ScryfallCard b) =>
          a.collectorNumberSortKey.compareTo(b.collectorNumberSortKey));
      expect(cards.first.collectorNumber, '42');
      expect(cards.last.collectorNumberSortKey,
          ScryfallCard.nonNumericCollectorNumberSortKey);
    });

    test('set objects round-trip and tolerate missing optional keys', () {
      final ScryfallSet set = ScryfallSet.fromJson(<String, dynamic>{
        'object': 'set',
        'id': '118f7e64-5caa-4cb7-99a8-184f4d3a7422',
        'code': 'tla',
        'name': 'Avatar: The Last Airbender',
        'uri': 'https://api.scryfall.com/sets/118f7e64',
        'scryfall_uri': 'https://scryfall.com/sets/tla',
        'search_uri': 'https://api.scryfall.com/cards/search?q=e%3Atla',
        'released_at': '2025-11-21',
        'set_type': 'expansion',
        'card_count': 394,
        'digital': false,
        'nonfoil_only': false,
        'foil_only': false,
        'icon_svg_uri': 'https://svgs.scryfall.io/sets/tla.svg',
      });
      expect(set.code, 'tla');
      expect(set.displayCode, 'TLA');
      expect(set.setType, 'expansion');
      expect(set.cardCount, 394);
      expect(set.releasedAt, DateTime(2025, 11, 21));
      expect(set.collectorNumberStart, isNull);
      expect(set.toJson()['released_at'], '2025-11-21');

      final ScryfallSet sparse = ScryfallSet.fromJson(<String, dynamic>{});
      expect(sparse.code, isEmpty);
      expect(sparse.cardCount, 0);
      expect(sparse.iconSvgUri, isNull);
      expect(sparse.releasedAt, isNull);
    });
  });

  /// Declares a test that is skipped when api.scryfall.com is unreachable.
  void liveTest(String description, Future<void> Function() body) {
    test(description, body, skip: skip);
  }

  // -------------------------------------------------------------------------
  // Live network tests.
  // -------------------------------------------------------------------------

  group('live: /sets', () {
    liveTest('fetchAllSets returns every set, each with a code, name and icon',
        () async {
      final List<ScryfallSet> sets = await client.fetchAllSets();

      expect(sets.length, greaterThan(250));

      for (final ScryfallSet set in sets) {
        expect(set.code, isNotEmpty, reason: 'set ${set.id} has no code');
        expect(set.name, isNotEmpty, reason: 'set ${set.code} has no name');
        expect(set.setType, isNotEmpty);
        expect(set.id, isNotEmpty);
      }

      final int withIcon =
          sets.where((ScryfallSet s) => (s.iconSvgUri ?? '').isNotEmpty).length;
      expect(
        withIcon / sets.length,
        greaterThan(0.9),
        reason: 'most sets should publish an iconSvgUri',
      );

      final int withDate =
          sets.where((ScryfallSet s) => s.releasedAt != null).length;
      expect(withDate / sets.length, greaterThan(0.9));

      final ScryfallSet tla = sets.firstWhere((ScryfallSet s) => s.code == 'tla');
      expect(tla.name, 'Avatar: The Last Airbender');
      expect(tla.setType, 'expansion');
      expect(tla.cardCount, greaterThan(0));
      expect(tla.iconSvgUri, startsWith('https://'));
      expect(tla.searchUri, isNotNull);
      expect(tla.releasedAt, isNotNull);
    });

    liveTest('the set list is cached for the lifetime of the client', () async {
      final List<ScryfallSet> first = await client.fetchAllSets();
      expect(client.hasCachedSets, isTrue);
      final List<ScryfallSet> second = await client.fetchAllSets();
      expect(identical(first, second), isTrue,
          reason: 'the cached list must be handed back without a request');
    });
  });

  group('live: /cards/search pagination', () {
    liveTest('searchCards exposes has_more / next_page / total_cards', () async {
      final ScryfallSearchResult page1 = await client.searchCards(
        'set:tla',
        order: 'set',
        unique: false,
        page: 1,
      );

      expect(page1.cards, hasLength(175), reason: 'Scryfall pages 175 cards');
      expect(page1.hasMore, isTrue);
      expect(page1.totalCards, greaterThan(300));
      expect(page1.nextPage, isNotNull);
      expect(page1.nextPage, contains('page=2'));

      final ScryfallSearchResult page2 = await client.searchCards(
        'set:tla',
        order: 'set',
        unique: false,
        page: 2,
      );
      expect(page2.cards, hasLength(175));
      expect(page2.totalCards, page1.totalCards);
      expect(page2.cards.first.collectorNumber, '176');

      // unique:true is Scryfall's "cards" rollup; tla collapses below the
      // number of printings.
      final ScryfallSearchResult rolled = await client.searchCards('set:tla');
      expect(rolled.totalCards, lessThanOrEqualTo(page1.totalCards));
    });
  });

  group('live: /cards/search?q=set:<code>', () {
    liveTest('fetchCardsInSet("tla") returns every card sorted by collector number',
        () async {
      final List<({int done, int total})> progress =
          <({int done, int total})>[];
      final List<ScryfallCard> cards = await client.fetchCardsInSet(
        'tla',
        onProgress: (int done, int total) => progress.add((done: done, total: total)),
      );

      expect(cards.length, greaterThan(300));
      expect(progress, isNotEmpty, reason: 'progress must stream per page');
      expect(progress.last.done, cards.length);
      expect(progress.last.total, cards.length,
          reason: 'every page was followed');

      for (final ScryfallCard card in cards) {
        expect(card.setCode, 'tla');
        expect(card.name, isNotEmpty);
        expect(card.collectorNumber, isNotEmpty);
        expect(card.rarity, isNotEmpty);
        final String? url = card.imageUrl();
        expect(url, isNotNull,
            reason: 'no image for ${card.setCode}/${card.collectorNumber}');
        expect(url, startsWith('https://'));
      }

      final List<int> keys =
          cards.map((ScryfallCard c) => c.collectorNumberSortKey).toList();
      final List<int> sorted = List<int>.of(keys)..sort();
      expect(keys, sorted, reason: 'cards must be sorted by collector number');
      expect(cards.first.collectorNumber, '1');

      final Set<String> ids = cards.map((ScryfallCard c) => c.id).toSet();
      expect(ids, hasLength(cards.length), reason: 'no duplicate printings');
    });
  });

  group('live: double-faced cards', () {
    liveTest('a DFC resolved by set+number gets its image from card_faces', () async {
      final ScryfallCard? card =
          await client.fetchCardBySetAndNumber('tla', '27');

      expect(card, isNotNull);
      expect(card!.layout, 'transform');
      expect(card.name, contains('//'));
      expect(card.faces, hasLength(2));
      expect(card.imageUris, isEmpty,
          reason: 'the API omits top-level image_uris for transform cards');

      final String? front = card.imageUrl();
      final String? back = card.imageUrl(face: 1);
      expect(front, isNotNull);
      expect(back, isNotNull);
      expect(front, contains('/front/'));
      expect(back, contains('/back/'));
      expect(front, startsWith('https://cards.scryfall.io/'));
      expect(card.imageUrl(size: 'png'), contains('.png'));
    });

    liveTest('a well-known DFC (isd/51 Delver of Secrets) also resolves', () async {
      final ScryfallCard? card =
          await client.fetchCardBySetAndNumber('isd', '51');
      expect(card, isNotNull);
      expect(card!.name, 'Delver of Secrets // Insectile Aberration');
      expect(card.imageUris, isEmpty);
      expect(card.imageUrl(), contains('/front/'));
      expect(card.imageUrl(face: 1), contains('/back/'));
    });

    liveTest('every DFC found by is:dfc resolves an image', () async {
      final ScryfallSearchResult result =
          await client.searchCards('set:tla is:dfc', unique: false);
      expect(result.cards, isNotEmpty);
      for (final ScryfallCard card in result.cards) {
        expect(card.imageUris, isEmpty);
        expect(card.faces, isNotEmpty);
        expect(card.imageUrl(), isNotNull,
            reason: 'no image for ${card.setCode}/${card.collectorNumber}');
        expect(card.imageUrl(face: 1), isNotNull);
      }
    });
  });

  group('live: single card lookups', () {
    liveTest('fetchCardBySetAndNumber + fetchCardById, with LRU caching', () async {
      final ScryfallCard? byNumber =
          await client.fetchCardBySetAndNumber('TLA', '1');
      expect(byNumber, isNotNull);
      expect(byNumber!.collectorNumber, '1');
      expect(byNumber.setCode, 'tla');
      expect(byNumber.oracleId, isNotNull);
      expect(client.cardCacheSize, greaterThan(0));

      final int cacheBefore = client.cardCacheSize;
      final ScryfallCard? byId = await client.fetchCardById(byNumber.id);
      expect(byId, isNotNull);
      expect(byId!.id, byNumber.id);
      expect(byId.name, byNumber.name);
      expect(client.cardCacheSize, cacheBefore,
          reason: 'the id lookup must be served from the LRU cache');
    });

    liveTest('a missing printing returns null instead of throwing', () async {
      final ScryfallCard? card =
          await client.fetchCardBySetAndNumber('tla', '99999');
      expect(card, isNull);

      final ScryfallCard? byId =
          await client.fetchCardById('00000000-0000-0000-0000-000000000000');
      expect(byId, isNull);
    });
  });

  group('live: /cards/collection', () {
    liveTest('fetchCollection resolves identifiers and skips not_found ones',
        () async {
      final List<ScryfallCard> cards = await client.fetchCollection(
        <ScryfallCardIdentifier>[
          (setCode: 'tla', collectorNumber: '1'),
          (setCode: 'tla', collectorNumber: '27'),
          (setCode: 'zzz', collectorNumber: '99999'),
        ],
      );

      expect(cards, hasLength(2));
      expect(
        cards.map((ScryfallCard c) => c.collectorNumber).toSet(),
        <String>{'1', '27'},
      );
      expect(
        cards.firstWhere((ScryfallCard c) => c.collectorNumber == '27').faces,
        hasLength(2),
      );
    });

    liveTest('more than 75 identifiers are chunked across multiple requests',
        () async {
      final List<ScryfallCardIdentifier> ids =
          List<ScryfallCardIdentifier>.generate(
        76,
        (int index) => (setCode: 'tla', collectorNumber: '${index + 1}'),
      );
      final List<ScryfallCard> cards = await client.fetchCollection(ids);
      expect(cards, hasLength(76));
      expect(
        cards.map((ScryfallCard c) => c.id).toSet(),
        hasLength(76),
      );
      expect(cards.map((ScryfallCard c) => c.collectorNumber).toSet(),
          hasLength(76));
    });
  });

  group('live: rate limiting', () {
    liveTest('concurrent calls are serialised with the documented gaps',
        () async {
      // /cards/:id is a "10 requests/second" endpoint.
      final Stopwatch fast = Stopwatch()..start();
      await Future.wait(<Future<ScryfallCard?>>[
        for (int i = 0; i < 4; i++)
          client.fetchCardById('00000000-0000-0000-0000-00000000000$i'),
      ]);
      fast.stop();
      expect(
        fast.elapsedMilliseconds,
        greaterThanOrEqualTo(300),
        reason: '4 concurrent lookups must be spaced by 3 x 100 ms',
      );

      // /cards/search is limited to 2 requests/second (500 ms).
      final Stopwatch slow = Stopwatch()..start();
      await Future.wait(<Future<ScryfallSearchResult>>[
        for (int page = 1; page <= 3; page++)
          client.searchCards('set:tla', order: 'set', unique: false, page: page),
      ]);
      slow.stop();
      expect(
        slow.elapsedMilliseconds,
        greaterThanOrEqualTo(1000),
        reason: '3 concurrent searches must be spaced by 2 x 500 ms',
      );
    });
  });

  group('live: oracle id printings', () {
    liveTest('fetchCardsByOracleId returns every printing of a card', () async {
      final List<ScryfallCard> cards =
          await client.fetchCardsByOracleId(kYangchenOracleId);
      expect(cards, isNotEmpty);
      for (final ScryfallCard card in cards) {
        expect(card.oracleId, kYangchenOracleId);
        expect(card.imageUrl(), isNotNull);
      }
      expect(cards.map((ScryfallCard c) => c.setCode).toSet().length,
          greaterThanOrEqualTo(1));
    });
  });
}