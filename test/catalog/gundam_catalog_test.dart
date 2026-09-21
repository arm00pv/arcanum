// Tests for the gcgapi catalogue adapter.
//
//   flutter test test/catalog/gundam_catalog_test.dart
//
// Nothing here touches the network. The adapter takes a Dio instance, so these
// tests hand it one backed by an adapter serving canned payloads, and answer 404
// - the way gcgapi answers a product it does not hold - for anything a test did
// not route.
//
// The fixtures are trimmed slices of live responses, kept awkward on purpose:
// several products are printed with one card number, an alternate art is filed
// under a set its number does not name, the provider writes a bare hyphen where a
// card has no rules text or trait, a page is capped at 250 rows, and a set's code
// is folded to the form the app stores. Every one of those is a case where the
// Gundam path degrades quietly rather than failing loudly, which is why they are
// pinned here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:arcanum/data/catalog/gundam_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The set list as gcgapi publishes it: code, name and a real card count, and
/// nothing about when the set was released.
const String setsJson = '''
{"data":[
  {"set_code":"GD01","set_name":"Newtype Rising","card_count":254},
  {"set_code":"EB01","set_name":"Eternal Nexus","card_count":108},
  {"set_code":"ST01","set_name":"Heroic Beginnings","card_count":57},
  {"set_code":"RP","set_name":"Promotion card","card_count":66},
  {"set_code":"EXB","set_name":"Basic Cards","card_count":2}
]}
''';

/// One ordinary product: a Unit with a trait, a level, a zone and a pilot.
const String gd01001Json = '''
{"product_id":"GD01-001","card_number":"GD01-001","name":"Gundam",
 "set_code":"GD01","set_name":"Newtype Rising","rarity":"LR","card_type":"UNIT",
 "color":"Blue","level":4,"cost":3,"ap":3,"hp":3,"zone":"Space Earth",
 "trait":"(Earth Federation)","link":"[Amuro Ray]",
 "source_title":"Mobile Suit Gundam","block_icon":"1","sp":null,
 "effect":"All your (White Base Team) Units gain <Repair 1>.",
 "image_url":"https://www.gundam-gcg.com/en/images/cards/card/GD01-001.webp?260917",
 "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=GD01-001"}
''';

/// An alternate art of the same card: the same printed number, a rarity of its
/// own and a product id of its own - which is the whole reason the id cannot be
/// the number.
const String gd01001p1Json = '''
{"product_id":"GD01-001_p1","card_number":"GD01-001","name":"Gundam",
 "set_code":"GD01","set_name":"Newtype Rising","rarity":"LR +","card_type":"UNIT",
 "color":"Blue","level":4,"cost":3,"ap":3,"hp":3,"zone":"Space Earth",
 "trait":"(Earth Federation)","link":"[Amuro Ray]",
 "source_title":"Mobile Suit Gundam","block_icon":"1",
 "effect":"All your (White Base Team) Units gain <Repair 1>.",
 "image_url":"https://www.gundam-gcg.com/en/images/cards/card/GD01-001_p1.webp?260917",
 "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=GD01-001_p1"}
''';

/// A Resource card, which is the shape the provider writes a bare hyphen into:
/// no rules text, no trait, no zone and no pilot.
const String rp001Json = '''
{"product_id":"RP-001","card_number":"RP-001","name":"Resource",
 "set_code":"RP","set_name":"Promotion card","rarity":"P","card_type":"RESOURCE",
 "color":null,"level":null,"cost":null,"ap":null,"hp":null,"zone":"-",
 "trait":"-","link":"-","source_title":"Mobile Suit Gundam Wing",
 "block_icon":"\u03b2","effect":"-",
 "image_url":"https://www.gundam-gcg.com/en/images/cards/card/RP-001.webp?260917",
 "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=RP-001"}
''';

/// A reprint filed under a set its own number does not name.
const String exb001p7Json = '''
{"product_id":"EXB-001_p7","card_number":"EXB-001","name":"Ex Base",
 "set_code":"EXB","set_name":"Basic Cards","rarity":"P","card_type":"EX BASE",
 "color":null,"level":null,"cost":null,"ap":null,"hp":null,"zone":"-",
 "trait":"-","link":"-","source_title":"-","block_icon":"-","effect":"-",
 "image_url":"https://www.gundam-gcg.com/en/images/cards/card/EXB-001_p7.webp?260917",
 "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=EXB-001_p7"}
''';

