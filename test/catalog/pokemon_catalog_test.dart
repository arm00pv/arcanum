// Tests for the TCGdex catalogue adapter.
//
//   flutter test test/catalog/pokemon_catalog_test.dart
//
// Nothing here touches the network. The adapter takes a Dio instance, so these
// tests hand it one backed by an adapter serving canned payloads, and answer
// 404 - the way TCGdex answers a card it does not hold - for anything a test
// did not route.
//
// The fixtures are trimmed slices of live responses, kept awkward on purpose:
// the set list carries no release date, series or logo (the adapter enriches
// each set to get them), a card's own detail call can fail, and the asset CDN
// needs the series segment in the URL. Every one of those is a case where the
// Pokémon path degrades quietly rather than failing loudly, which is why they
// are pinned here.

import 'dart:typed_data';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/pokemon_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The set list as TCGdex publishes it: ids, names and card counts, and nothing
/// else. No release date, no series, no logo - those arrive one set at a time.
const String setsJson = '''
[
  {"id":"base1","name":"Base Set","cardCount":{"total":102,"official":102}},
  {"id":"swsh1","name":"Sword & Shield","cardCount":{"total":216,"official":202}},
  {"id":"xyp","name":"XY Black Star Promos","cardCount":{"total":211,"official":211}}
]
''';

/// One set, enriched: this is what the per-set call adds.
const String base1Json = '''
{"id":"base1","name":"Base Set","releaseDate":"1999-01-09",
 "serie":{"id":"base","name":"Base"},
 "logo":"https://assets.tcgdex.net/en/base/base1/logo",
 "cardCount":{"total":102,"official":102},
 "cards":[
   {"id":"base1-4","localId":"4","name":"Charizard"},
   {"id":"base1-58","localId":"58","name":"Pikachu"},
   {"id":"base1-99","localId":"99","name":"Missing Card"}
 ]}
''';

/// Charizard: holo and 1st edition exist as physical variants, and TCGplayer
/// quotes only the unlimited holo.
const String charizardJson = '''
{"id":"base1-4","localId":"4","name":"Charizard","rarity":"Rare",
 "image":"https://assets.tcgdex.net/en/base/base1/4",
 "set":{"id":"base1","name":"Base Set","cardCount":{"official":102,"total":102}},
 "illustrator":"Mitsuhiro Arita","hp":120,"types":["Fire"],"stage":"Stage 2",
 "category":"Pokemon","dexId":[6],
 "variants":{"firstEdition":true,"holo":true,"normal":false,"reverse":false},
 "attacks":[{"cost":["Fire"],"name":"Fire Spin","damage":"100",
   "effect":"Discard 2 Energy cards attached to Charizard."}],
 "pricing":{"tcgplayer":{"unit":"USD","updated":"2026-09-12T04:02:08.225Z",
   "holofoil":{"productId":42382,"lowPrice":449.99,"midPrice":902.5,
     "marketPrice":869.02}},
  "cardmarket":{"unit":"EUR","updated":"2026-09-12T04:02:10.282Z",
    "avg":523.53,"low":102,"trend":583.52}}}
''';

/// Pikachu: two quoted finishes, which is the ordinary modern case.
const String pikachuJson = '''
{"id":"base1-58","localId":"58","name":"Pikachu","rarity":"Common",
 "image":"https://assets.tcgdex.net/en/base/base1/58",
 "set":{"id":"base1","name":"Base Set"},
 "variants":{"normal":true,"reverse":true,"holo":false,"firstEdition":false},
 "pricing":{"tcgplayer":{"unit":"USD",
   "normal":{"productId":1,"marketPrice":12.5},
   "reverseHolofoil":{"productId":2,"marketPrice":31.75}}}}
''';

/// The search endpoint answers with ids, names and a thumbnail - never a rarity
/// or a price.
const String searchJson = '''
[
  {"id":"base1-4","localId":"4","name":"Charizard"},
  {"id":"base1-58","localId":"58","name":"Pikachu","image":"https://assets.tcgdex.net/en/base/base1/58"},
  {"id":"base1-99","localId":"99","name":"Missing Card"}
]
''';

/// Serves canned payloads in place of the network.
class _FakeTcgdexApi implements HttpClientAdapter {
  _FakeTcgdexApi(this._respond, this.requests);

  /// Answers one request with a JSON body, or with null for a 404.
  final String? Function(Uri uri) _respond;

