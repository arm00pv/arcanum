// Tests for the YGOPRODeck catalogue adapter.
//
//   flutter test test/catalog/ygo_catalog_test.dart
//
// Nothing here touches the network. The adapter takes a Dio instance, so the
// tests hand it one backed by an adapter that serves canned payloads and
// answers HTTP 400 - the way the real API answers an unknown query - for
// anything a test did not route.
//
// The fixtures are trimmed slices of live cardinfo.php and cardsets.php
// responses, kept deliberately awkward: two set codes that Konami reuses, one
// card printed twice inside a single set under one collector code, region
// letters in the middle of a collector code, prices that are all strings, and
// "0.00" where the provider holds no market data. Those are the cases the
// adapter exists to absorb.

import 'dart:typed_data';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/ygo_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The set list, as cardsets.php publishes it: a bare array, and with "LOB"
/// used by two genuinely different sets.
const String setsJson = '''
[
  {"set_name":"Legend of Blue Eyes White Dragon","set_code":"LOB",
   "num_of_cards":355,"tcg_date":"2002-03-08",
   "set_image":"https://images.ygoprodeck.com/images/sets/LOB.jpg"},
  {"set_name":"Legend of Blue Eyes White Dragon (25th Anniversary Edition)",
   "set_code":"LOB","num_of_cards":14,"tcg_date":"2023-04-20",
   "set_image":"https://images.ygoprodeck.com/images/sets/LOB.jpg"},
  {"set_name":"Starter Deck: Kaiba","set_code":"SDK","num_of_cards":60,
   "tcg_date":"2002-03-29"},
  {"set_name":"Quarter Century Bonanza","set_code":"RA03","num_of_cards":100,
   "tcg_date":"2024-11-14"}
]
''';

/// Blue-Eyes White Dragon: a monster with real prices, printed in three sets,
/// twice inside one of them under two different region codes.
const String blueEyesJson = '''
{"id":89631139,"name":"Blue-Eyes White Dragon",
 "typeline":["Dragon","Normal"],"type":"Normal Monster",
 "humanReadableCardType":"Normal Monster","frameType":"normal",
 "desc":"This legendary dragon is a powerful engine of destruction.",
 "race":"Dragon","atk":3000,"def":2500,"level":8,"attribute":"LIGHT",
 "archetype":"Blue-Eyes",
 "ygoprodeck_url":"https://ygoprodeck.com/card/blue-eyes-white-dragon-7485",
 "card_sets":[
   {"set_name":"Legend of Blue Eyes White Dragon","set_code":"LOB-EN001",
    "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"62.15"},
   {"set_name":"Legend of Blue Eyes White Dragon","set_code":"LOB-001",
    "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"62.15"},
   {"set_name":"Legend of Blue Eyes White Dragon (25th Anniversary Edition)",
    "set_code":"LOB-EN001","set_rarity":"Quarter Century Secret Rare",
    "set_rarity_code":"","set_price":"0"},
   {"set_name":"Starter Deck: Kaiba","set_code":"SDK-001",
    "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"25.60"}
 ],
 "card_images":[{"id":89631139,
   "image_url":"https://images.ygoprodeck.com/images/cards/89631139.jpg",
   "image_url_small":"https://images.ygoprodeck.com/images/cards_small/89631139.jpg",
   "image_url_cropped":"https://images.ygoprodeck.com/images/cards_cropped/89631139.jpg"}],
 "card_prices":[{"cardmarket_price":"0.08","tcgplayer_price":"0.13",
   "ebay_price":"5.95","amazon_price":"3.90","coolstuffinc_price":"0.99"}]}
''';