/// What the name filter answers, and what the effect filter answers: the same
/// product, which is what makes the deduplication worth a test.
const String nameHitsJson = '''
{"data":[
  {"product_id":"GD01-001","card_number":"GD01-001","name":"Gundam",
   "set_code":"GD01","set_name":"Newtype Rising","rarity":"LR","card_type":"UNIT",
   "color":"Blue","level":4,"cost":3,"ap":3,"hp":3,"zone":"Space Earth",
   "trait":"(Earth Federation)","link":"[Amuro Ray]","source_title":"Mobile Suit Gundam",
   "block_icon":"1","effect":"All your Units gain <Repair 1>.",
   "image_url":"https://www.gundam-gcg.com/en/images/cards/card/GD01-001.webp?260917",
   "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=GD01-001"},
  {"product_id":"GD01-001_p1","card_number":"GD01-001","name":"Gundam",
   "set_code":"GD01","set_name":"Newtype Rising","rarity":"LR +","card_type":"UNIT",
   "color":"Blue","level":4,"cost":3,"ap":3,"hp":3,"zone":"Space Earth",
   "trait":"(Earth Federation)","link":"[Amuro Ray]","source_title":"Mobile Suit Gundam",
   "block_icon":"1","effect":"All your Units gain <Repair 1>.",
   "image_url":"https://www.gundam-gcg.com/en/images/cards/card/GD01-001_p1.webp?260917",
   "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=GD01-001_p1"}
]}
''';

const String effectHitsJson = '''
{"data":[
  {"product_id":"GD01-001","card_number":"GD01-001","name":"Gundam",
   "set_code":"GD01","set_name":"Newtype Rising","rarity":"LR","card_type":"UNIT",
   "color":"Blue","level":4,"cost":3,"ap":3,"hp":3,"zone":"Space Earth",
   "trait":"(Earth Federation)","link":"[Amuro Ray]","source_title":"Mobile Suit Gundam",
   "block_icon":"1","effect":"All your Units gain <Repair 1>.",
   "image_url":"https://www.gundam-gcg.com/en/images/cards/card/GD01-001.webp?260917",
   "detail_url":"https://www.gundam-gcg.com/en/cards/detail.php?detailSearch=GD01-001"}
]}
''';

/// A set with more products than the provider will answer in one page.
///
/// The cap is the provider's, not this client's: a limit above 250 answers 250
/// rows and reports its own limit in the meta block, so a set of 260 products is
/// only whole if the client asks for the second page. The products are generated
/// rather than typed out because 260 of them is 260 lines of fixture and what
/// they prove is the loop, not the mapping.
List<Map<String, Object?>> bigSet() => <Map<String, Object?>>[
  for (int i = 1; i <= 260; i++)
    <String, Object?>{
      'product_id': 'EB01-${i.toString().padLeft(3, '0')}',
      'card_number': 'EB01-${i.toString().padLeft(3, '0')}',
      'name': 'Card §i',
      'set_code': 'EB01',
      'set_name': 'Eternal Nexus',
      'rarity': 'C',
      'card_type': 'UNIT',
      'color': 'Green',
      'level': 1,
      'cost': 1,
      'ap': 1,
      'hp': 1,
      'zone': 'Space',
      'trait': '(Test)',
      'link': '-',
      'source_title': 'Test',
      'block_icon': '1',
      'effect': 'Nothing.',
      'image_url': 'https://www.gundam-gcg.com/en/images/cards/card/'
          'EB01-${i.toString().padLeft(3, '0')}.webp?260917',
      'detail_url': 'https://www.gundam-gcg.com/en/cards/detail.php'
          '?detailSearch=EB01-${i.toString().padLeft(3, '0')}',
    },
];