  /// Every URI asked for, so a test can count the calls an operation costs.
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
      return ResponseBody.fromString('{"error":"Not found"}', 404,
          headers: headers);
    }
    return ResponseBody.fromString(body, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a catalogue wired to those payloads.
PokemonCatalog catalogWith({
  String setsBody = setsJson,
  Map<String, String> bySet = const <String, String>{'base1': base1Json},
  Map<String, String> byCard = const <String, String>{
    'base1-4': charizardJson,
    'base1-58': pikachuJson,
  },
  String? searchBody = searchJson,
  List<Uri>? requests,
}) {
  final log = requests ?? <Uri>[];
  final dio = Dio(BaseOptions(baseUrl: 'https://api.tcgdex.net/v2/en'));
  dio.httpClientAdapter = _FakeTcgdexApi((Uri uri) {
    final path = uri.path;
    if (path.endsWith('/sets')) return setsBody;
    if (path.endsWith('/cards')) return searchBody;
    final setMatch = RegExp(r'/sets/([^/]+)$').firstMatch(path);
    if (setMatch != null) return bySet[setMatch.group(1)];
    final cardMatch = RegExp(r'/cards/([^/]+)$').firstMatch(path);
    if (cardMatch != null) return byCard[cardMatch.group(1)];
    return null;
  }, log);
  return PokemonCatalog(dio: dio);
}

void main() {
  group('set list', () {
    test('reads every set the provider lists', () async {
      final sets = await catalogWith().fetchAllSets();

      expect(sets, hasLength(3));
      expect(sets.first.id, 'base1');
      expect(sets.first.name, 'Base Set');
      expect(sets.first.game, CardGame.pokemon);
    });

    test('fills in the release date, series and logo the list omits', () async {
      // The list endpoint has none of these, so a set shown without enrichment
      // sorts to the bottom of "Newest" and prints no date at all.
      final sets = await catalogWith().fetchAllSets();
      final base = sets.firstWhere((s) => s.id == 'base1');

      expect(base.releasedAt, DateTime(1999, 1, 9));
      expect(base.series, 'Base');
      expect(base.logoUri, 'https://assets.tcgdex.net/en/base/base1/logo.webp');
      expect(base.cardCount, 102);
    });

    test('keeps a set whose enrichment call fails', () async {
      // One failed call must not remove a set from the catalogue; the stub the
      // list provided is what survives, with no date rather than a wrong one.
      final sets = await catalogWith(
        bySet: const <String, String>{'base1': base1Json},
      ).fetchAllSets();

      expect(sets, hasLength(3));
      final promos = sets.firstWhere((s) => s.id == 'xyp');
      expect(promos.name, 'XY Black Star Promos');
      expect(promos.releasedAt, isNull);
      expect(promos.cardCount, 211);
    });

    test('reports progress once per set', () async {
      final seen = <int>[];
      await catalogWith().fetchAllSets(
        onProgress: (done, total) => seen.add(total),
      );

      expect(seen, isNotEmpty);
      expect(seen.every((t) => t == 3), isTrue);
      expect(seen.last, 3);
    });
  });

  group('cards in a set', () {
    test('maps prices onto the finishes Pokemon actually prints', () async {
      final cards = await catalogWith().fetchCardsInSet('base1');
      final charizard = cards.firstWhere((c) => c.id == 'base1-4');

      expect(charizard.name, 'Charizard');
      expect(charizard.rarity, 'Rare');
      expect(charizard.prices.priceFor(CardFinish.holofoil), 869.02);
      expect(charizard.collectorNumber, '4');
      // Cardmarket is not the canonical currency, so it lands in secondary
      // rather than being shown as if it were dollars.
      expect(charizard.prices.secondary['eur'], 583.52);
      expect(charizard.game, CardGame.pokemon);
    });

    test('reads both finishes when a card has two quoted', () async {
      final cards = await catalogWith().fetchCardsInSet('base1');
      final pikachu = cards.firstWhere((c) => c.id == 'base1-58');

      expect(pikachu.prices.priceFor(CardFinish.nonfoil), 12.5);
      expect(pikachu.prices.priceFor(CardFinish.reverseHolofoil), 31.75);
    });

    test('records the physical variants the card exists in', () async {
      final cards = await catalogWith().fetchCardsInSet('base1');
      final charizard = cards.firstWhere((c) => c.id == 'base1-4');
      final variants = charizard.extras['variants'] as List<dynamic>;

      expect(variants, contains(CardFinish.holofoil.code));
      expect(variants, contains(CardFinish.firstEdition.code));
      expect(variants, isNot(contains(CardFinish.nonfoil.code)));
    });

    test('takes art from the response rather than rebuilding the URL', () async {
      final cards = await catalogWith().fetchCardsInSet('base1');
      final charizard = cards.firstWhere((c) => c.id == 'base1-4');

      expect(
        charizard.imageUrl(size: 'normal'),
        'https://assets.tcgdex.net/en/base/base1/4/high.webp',
      );
    });

    test('keeps a card whose detail call fails, with working art', () async {
      // The regression this pins: the CDN needs the series segment, and a URL
      // built from the set id alone answers 404. The series is only known
      // because the set call was made, so it has to survive to this point.
      final cards = await catalogWith().fetchCardsInSet('base1');
      final missing = cards.firstWhere((c) => c.id == 'base1-99');

      expect(missing.name, 'Missing Card');
      expect(missing.rarity, 'unknown');
      expect(missing.prices.priceFor(CardFinish.holofoil), isNull);
      expect(
        missing.imageUrl(size: 'normal'),
        'https://assets.tcgdex.net/en/base/base1/99/high.webp',
      );
    });

    test('reads the set once and each card once', () async {
      final requests = <Uri>[];
      await catalogWith(requests: requests).fetchCardsInSet('base1');

      expect(
        requests.where((u) => RegExp(r'/sets/base1$').hasMatch(u.path)),
        hasLength(1),
      );
      expect(
        requests.where((u) => u.path.contains('/cards/')),
        hasLength(3),
      );
    });

    test('answers empty for a set the provider does not hold', () async {
      expect(await catalogWith().fetchCardsInSet('nope'), isEmpty);
    });
  });

  group('single cards', () {
    test('resolves a card by its TCGdex id', () async {
      final card = await catalogWith().fetchCardById('base1-4');

      expect(card, isNotNull);
      expect(card!.name, 'Charizard');
      expect(card.setCode, 'base1');
      expect(card.collectorNumber, '4');
      expect(card.cmc, 120);
      expect(card.colors, <String>['Fire']);
      expect(card.typeLine, 'Pokémon - Stage 2');
    });

    test('flattens attacks into readable rules text', () async {
      final card = await catalogWith().fetchCardById('base1-4');

      expect(card!.oracleText, contains('Fire Spin'));
      expect(card.oracleText, contains('Discard 2 Energy cards'));
    });

    test('answers null for a card the provider does not hold', () async {
      expect(await catalogWith().fetchCardById('base1-99'), isNull);
    });

    test('leaves the release date empty when only the card was fetched',
        () async {
      // Documented degradation: the card response carries no date, so a card
      // reached this way shows no date chip until its set is browsed.
      final card = await catalogWith().fetchCardById('base1-4');

      expect(card!.releasedAt, isNull);
    });
  });

  group('search', () {
    test('resolves each hit into a card worth showing', () async {
      final results = await catalogWith().search('charizard');

      expect(results, hasLength(2));
      expect(results.map((c) => c.name), <String>['Charizard', 'Pikachu']);
      // Relevance order, not the order the workers finished in.
      expect(results.first.rarity, 'Rare');
    });

    test('drops a hit it cannot resolve instead of failing the search',
        () async {
      final results = await catalogWith().search('anything');

      expect(results.every((c) => c.id != 'base1-99'), isTrue);
      expect(results, hasLength(2));
    });

    test('caps the detail calls one search will make', () async {
      // The provider matches over two hundred printings for a name like
      // "Pikachu"; every hit shown costs a request, so the ceiling is real.
      final many = StringBuffer('[');
      for (var i = 0; i < 200; i++) {
        if (i > 0) many.write(',');
        many.write('{"id":"base1-$i","localId":"$i","name":"Pikachu $i"}');
      }
      many.write(']');

      final requests = <Uri>[];
      await catalogWith(searchBody: many.toString(), requests: requests)
          .search('pikachu');

      final detailCalls = requests.where((u) => u.path.contains('/cards/'));
      expect(detailCalls.length, lessThanOrEqualTo(60));
      expect(detailCalls, isNotEmpty);
    });

    test('asks the provider for the name, which is all it can filter on',
        () async {
      final requests = <Uri>[];
      await catalogWith(requests: requests).search('charizard');

      final list = requests.firstWhere((u) => u.path.endsWith('/cards'));
      expect(list.queryParameters['name'], 'charizard');
    });

    test('answers empty when the search itself fails', () async {
      // A search is a convenience, never a reason to show an error screen.
      expect(await catalogWith(searchBody: null).search('charizard'), isEmpty);
    });
  });

  group('printings', () {
    test('reports none, because Pokemon reprints share a name', () async {
      // The repository falls back to the local cache, which keys reprints by
      // normalised name; there is no provider-side oracle id to query.
      expect(await catalogWith().fetchPrintingsOf('charizard'), isEmpty);
    });
  });

  group('game vocabulary', () {
    test('offers the finishes a Pokemon collector sorts by', () {
      expect(
        CardGame.pokemon.finishes,
        <CardFinish>[
          CardFinish.nonfoil,
          CardFinish.holofoil,
          CardFinish.reverseHolofoil,
          CardFinish.firstEdition,
          CardFinish.firstEditionHolofoil,
        ],
      );
    });

    test('addresses the set and card by TCGdex ids', () {
      final catalog = catalogWith();
      expect(catalog.game, CardGame.pokemon);
      expect(catalog.sourceName, 'TCGdex');
    });
  });
}