/// Monster Reborn, a Spell card: no "attribute" key at all, no usable TCGplayer
/// price, and a collector code with a leading zero.
const String monsterRebornJson = '''
{"id":83764718,"name":"Monster Reborn","type":"Spell Card",
 "humanReadableCardType":"Spell Card","frameType":"spell","race":"Normal",
 "desc":"Target 1 monster in either GY; Special Summon it.",
 "ygoprodeck_url":"https://ygoprodeck.com/card/monster-reborn-1519",
 "card_sets":[
   {"set_name":"Legend of Blue Eyes White Dragon","set_code":"LOB-EN053",
    "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"0"}
 ],
 "card_images":[{"id":83764718,
   "image_url":"https://images.ygoprodeck.com/images/cards/83764718.jpg",
   "image_url_small":"https://images.ygoprodeck.com/images/cards_small/83764718.jpg",
   "image_url_cropped":"https://images.ygoprodeck.com/images/cards_cropped/83764718.jpg"}],
 "card_prices":[{"cardmarket_price":"0.05","tcgplayer_price":"0.00",
   "ebay_price":"1.50","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';

/// Dark Magician as the provider lists it on a rarity-collection set: the same
/// collector code twice at two rarities, and no usable price in any currency.
const String darkMagicianJson = '''
{"id":46986414,"name":"Dark Magician","typeline":["Spellcaster","Normal"],
 "type":"Normal Monster","humanReadableCardType":"Normal Monster",
 "frameType":"normal","desc":"The ultimate wizard in terms of attack and defense.",
 "race":"Spellcaster","atk":2500,"def":2100,"level":7,"attribute":"DARK",
 "archetype":"Dark Magician",
 "card_sets":[
   {"set_name":"Quarter Century Bonanza","set_code":"RA03-EN079",
    "set_rarity":"Platinum Secret Rare","set_rarity_code":"(PS)","set_price":"0"},
   {"set_name":"Quarter Century Bonanza","set_code":"RA03-EN079",
    "set_rarity":"Quarter Century Secret Rare","set_rarity_code":"","set_price":"0"}
 ],
 "card_prices":[{"cardmarket_price":"0.00","tcgplayer_price":"0.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';

/// A card the fuzzy name search returns but which is a different card.
const String decoyJson = '''
{"id":21082814,"name":"Blue-Eyes Ultimate Dragon",
 "type":"Fusion Monster","humanReadableCardType":"Fusion Monster",
 "frameType":"fusion","attribute":"LIGHT","desc":"Three Blue-Eyes fused.",
 "card_sets":[{"set_name":"Starter Deck: Kaiba","set_code":"SDK-001",
   "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"0"}],
 "card_prices":[{"cardmarket_price":"0.00","tcgplayer_price":"0.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';

/// Wraps card objects in the data array every cardinfo.php answer uses.
String cardData(List<String> cards) {
  final joined = cards.join(',');
  return '{"data":[$joined]}';
}

/// Serves canned payloads in place of the network.
class _FakeYgoApi implements HttpClientAdapter {
  _FakeYgoApi(this._respond, this.requests);

  /// Answers one request with a JSON body, or with null for the provider's
  /// HTTP 400 "nothing matched".
  final String? Function(Uri uri) _respond;

  /// Every URI the adapter was asked for, so a test can prove which endpoint -
  /// and which set name - the catalogue actually used.
  final List<Uri> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final headers = <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    };
    final body = _respond(uri);
    if (body == null) {
      return ResponseBody.fromString(
        '{"error":"No card matching your query was found in the database."}',
        400,
        headers: headers,
      );
    }
    return ResponseBody.fromString(body, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a catalogue wired to those payloads.
///
/// [requests] receives every URI asked for; it fills up as the test runs.
YgoCatalog catalogWith({
  String setsBody = setsJson,
  Map<String, String> bySetName = const <String, String>{},
  Map<String, String> byId = const <String, String>{},
  String? byFname,
  String? byDesc,
  List<Uri>? requests,
}) {
  final log = requests ?? <Uri>[];
  final dio = Dio(BaseOptions(baseUrl: 'https://db.ygoprodeck.com/api/v7'));
  dio.httpClientAdapter = _FakeYgoApi((Uri uri) {
    final query = uri.queryParameters;
    if (uri.path.endsWith('/cardsets.php')) return setsBody;
    if (query.containsKey('cardset')) return bySetName[query['cardset']];
    if (query.containsKey('id')) return byId[query['id']];
    // A search asks twice: once for names, once for effect text.
    if (query.containsKey('fname')) return byFname;
    if (query.containsKey('desc')) return byDesc;
    return null;
  }, log);
  return YgoCatalog(dio: dio);
}

/// The LOB payload: the two cards that really are in that set.
final String lobBody = cardData(<String>[blueEyesJson, monsterRebornJson]);

void main() {
  group('set list', () {
    test('reads sets with their published codes, names and release dates',
        () async {
      final sets = await catalogWith().fetchAllSets();

      expect(sets, hasLength(4));
      expect(sets.map((s) => s.game).toSet(), <CardGame>{CardGame.yugioh});
      expect(sets[0].name, 'Legend of Blue Eyes White Dragon');
      expect(sets[0].releasedAt, DateTime(2002, 3, 8));
      expect(sets[0].cardCount, 355);
      expect(sets[0].setType, 'set');
      expect(
        sets[0].logoUri,
        'https://images.ygoprodeck.com/images/sets/LOB.jpg',
      );
    });

    test('keeps every set when Konami reuses a set code', () async {
      final sets = await catalogWith().fetchAllSets();

      // The app stores sets keyed by code, so a shared code would otherwise
      // overwrite one set with another and lose it from the catalogue.
      expect(sets.map((s) => s.code).toSet(), hasLength(sets.length));
      expect(sets.map((s) => s.code), <String>['lob', 'lob2', 'sdk', 'ra03']);
    });

    test('offers no symbol and no logo the provider never published', () async {
      final sets = await catalogWith().fetchAllSets();

      expect(sets.every((s) => s.iconSvgUri == null), isTrue);
      expect(sets.last.logoUri, isNull);
    });
  });

  group('cards in a set', () {
    test('queries by set name and derives collector numbers from the codes',
        () async {
      final requests = <Uri>[];
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
        requests: requests,
      );

      final cards = await catalog.fetchCardsInSet('lob');

      // The provider rejects a set code and accepts only the set's name. The
      // log also holds the set-list read that made that lookup possible.
      final asked = requests
          .where((Uri uri) => uri.queryParameters.containsKey('cardset'))
          .toList();
      expect(
        asked.single.queryParameters['cardset'],
        'Legend of Blue Eyes White Dragon',
      );

      final blueEyes =
          cards.where((c) => c.name == 'Blue-Eyes White Dragon').toList();
      expect(blueEyes, hasLength(2));
      // "LOB-EN001" and "LOB-001" are both number 001: the letters in the
      // middle name a region, not a position.
      expect(blueEyes.map((c) => c.collectorNumber).toSet(), <String>{'001'});
      expect(blueEyes.every((c) => c.setCode == 'lob'), isTrue);
      expect(
        blueEyes.every((c) => c.setName == 'Legend of Blue Eyes White Dragon'),
        isTrue,
      );
      // Two printings of one card must never share a catalogue id.
      expect(blueEyes.map((c) => c.id).toSet(), hasLength(2));

      final reborn = cards.firstWhere((c) => c.name == 'Monster Reborn');
      expect(reborn.collectorNumber, '053');
      expect(reborn.rarity, 'Ultra Rare');
      expect(reborn.game, CardGame.yugioh);
    });

    test('keeps one card printed twice in a set at two rarities', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Quarter Century Bonanza': cardData(<String>[darkMagicianJson]),
        },
      );

      final cards = await catalog.fetchCardsInSet('ra03');

      expect(cards, hasLength(2));
      expect(cards.map((c) => c.collectorNumber).toSet(), <String>{'079'});
      expect(
        cards.map((c) => c.rarity).toSet(),
        <String>{'Platinum Secret Rare', 'Quarter Century Secret Rare'},
      );
      expect(cards.map((c) => c.id).toSet(), hasLength(2));
    });

    test('gives a reprinted set its own code, not the original\'s', () async {
      final requests = <Uri>[];
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon (25th Anniversary Edition)':
              cardData(<String>[blueEyesJson]),
        },
        requests: requests,
      );

      final cards = await catalog.fetchCardsInSet('lob2');

      final asked = requests
          .where((Uri uri) => uri.queryParameters.containsKey('cardset'))
          .toList();
      expect(
        asked.single.queryParameters['cardset'],
        'Legend of Blue Eyes White Dragon (25th Anniversary Edition)',
      );
      // Only the anniversary printing belongs in this set: the card is also
      // printed in the 2002 set that shares its code.
      expect(cards, hasLength(1));
      expect(cards.single.setCode, 'lob2');
      expect(cards.single.rarity, 'Quarter Century Secret Rare');
    });

    test('carries the artwork, stats and text the provider publishes', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final card = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Blue-Eyes White Dragon');

      expect(card.imageUris['small'], contains('cards_small'));
      expect(card.imageUris['art_crop'], contains('cards_cropped'));
      expect(card.extras['passcode'], 89631139);
      expect(card.extras['atk'], 3000);
      expect(card.extras['def'], 2500);
      expect(card.extras['level'], 8);
      expect(card.extras['frameType'], 'normal');
      expect(card.oracleText, contains('legendary dragon'));
    });
  });

  group('prices', () {
    test('puts the TCGplayer USD figure on the non-foil finish', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final card = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Blue-Eyes White Dragon');

      // The printing's own figure, not the card's. The card-level block quotes
      // TCGplayer at 0.13, but that is the cheapest version of Blue-Eyes
      // anywhere; this row is the LOB Ultra Rare, which the provider prices at
      // 62.15. Using the card-level number here is what valued a 62-dollar
      // printing at thirteen cents.
      expect(card.prices.priceFor(CardFinish.nonfoil), 62.15);
      expect(card.prices.byFinish.keys, <String>[CardFinish.nonfoil.code]);
      // No foil price was published, so none is invented.
      expect(card.prices.priceFor(CardFinish.foil), isNull);
      // Cardmarket is the one EUR figure in the block: kept, and labelled.
      expect(card.prices.eur, 0.08);
      expect(card.prices.byFinish.containsKey('eur'), isFalse);
      expect(card.prices.secondary['ebay'], 5.95);
      expect(card.prices.secondary['coolstuffinc'], 0.99);
    });

    test('prefers the printing price over the card price', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final cards = await catalog.fetchCardsInSet('lob');

      // Both LOB printings carry their own set_price of 62.15 while the card
      // block says 0.13, so every printing must come out at 62.15.
      final blueEyes = cards.where((c) => c.name == 'Blue-Eyes White Dragon');
      expect(blueEyes, isNotEmpty);
      for (final card in blueEyes) {
        expect(card.prices.priceFor(CardFinish.nonfoil), 62.15);
      }
    });

    test('gives two rarities of one card their own prices', () async {
      const twoRarities = '''
{"id":55555555,"name":"Twin Rarity","type":"Effect Monster",
 "humanReadableCardType":"Effect Monster","frameType":"effect",
 "desc":"Test.","race":"Warrior","atk":1000,"def":1000,"level":4,
 "attribute":"DARK",
 "card_sets":[
   {"set_name":"Starter Deck: Kaiba","set_code":"SDK-010",
    "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"74.49"},
   {"set_name":"Starter Deck: Kaiba","set_code":"SDK-010",
    "set_rarity":"Secret Rare","set_rarity_code":"(ScR)","set_price":"27.92"}],
 "card_prices":[{"cardmarket_price":"0.10","tcgplayer_price":"0.14",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Starter Deck: Kaiba': cardData(<String>[twoRarities]),
        },
      );

      final cards = await catalog.fetchCardsInSet('sdk');
      final prices = <String, double?>{
        for (final card in cards)
          card.rarity: card.prices.priceFor(CardFinish.nonfoil),
      };

      // This is the whole point: one card, one collector number, two rarities,
      // and the two are worth different money rather than the same 0.14.
      expect(prices['Ultra Rare'], 74.49);
      expect(prices['Secret Rare'], 27.92);
    });

    test('falls back to the card price when the row has none', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      // The 25th Anniversary printing carries set_price "0", which the provider
      // uses for "no market data yet", so the card-level figure stands in
      // rather than the printing going unpriced.
      final reborn = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Monster Reborn');
      expect(reborn.prices.priceFor(CardFinish.nonfoil), 1.50);
    });

    test('falls back to another USD vendor only when TCGplayer is empty',
        () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final spell = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Monster Reborn');

      expect(spell.prices.priceFor(CardFinish.nonfoil), 1.50);
      expect(spell.prices.eur, 0.05);
    });

    test('reads "0.00" as no market data rather than as a free card', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Quarter Century Bonanza': cardData(<String>[darkMagicianJson]),
        },
      );

      final card = (await catalog.fetchCardsInSet('ra03')).first;

      expect(card.prices.isEmpty, isTrue);
      expect(card.prices.from, isNull);
      expect(card.prices.priceFor(CardFinish.nonfoil), isNull);
      expect(card.prices.byFinish, isEmpty);
      expect(card.prices.secondary, isEmpty);
    });
  });

  group('attributes', () {
    test('a Spell card with no attribute still buckets sensibly', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final spell = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Monster Reborn');

      expect(spell.colors, isEmpty);
      // Spell and Trap cards have no attribute at all, so they land in the one
      // documented catch-all instead of crashing or inflating a real attribute.
      expect(CardGame.yugioh.bucketFor(''), YgoAttribute.spellTrap);
      expect(
        CardGame.yugioh.dominantBucket(spell.colors),
        YgoAttribute.spellTrap,
      );
    });

    test('a monster carries the attribute the provider published', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final card = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Blue-Eyes White Dragon');

      expect(card.colors, <String>['LIGHT']);
      expect(card.colorIdentity, <String>['LIGHT']);
      expect(CardGame.yugioh.dominantBucket(card.colors), YgoAttribute.light);
    });

    test('resolves attributes by name and by symbol', () {
      expect(YgoAttribute.fromName('DARK'), YgoAttribute.dark);
      expect(YgoAttribute.fromName('dark'), YgoAttribute.dark);
      expect(YgoAttribute.fromName('WIND'), YgoAttribute.wind);
      expect(YgoAttribute.fromName('DIVINE'), YgoAttribute.divine);
      // The full wire name is what a card row hands back in.
      expect(YgoAttribute.fromSymbol('EARTH'), YgoAttribute.earth);
      expect(YgoAttribute.fromSymbol('W'), YgoAttribute.water);
      // Anything unreadable is the catch-all, never a real attribute.
      expect(YgoAttribute.fromName(null), YgoAttribute.spellTrap);
      expect(YgoAttribute.fromName('spell'), YgoAttribute.spellTrap);
      expect(YgoAttribute.fromSymbol('???'), YgoAttribute.spellTrap);
    });

    test('buckets the seven attributes onto the game categories', () {
      expect(CardGame.yugioh.colourCategories, YgoAttribute.values);
      expect(
        CardGame.yugioh.colourCategories
            .where((bucket) => bucket != YgoAttribute.spellTrap)
            .map((bucket) => bucket.label),
        <String>['Dark', 'Light', 'Earth', 'Water', 'Fire', 'Wind', 'Divine'],
      );
    });
  });

  group('rarity shorthand', () {
    test('keeps the provider code verbatim when it publishes one', () async {
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final card = (await catalog.fetchCardsInSet('lob'))
          .firstWhere((c) => c.name == 'Blue-Eyes White Dragon');

      expect(card.rarityCode, 'UR');
    });

    test('derives initials when the provider leaves the code empty', () async {
      const bare = '''
{"id":99999999,"name":"Bare Rarity","type":"Effect Monster",
 "humanReadableCardType":"Effect Monster","frameType":"effect",
 "desc":"Test.","race":"Warrior","atk":1000,"def":1000,"level":4,
 "attribute":"EARTH",
 "card_sets":[
   {"set_name":"Starter Deck: Kaiba","set_code":"SDK-099",
    "set_rarity":"Grand Master Rare","set_rarity_code":"","set_price":"0"},
   {"set_name":"Starter Deck: Kaiba","set_code":"SDK-098",
    "set_rarity":"New","set_rarity_code":"","set_price":"0"}],
 "card_prices":[{"cardmarket_price":"0.00","tcgplayer_price":"0.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Starter Deck: Kaiba': cardData(<String>[bare]),
        },
      );

      final cards = await catalog.fetchCardsInSet('sdk');

      // "Grand Master Rare" would otherwise collapse to the rare tier letter
      // and be indistinguishable from every other premium rarity in the set.
      final grand = cards.firstWhere((c) => c.rarity == 'Grand Master Rare');
      expect(grand.rarityCode, 'GMR');

      // A one-word rarity keeps its own name rather than one initial.
      final placeholder = cards.firstWhere((c) => c.rarity == 'New');
      expect(placeholder.rarityCode, 'NEW');
    });

    test('caps the shorthand so it cannot push the card name out', () async {
      const long = '''
{"id":88888888,"name":"Long Rarity","type":"Spell Card",
 "humanReadableCardType":"Spell Card","frameType":"spell","race":"Normal",
 "desc":"Test.",
 "card_sets":[{"set_name":"Starter Deck: Kaiba","set_code":"SDK-097",
   "set_rarity":"Duel Terminal Parallel Rare","set_rarity_code":"",
   "set_price":"0"}],
 "card_prices":[{"cardmarket_price":"0.00","tcgplayer_price":"0.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Starter Deck: Kaiba': cardData(<String>[long]),
        },
      );

      final card = (await catalog.fetchCardsInSet('sdk')).single;
      expect(card.rarityCode, 'DTPR');
    });

    test('publishes no shorthand when the row has no rarity at all', () async {
      const none = '''
{"id":77777777,"name":"No Rarity","type":"Spell Card",
 "humanReadableCardType":"Spell Card","frameType":"spell","race":"Normal",
 "desc":"Test.",
 "card_sets":[{"set_name":"Starter Deck: Kaiba","set_code":"SDK-096",
   "set_rarity":"","set_rarity_code":"","set_price":"0"}],
 "card_prices":[{"cardmarket_price":"0.00","tcgplayer_price":"0.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Starter Deck: Kaiba': cardData(<String>[none]),
        },
      );

      // The badge falls back to the tier letter rather than inventing a code.
      final card = (await catalog.fetchCardsInSet('sdk')).single;
      expect(card.rarityCode, isNull);
    });
  });

  group('reprints', () {
    test('groups every printing of one name and drops fuzzy matches', () async {
      final catalog = catalogWith(
        byFname: cardData(<String>[blueEyesJson, decoyJson]),
      );

      final printings =
          await catalog.fetchPrintingsOf('Blue-Eyes White Dragon');

      expect(printings, hasLength(4));
      expect(
        printings.map((c) => c.oracleId).toSet(),
        <String>{TcgCard.normaliseName('Blue-Eyes White Dragon')},
      );
      // The same card is in three sets, two of which share the code "LOB".
      expect(
        printings.map((c) => c.setCode).toSet(),
        <String>{'lob', 'lob2', 'sdk'},
      );
      expect(printings.map((c) => c.id).toSet(), hasLength(printings.length));
      // "Blue-Eyes Ultimate Dragon" is a different card and must not be folded
      // into its reprints.
      expect(
        printings.every((c) => c.name == 'Blue-Eyes White Dragon'),
        isTrue,
      );
    });

    test('resolves a catalogue id as well as a name', () async {
      final catalog = catalogWith(
        byId: <String, String>{
          '83764718': cardData(<String>[monsterRebornJson]),
        },
      );

      final printings = await catalog
          .fetchPrintingsOf('83764718:lob:lob-en053:ultra-rare');

      expect(printings, hasLength(1));
      expect(printings.single.name, 'Monster Reborn');
      expect(printings.single.setCode, 'lob');
    });
  });

  group('single cards and price refreshes', () {
    test('resolves the printing a catalogue id names', () async {
      final catalog = catalogWith(
        byId: <String, String>{'89631139': cardData(<String>[blueEyesJson])},
      );

      final card =
          await catalog.fetchCardById('89631139:sdk:sdk-001:ultra-rare');

      expect(card, isNotNull);
      expect(card!.name, 'Blue-Eyes White Dragon');
      expect(card.setCode, 'sdk');
      expect(card.collectorNumber, '001');
    });

    test('answers null for a passcode the provider does not know', () async {
      final catalog = catalogWith();

      expect(
        await catalog.fetchCardById('99999999:lob:lob-en001:rare'),
        isNull,
      );
      expect(await catalog.fetchCardById(''), isNull);
    });

    test('re-reads prices by passcode and returns updated copies', () async {
      const repriced = '''
{"id":89631139,"name":"Blue-Eyes White Dragon","attribute":"LIGHT",
 "card_sets":[{"set_name":"Starter Deck: Kaiba","set_code":"SDK-001",
   "set_rarity":"Ultra Rare","set_rarity_code":"(UR)","set_price":"40"}],
 "card_prices":[{"cardmarket_price":"0.10","tcgplayer_price":"12.50",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final requests = <Uri>[];
      final catalog = catalogWith(
        byId: <String, String>{'89631139': cardData(<String>[repriced])},
        requests: requests,
      );

      const original = TcgCard(
        game: CardGame.yugioh,
        id: '89631139:sdk:sdk-001:ultra-rare',
        setCode: 'sdk',
        setName: 'Starter Deck: Kaiba',
        name: 'Blue-Eyes White Dragon',
        collectorNumber: '001',
        rarity: 'Ultra Rare',
        prices: TcgPrices(byFinish: <String, double?>{'nonfoil': 0.13}),
      );

      final fresh = await catalog.refreshPrices(<TcgCard>[original]);

      expect(requests.single.queryParameters['id'], '89631139');
      expect(fresh, hasLength(1));
      expect(fresh.single.id, original.id);
      expect(fresh.single.setCode, 'sdk');
      // 40 is this printing's own set_price; 12.50 is the card-level TCGplayer
      // figure that stood in for every version of the card before.
      expect(fresh.single.prices.priceFor(CardFinish.nonfoil), 40.0);
    });
  });

  group('game vocabulary', () {
    test('Yu-Gi-Oh! offers the finishes and grades its collectors use', () {
      expect(
        CardGame.yugioh.finishes,
        <CardFinish>[CardFinish.nonfoil, CardFinish.foil],
      );
      expect(
        CardGame.yugioh.conditions,
        <CardCondition>[
          CardCondition.nearMint,
          CardCondition.lightPlayed,
          CardCondition.moderatelyPlayed,
          CardCondition.heavilyPlayed,
          CardCondition.damaged,
        ],
      );
      // The Magic-only grades have no meaning to a Yu-Gi-Oh! collector.
      for (final magicOnly in <CardCondition>[
        CardCondition.mint,
        CardCondition.excellent,
        CardCondition.good,
        CardCondition.played,
        CardCondition.poor,
      ]) {
        expect(CardGame.yugioh.conditions, isNot(contains(magicOnly)));
      }
    });

    test('the third game keeps its own identity and never merges', () {
      expect(CardGame.yugioh.id, 'yugioh');
      expect(CardGame.yugioh.tag, CardGameTag.yugioh);
      expect(CardGame.yugioh.abbreviation, 'YGO');
      expect(CardGame.yugioh.publisher, 'Konami');
      expect(CardGame.yugioh.dataSource, 'YGOPRODeck');
      expect(CardGame.yugioh.catalogueSince, 1999);
      expect(CardGame.fromId('yugioh'), CardGame.yugioh);
      // Every game keeps a distinct accent, so the switcher can tell them apart
      // at a glance.
      expect(
        CardGame.values.map((game) => game.accent).toSet(),
        hasLength(CardGame.values.length),
      );
    });

    test('the catalogue declares the game it serves', () {
      final catalog = catalogWith();

      expect(catalog.game, CardGame.yugioh);
      expect(catalog.sourceName, 'YGOPRODeck');
    });
  });

  group('ids the companion sampler depends on', () {
    test('the catalogue emits the compound id the sampler writes', () async {
      // tool/poll_yugioh_prices.py stores one price series per printing under
      // an id rebuilt from the passcode, the set code, the printing code and
      // the rarity. If the two ever disagree the sampler keeps writing rows the
      // app never asks for, and Yu-Gi-Oh! silently loses the only history it
      // has. This is the contract, pinned from the app's side.
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Legend of Blue Eyes White Dragon': lobBody,
        },
      );

      final cards = await catalog.fetchCardsInSet('lob');

      expect(
        cards.map((c) => c.id),
        contains('89631139:lob:lob-en001:ultra-rare'),
      );
    });

    test('a printing with no rarity keeps the sampler placeholder', () async {
      const bare = '''
{"id":77777777,"name":"No Rarity","type":"Spell Card",
 "humanReadableCardType":"Spell Card","frameType":"spell","desc":"Test.",
 "card_sets":[{"set_name":"Starter Deck: Kaiba","set_code":"SDK-042",
   "set_rarity":"","set_rarity_code":"","set_price":"2.00"}],
 "card_prices":[{"cardmarket_price":"0.10","tcgplayer_price":"2.00",
   "ebay_price":"0.00","amazon_price":"0.00","coolstuffinc_price":"0.00"}]}
''';
      final catalog = catalogWith(
        bySetName: <String, String>{
          'Starter Deck: Kaiba': cardData(<String>[bare]),
        },
      );

      final cards = await catalog.fetchCardsInSet('sdk');

      expect(cards.single.id, '77777777:sdk:sdk-042:unknown');
    });
  });

  group('malformed responses', () {
    test('a set list that is not a list is reported, not guessed at', () async {
      final catalog = catalogWith(setsBody: '{"data":[]}');

      await expectLater(catalog.fetchAllSets(), throwsA(isA<Object>()));
    });

    test('an unknown set code is reported rather than fetched', () async {
      final catalog = catalogWith();

      await expectLater(catalog.fetchCardsInSet('zzz'), throwsA(isA<Object>()));
    });

    test('a search that matches nothing returns an empty list', () async {
      final catalog = catalogWith();

      expect(await catalog.search('nothing like this exists'), isEmpty);
    });

    test('searches effect text as well as names', () async {
      // "Special Summon" is not a card name. The provider answers it through
      // its description filter, which the adapter used not to send at all.
      final catalog = catalogWith(
        byFname: cardData(<String>[blueEyesJson]),
        byDesc: cardData(<String>[monsterRebornJson]),
      );

      final results = await catalog.search('Special Summon');

      expect(results.map((c) => c.name), contains('Monster Reborn'));
    });

    test('leads with name matches when both passes hit', () async {
      final catalog = catalogWith(
        byFname: cardData(<String>[blueEyesJson]),
        byDesc: cardData(<String>[blueEyesJson]),
      );

      final results = await catalog.search('Blue-Eyes');

      // The same card comes back from both passes and is printed in three
      // sets; it must appear once per printing, not twice.
      expect(results.map((c) => c.id).toSet(), hasLength(results.length));
      expect(results.first.name, 'Blue-Eyes White Dragon');
    });

    test('answers names when the effect pass is unavailable', () async {
      final catalog = catalogWith(byFname: cardData(<String>[blueEyesJson]));

      final results = await catalog.search('Blue-Eyes');

      expect(results, isNotEmpty);
      expect(results.every((c) => c.name == 'Blue-Eyes White Dragon'), isTrue);
    });
  });
}