/// Serves canned payloads in place of the network.
///
/// The set list answers whole, one product answers by its id or a 404, and the
/// set route filters by set code - case-insensitively, as the provider does -
/// and slices the way a filtered list is sliced. Every request is recorded, so a
/// test can assert how many were made and with what.
class _FakeGcgapi implements HttpClientAdapter {
  _FakeGcgapi({this.failAll = false})
    : byId = <String, Map<String, Object?>>{
        for (final Map<String, Object?> card in <Map<String, Object?>>[
          jsonDecode(gd01001Json) as Map<String, Object?>,
          jsonDecode(gd01001p1Json) as Map<String, Object?>,
          jsonDecode(rp001Json) as Map<String, Object?>,
          jsonDecode(exb001p7Json) as Map<String, Object?>,
          ...bigSet(),
        ])
          card['product_id']! as String: card,
      };

  /// Whether every request fails, for the paths that must narrow rather than
  /// raise into the UI.
  final bool failAll;
  final Map<String, Map<String, Object?>> byId;
  final List<Uri> requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (failAll) {
      throw DioException(requestOptions: options, message: 'down');
    }
    final List<String> segments = options.uri.pathSegments;

    if (segments.isNotEmpty && segments.last == 'sets') {
      return _body(setsJson);
    }

    if (segments.length >= 2 && segments[segments.length - 2] == 'cards') {
      final Map<String, Object?>? card = byId[segments.last];
      if (card == null) {
        return _body('{"detail":"Not found"}', 404);
      }
      return _body(jsonEncode(<String, Object?>{'data': card}));
    }

    if (segments.isNotEmpty && segments.last == 'cards') {
      final Map<String, String> query = options.uri.queryParameters;
      // A name or effect query is the search route; anything else is the set
      // listing, which is the only other thing this route answers.
      if (query.containsKey('name')) return _body(nameHitsJson);
      if (query.containsKey('effect')) return _body(effectHitsJson);
      final String code = (query['set_code'] ?? '').toLowerCase();
      final List<Map<String, Object?>> all = <Map<String, Object?>>[
        for (final Map<String, Object?> card in byId.values)
          if ((card['set_code']! as String).toLowerCase() == code) card,
      ];
      final int limit = int.tryParse(query['limit'] ?? '') ?? 100;
      final int offset = int.tryParse(query['offset'] ?? '') ?? 0;
      final List<Map<String, Object?>> page =
          all.skip(offset).take(limit).toList();
      return _body(jsonEncode(<String, Object?>{
        'data': page,
        '_meta': <String, Object?>{
          'total': all.length,
          'limit': limit,
          'offset': offset,
          'count': page.length,
        },
      }));
    }
    return _body('{"data":[]}');
  }

  static ResponseBody _body(String body, [int status = 200]) =>
      ResponseBody.fromString(body, status, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

/// A catalogue wired to a fake provider.
GundamCatalog _catalogOn(_FakeGcgapi api) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.gcgapi.com/v1'));
  dio.httpClientAdapter = api;
  return GundamCatalog(dio: dio);
}

void main() {
  group('set list', () {
    test('reads every set the provider lists, with its own card count', () async {
      final GundamCatalog catalog = _catalogOn(_FakeGcgapi());
      final List<TcgSet> sets = await catalog.fetchAllSets();
      expect(sets, hasLength(5));
      expect(sets.first.game, CardGame.gundam);
      expect(sets.first.id, 'GD01');
      expect(sets.first.name, 'Newtype Rising');
      expect(sets.first.cardCount, 254);
      // The provider publishes no release date for any set, so the column is
      // empty rather than guessed at: the sets table sorts on it.
      expect(sets.first.releasedAt, isNull);
    });

    test('stores the code folded and keeps the provider spelling as the id',
        () async {
      final List<TcgSet> sets = await _catalogOn(_FakeGcgapi()).fetchAllSets();
      for (final TcgSet set in sets) {
        expect(set.code, set.code.toLowerCase());
        expect(set.code, isNot(set.id));
      }
      expect(<String, String>{for (final TcgSet s in sets) s.code: s.id},
          containsPair('gd01', 'GD01'));
    });

    test('classifies the three kinds of set the provider names', () async {
      final List<TcgSet> sets = await _catalogOn(_FakeGcgapi()).fetchAllSets();
      final Map<String, String> types = <String, String>{
        for (final TcgSet set in sets) set.code: set.setType,
      };
      expect(types['gd01'], 'expansion');
      expect(types['eb01'], 'expansion');
      expect(types['st01'], 'starter');
      expect(types['rp'], 'promo');
    });

    test('reports progress once per set', () async {
      final List<(int, int)> progress = <(int, int)>[];
      await _catalogOn(_FakeGcgapi()).fetchAllSets(
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(progress.first, (0, 5));
      expect(progress.last, (5, 5));
    });
  });

  group('cards in a set', () {
    test('stores the provider id verbatim on a row built from the product',
        () async {
      final GundamCatalog catalog = _catalogOn(_FakeGcgapi());
      final List<TcgCard> cards = await catalog.fetchCardsInSet('gd01');
      final TcgCard card = cards.firstWhere((TcgCard c) => c.id == 'GD01-001');
      expect(card.game, CardGame.gundam);
      expect(card.setCode, 'gd01');
      expect(card.setName, 'Newtype Rising');
      expect(card.name, 'Gundam');
      expect(card.collectorNumber, '001');
      expect(card.collectorNumberSortKey, 1);
      expect(card.rarity, 'LR');
      expect(card.typeLine, 'UNIT - (Earth Federation) - Level 4 - Space Earth');
      expect(card.oracleText, 'All your (White Base Team) Units gain <Repair 1>.');
      expect(card.cmc, 3);
      expect(card.colors, <String>['Blue']);
      expect(card.promo, isFalse);
      expect(card.oracleId, 'gundam|unit');
      expect(card.imageUris['normal'],
          'https://www.gundam-gcg.com/en/images/cards/card/GD01-001.webp?260917');
      // The full printed number, and the provider's own id, which is not a
      // TCGplayer product id and is deliberately not stored under tcgplayerId.
      expect(card.extras['printedNumber'], 'GD01-001');
      expect(card.extras['productId'], 'GD01-001');
      expect(card.extras.containsKey('tcgplayerId'), isFalse);
      expect(card.extras['level'], 4);
      expect(card.extras['ap'], 3);
      expect(card.extras['hp'], 3);
      expect(card.extras['zone'], 'Space Earth');
      expect(card.extras['trait'], '(Earth Federation)');
      expect(card.extras['link'], '[Amuro Ray]');
      expect(card.extras['cardType'], 'UNIT');
      expect(card.extras['sourceTitle'], 'Mobile Suit Gundam');
      expect(card.extras['blockIcon'], '1');
      // The source quotes no price at all, so a card carries none.
      expect(card.prices.isEmpty, isTrue);
    });

    test('keeps the art variants of one card apart', () async {
      final List<TcgCard> cards =
          await _catalogOn(_FakeGcgapi()).fetchCardsInSet('gd01');
      final List<TcgCard> variants = <TcgCard>[
        for (final TcgCard card in cards)
          if (card.collectorNumber == '001') card,
      ];
      expect(variants.map((TcgCard c) => c.id).toList()..sort(),
          <String>['GD01-001', 'GD01-001_p1']);
      // One card number, two products: an id built from the number would have
      // collapsed these into one row.
      expect(variants.map((TcgCard c) => c.collectorNumber).toSet(),
          <String>{'001'});
      expect(variants.map((TcgCard c) => c.rarity).toSet(), <String>{'LR', 'LR +'});
      // They are one card to a collector, which is what the oracle id groups.
      expect(variants.map((TcgCard c) => c.oracleId).toSet(), hasLength(1));
    });

    test('reads a set larger than the provider page cap page by page', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      final List<TcgCard> cards = await _catalogOn(api).fetchCardsInSet('eb01');
      expect(cards, hasLength(260));
      expect(cards.map((TcgCard c) => c.id).toSet(), hasLength(260));
      final List<Uri> pages = <Uri>[
        for (final Uri uri in api.requests)
          if (uri.queryParameters.containsKey('set_code')) uri,
      ];
      expect(pages, hasLength(2));
      expect(pages.first.queryParameters['offset'], '0');
      expect(pages.first.queryParameters['limit'], '250');
      expect(pages.last.queryParameters['offset'], '250');
      // Collector-number order across the whole set, not within a page.
      expect(cards.first.collectorNumber, '001');
      expect(cards.last.collectorNumber, '260');
    });

    test('reports progress against the count the provider publishes', () async {
      final List<(int, int)> progress = <(int, int)>[];
      await _catalogOn(_FakeGcgapi()).fetchCardsInSet(
        'eb01',
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(progress.first, (0, 0));
      expect(progress.any(((int, int) p) => p.$2 == 260), isTrue);
      expect(progress.last.$1, 260);
    });

    test('files an alternate art under the set it is filed in', () async {
      // EXB-001_p7 is a Basic Cards product printed with an Ex Base number, and
      // a set download puts it in the set it was downloaded as part of, which is
      // what keeps the catalogue's foreign key true.
      final List<TcgCard> cards =
          await _catalogOn(_FakeGcgapi()).fetchCardsInSet('exb');
      final TcgCard card = cards.firstWhere((TcgCard c) => c.id == 'EXB-001_p7');
      expect(card.setCode, 'exb');
      expect(card.collectorNumber, '001');
      expect(card.extras['printedNumber'], 'EXB-001');
    });

    test('reads the provider hyphen as nothing at all', () async {
      final List<TcgCard> cards =
          await _catalogOn(_FakeGcgapi()).fetchCardsInSet('rp');
      final TcgCard resource = cards.single;
      expect(resource.typeLine, 'RESOURCE');
      expect(resource.oracleText, isNull);
      expect(resource.extras.containsKey('zone'), isFalse);
      expect(resource.extras.containsKey('trait'), isFalse);
      expect(resource.extras.containsKey('link'), isFalse);
      // Not every hyphen is a placeholder: the block icon is a real value.
      expect(resource.extras['blockIcon'], '\u03b2');
      expect(resource.promo, isTrue);
      expect(resource.cmc, isNull);
      expect(resource.colors, isEmpty);
    });

    test('answers empty for a set the provider does not hold', () async {
      final List<TcgCard> cards =
          await _catalogOn(_FakeGcgapi()).fetchCardsInSet('nope');
      expect(cards, isEmpty);
    });
  });

  group('single cards', () {
    test('resolves a card by its product id', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      final TcgCard? card = await _catalogOn(api).fetchCardById('GD01-001_p1');
      expect(card, isNotNull);
      expect(card!.id, 'GD01-001_p1');
      // Reached by id alone there is no set in hand, so the code comes from the
      // payload's own set_code - and it is the same string a set download
      // derives, which the parity test asserts over the committed sample.
      expect(card.setCode, 'gd01');
      expect(api.requests.single.path, '/v1/cards/GD01-001_p1');
    });

    test('answers null for a card the provider does not hold', () async {
      expect(await _catalogOn(_FakeGcgapi()).fetchCardById('NOPE-999'), isNull);
    });

    test('answers null for an empty id without asking', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      expect(await _catalogOn(api).fetchCardById('  '), isNull);
      expect(api.requests, isEmpty);
    });
  });

  group('search', () {
    test('leads with name matches and keeps one row per product', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      final List<TcgCard> hits = await _catalogOn(api).search('gundam');
      // Two filters were asked and both answered the same product, which is
      // deduplicated rather than shown twice - and the variant art is a product
      // of its own, so it stays.
      expect(hits.map((TcgCard c) => c.id).toList(),
          <String>['GD01-001', 'GD01-001_p1']);
      final List<String> filters = <String>[
        for (final Uri uri in api.requests) ...uri.queryParameters.keys,
      ];
      expect(filters, containsAll(<String>['name', 'effect']));
    });

    test('answers empty when a filter cannot be answered', () async {
      final List<TcgCard> hits =
          await _catalogOn(_FakeGcgapi(failAll: true)).search('gundam');
      expect(hits, isEmpty);
    });

    test('asks nothing at all for an empty query', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      expect(await _catalogOn(api).search('   '), isEmpty);
      expect(api.requests, isEmpty);
    });
  });

  group('printings and prices', () {
    test('reports no other printings, because reprints share no id', () async {
      expect(
          await _catalogOn(_FakeGcgapi()).fetchPrintingsOf('gundam|unit'), isEmpty);
    });

    test('quotes no price, because the source has none', () async {
      final _FakeGcgapi api = _FakeGcgapi();
      final List<TcgCard> cards = await _catalogOn(api).fetchCardsInSet('rp');
      expect(await _catalogOn(api).refreshPrices(cards), isEmpty);
    });
  });
}
