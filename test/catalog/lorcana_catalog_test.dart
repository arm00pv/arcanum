// Tests for the Lorcast catalogue adapter.
//
//   flutter test test/catalog/lorcana_catalog_test.dart
//
// Nothing here touches the network. The adapter takes a Dio instance, so these
// tests hand it one backed by an adapter serving canned payloads, and answer
// 404 - the way Lorcast answers a set or a card it does not hold - for anything
// a test did not route.
//
// The fixtures are trimmed slices of live responses, kept awkward on purpose:
// the set list carries no card count, a set's cards arrive as one bare array,
// promo printings carry no tcgplayer_id (and so no JPEG art at all), prices
// arrive as decimal strings and are sometimes unparseable, and \`version\` is the
// only thing separating a dozen different cards called Elsa. Every one of those
// is a case where the Lorcana path degrades quietly rather than failing loudly,
// which is why they are pinned here.

import 'dart:typed_data';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/lorcana_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The id Lorcast gives one printing: \`crd_\` and thirty-two hex digits.
const String elsaId = 'crd_a6f3c215973844fc8ae5cbc2a4ea388f';

/// A promo printing's id. Promos are the cards with no TCGplayer product.
const String promoId = 'crd_94aea01bdb0a49a4aff52b8802388bb1';

/// The set list as Lorcast publishes it: ids, codes, names and dates, and no
/// card count - the only way to learn one is to download the set. The promo
/// runs are numbered \`P1\`, \`P2\`, ...; \`cp\` is a promo by name instead.
const String setsJson = '''
{"results":[
  {"id":"set_7ecb0e0c71af496a9e0110e23824e0a5","name":"The First Chapter",
   "code":"1","released_at":"2023-08-18","prereleased_at":"2023-08-04"},
  {"id":"set_c794231dfd4e3482a675ecece86dcc","name":"Winterspell",
   "code":"11","released_at":"2026-02-13","prereleased_at":"2026-02-06"},
  {"id":"set_c254adfcbf6d4e3482a675ecece86dcc","name":"Promo Set 1",
   "code":"P1","released_at":"2023-08-18","prereleased_at":null},
  {"id":"set_e0eb34fc0fbb446886f84c34381d4dce","name":"Challenge Promo",
   "code":"cp","released_at":"2024-05-17","prereleased_at":null}
]}
''';

/// Elsa, exactly as Lorcast returns her: one full card object with the ink, the
/// classifications, both prices as decimal strings, and the tcgplayer_id that
/// unlocks the JPEG art. Her subtitle is the only thing telling her apart from
/// the other Elsa in this file.
final String elsaJson = '''
{"id":"$elsaId","name":"Elsa","version":"Concerned Sister","layout":"normal",
 "released_at":"2026-02-13",
 "image_uris":{"digital":{
   "small":"https://cards.lorcast.io/card/digital/small/$elsaId.avif?1770259762",
   "normal":"https://cards.lorcast.io/card/digital/normal/$elsaId.avif?1770259762",
   "large":"https://cards.lorcast.io/card/digital/large/$elsaId.avif?1770259762"}},
 "cost":3,"inkwell":true,"ink":"Ruby","inks":["Ruby"],"type":["Character"],
 "classifications":["Storyborn","Hero","Queen","Sorcerer"],
 "text":"CLEAR THE WAY When you play this character, you pay 2 {I} less for the next location you play this turn.",
 "keywords":[],"move_cost":null,"strength":2,"willpower":2,"lore":2,
 "rarity":"Uncommon","illustrators":["Hollie Hibbert"],"collector_number":"125",
 "lang":"en","flavor_text":"Nothing is more important than family.",
 "tcgplayer_id":673302,"legalities":{"core":"legal"},
 "set":{"id":"set_c794231dfd","code":"11","name":"Winterspell"},
 "prices":{"usd":"0.12","usd_foil":"0.3"},
 "purchase_uris":{"tcgplayer":"https://www.tcgplayer.com/product/673302"}}
''';

/// Anna: quoted in one finish only, and a keyword that is not spelled out in
/// her rules text.
final String annaJson = '''
{"id":"crd_anna1","name":"Anna","version":"Heir to Arendelle","layout":"normal",
 "released_at":"2026-02-13",
 "image_uris":{"digital":{"small":"https://cards.lorcast.io/card/digital/small/crd_anna1.avif?1",
   "normal":"https://cards.lorcast.io/card/digital/normal/crd_anna1.avif?1",
   "large":"https://cards.lorcast.io/card/digital/large/crd_anna1.avif?1"}},
 "cost":2,"inkwell":true,"ink":"Amethyst","inks":["Amethyst"],
 "type":["Character"],"classifications":["Storyborn","Hero"],
 "text":"LET IT GO Whenever this character quests, ready another character.",
 "keywords":["Evasive"],"move_cost":null,"strength":1,"willpower":3,"lore":1,
 "rarity":"Common","illustrators":["Nicholas Kole"],"collector_number":"42",
 "lang":"en","flavor_text":null,"tcgplayer_id":673400,
 "legalities":{"core":"legal"},
 "set":{"id":"set_c794231dfd","code":"11","name":"Winterspell"},
 "prices":{"usd":"1.50"}}
''';

/// A Location: no strength, willpower or lore, but a move cost - and a price
/// the provider has published as text that is not a number.
final String icePalaceJson = '''
{"id":"crd_palace","name":"Elsa's Ice Palace","version":"Winter Palace",
 "layout":"normal","released_at":"2026-02-13",
 "image_uris":{"digital":{"small":"https://cards.lorcast.io/card/digital/small/crd_palace.avif?2",
   "normal":"https://cards.lorcast.io/card/digital/normal/crd_palace.avif?2",
   "large":"https://cards.lorcast.io/card/digital/large/crd_palace.avif?2"}},
 "cost":3,"inkwell":false,"ink":"Sapphire","inks":["Sapphire"],
 "type":["Location"],"classifications":[],
 "text":"ICE PALACE Characters here get +1 lore while questing.",
 "keywords":[],"move_cost":2,"strength":null,"willpower":null,"lore":null,
 "rarity":"Rare","illustrators":["Jenna Gray"],"collector_number":"204",
 "lang":"en","flavor_text":null,"tcgplayer_id":673500,
 "legalities":{"core":"legal"},
 "set":{"id":"set_c794231dfd","code":"11","name":"Winterspell"},
 "prices":{"usd":"not-a-number"}}
''';

/// A Song: two types, two inks, no subtitle at all, and no stats.
final String wholeNewWorldJson = '''
{"id":"crd_anw","name":"A Whole New World","version":null,"layout":"normal",
 "released_at":"2026-02-13",
 "image_uris":{"digital":{"small":"https://cards.lorcast.io/card/digital/small/crd_anw.avif?3",
   "normal":"https://cards.lorcast.io/card/digital/normal/crd_anw.avif?3",
   "large":"https://cards.lorcast.io/card/digital/large/crd_anw.avif?3"}},
 "cost":5,"inkwell":true,"ink":"Emerald","inks":["Emerald","Sapphire"],
 "type":["Action","Song"],"classifications":[],
 "text":"Each player discards their hand and draws 7 cards.",
 "keywords":[],"move_cost":null,"strength":null,"willpower":null,"lore":null,
 "rarity":"Super_rare","illustrators":["Ian MacDonald"],
 "collector_number":"130","lang":"en","flavor_text":null,"tcgplayer_id":673600,
 "legalities":{"core":"legal"},
 "set":{"id":"set_c794231dfd","code":"11","name":"Winterspell"},
 "prices":{"usd":"4.25","usd_foil":"11.00"}}
''';

/// A card whose ink Lorcast does not name among the six the game plays, which
/// must land in the uninked bucket rather than in an ink it is not.
final String mickeyJson = '''
{"id":"crd_mickey","name":"Mickey Mouse","version":"Brave Little Tailor",
 "layout":"normal","released_at":"2026-02-13",
 "image_uris":{"digital":{"small":"https://cards.lorcast.io/card/digital/small/crd_mickey.avif?4",
   "normal":"https://cards.lorcast.io/card/digital/normal/crd_mickey.avif?4",
   "large":"https://cards.lorcast.io/card/digital/large/crd_mickey.avif?4"}},
 "cost":8,"inkwell":true,"ink":"Rainbow","inks":["Rainbow"],
 "type":["Character"],"classifications":["Storyborn","Hero"],
 "text":"LET'S GET DOWN TO BUSINESS When you play this character, draw a card.",
 "keywords":[],"move_cost":null,"strength":3,"willpower":5,"lore":2,
 "rarity":"Legendary","illustrators":["Dave Beauchene"],
 "collector_number":"1","lang":"en","flavor_text":null,"tcgplayer_id":673700,
 "legalities":{"core":"legal"},
 "set":{"id":"set_c794231dfd","code":"11","name":"Winterspell"},
 "prices":{"usd":"22.40","usd_foil":"48.00"}}
''';

/// A set's cards arrive as a bare JSON array of full card objects, in whatever
/// order the provider keeps them, so one request carries everything a row needs.
final String winterspellJson =
    '[$mickeyJson,$annaJson,$elsaJson,$wholeNewWorldJson,$icePalaceJson]';

/// A promo printing, and the one shape with no TCGplayer product behind it: no
/// tcgplayer_id, no prices at all, and art that exists only as AVIF. Its
/// \`version\` is an empty string rather than null, which is the other way a card
/// arrives without a subtitle.
final String challengePromoJson = '''
[
 {"id":"$promoId","name":"A Whole New World","version":"","layout":"normal",
  "released_at":"2024-05-17",
  "image_uris":{"digital":{
    "small":"https://cards.lorcast.io/card/digital/small/$promoId.avif?1755566321",
    "normal":"https://cards.lorcast.io/card/digital/normal/$promoId.avif?1755566321",
    "large":"https://cards.lorcast.io/card/digital/large/$promoId.avif?1755566321"}},
  "cost":5,"inkwell":true,"ink":"Steel","inks":["Steel"],
  "type":["Action","Song"],"classifications":[],
  "text":"Each player discards their hand and draws 7 cards.",
  "keywords":[],"move_cost":null,"strength":null,"willpower":null,"lore":null,
  "rarity":"Promo","illustrators":["Ian MacDonald"],"collector_number":"10",
  "lang":"en","flavor_text":null,"tcgplayer_id":null,
  "legalities":{"core":"legal"},
  "set":{"id":"set_e0eb34fc","code":"cp","name":"Challenge Promo"},
  "prices":{}}
]
''';

/// A card from a numbered promo run, whose set code is the mixed-case "P1".
/// The provider answers to that spelling and not to "p1", while the app stores
/// and asks for the lowercase form.
const String promoRunJson = '''
[
 {"id":"crd_p1a","name":"Mickey Mouse","version":"Brave Little Tailor",
  "layout":"normal","released_at":"2023-08-18",
  "image_uris":{"digital":{
    "small":"https://cards.lorcast.io/card/digital/small/crd_p1a.avif?1",
    "normal":"https://cards.lorcast.io/card/digital/normal/crd_p1a.avif?1",
    "large":"https://cards.lorcast.io/card/digital/large/crd_p1a.avif?1"}},
  "cost":8,"inkwell":true,"ink":"Ruby","inks":["Ruby"],
  "type":["Character"],"classifications":["Dreamborn","Hero"],
  "text":"Evasive.","keywords":["Evasive"],"move_cost":null,
  "strength":3,"willpower":3,"lore":3,
  "rarity":"Promo","illustrators":["Nicholas Kole"],"collector_number":"1",
  "lang":"en","flavor_text":null,"tcgplayer_id":500001,
  "legalities":{"core":"legal"},
  "set":{"id":"set_c254adfc","code":"P1","name":"Promo Set 1"},
  "prices":{"usd":"4.50","usd_foil":"9.00"}}
]
''';

/// A second Elsa, from the same search: same name, different subtitle, so the
/// two must not group as one card.
final String snowQueenJson = '''
{"id":"crd_elsa2","name":"Elsa","version":"Snow Queen","layout":"normal",
 "released_at":"2023-08-18",
 "image_uris":{"digital":{"small":"https://cards.lorcast.io/card/digital/small/crd_elsa2.avif?5",
   "normal":"https://cards.lorcast.io/card/digital/normal/crd_elsa2.avif?5",
   "large":"https://cards.lorcast.io/card/digital/large/crd_elsa2.avif?5"}},
 "cost":6,"inkwell":true,"ink":"Amethyst","inks":["Amethyst"],
 "type":["Character"],"classifications":["Dreamborn","Hero","Queen"],
 "text":"FREEZE When you play this character, exert chosen character.",
 "keywords":[],"move_cost":null,"strength":4,"willpower":4,"lore":2,
 "rarity":"Legendary","illustrators":["Nicholas Kole"],
 "collector_number":"42","lang":"en","flavor_text":null,"tcgplayer_id":673900,
 "legalities":{"core":"legal"},
 "set":{"id":"set_7ecb0e0c","code":"1","name":"The First Chapter"},
 "prices":{"usd":"12.00","usd_foil":"31.50"}}
''';

/// Search answers with the same full card objects, so a hit costs no second
/// request - the whole of what a row shows is already in this response.
final String searchJson = '{"results":[$elsaJson,$snowQueenJson]}';

/// Serves canned payloads in place of the network.
class _FakeLorcastApi implements HttpClientAdapter {
  _FakeLorcastApi(this._respond, this.requests);

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
///
/// [searchFails] answers the search endpoint with a 404, which is how the
/// provider behaves when it is rate limiting or unreachable.
LorcanaCatalog catalogWith({
  String? setsBody = setsJson,
  Map<String, String>? bySet,
  Map<String, String>? byCard,
  String? searchBody,
  bool searchFails = false,
  List<Uri>? requests,
}) {
  final body = searchFails ? null : (searchBody ?? searchJson);
  final sets = bySet ??
      <String, String>{
        '11': winterspellJson,
        'cp': challengePromoJson,
        // Keyed by the spelling the request must carry, not the one the app
        // stores: a request for "p1" would not be routed at all.
        'P1': promoRunJson,
      };
  final cards = byCard ?? <String, String>{elsaId: elsaJson};
  final log = requests ?? <Uri>[];
  final dio = Dio(BaseOptions(baseUrl: 'https://api.lorcast.com/v0'));
  dio.httpClientAdapter = _FakeLorcastApi((Uri uri) {
    final path = uri.path;
    if (path.endsWith('/sets')) return setsBody;
    // Search is checked before the card route: both end in a path segment, and
    // \`/cards/search\` would otherwise be read as the id "search".
    if (path.endsWith('/cards/search')) return body;
    final setMatch = RegExp(r'/sets/([^/]+)/cards$').firstMatch(path);
    if (setMatch != null) return sets[setMatch.group(1)];
    final cardMatch = RegExp(r'/cards/([^/]+)$').firstMatch(path);
    if (cardMatch != null) return cards[cardMatch.group(1)];
    return null;
  }, log);
  return LorcanaCatalog(dio: dio);
}

void main() {
  group('set list', () {
    test('reads every set the provider lists', () async {
      final sets = await catalogWith().fetchAllSets();

      expect(sets, hasLength(4));
      expect(sets.first.code, '1');
      expect(sets.first.name, 'The First Chapter');
      expect(sets.first.game, CardGame.lorcana);
    });

    test('dates each set from the one release date the list carries', () async {
      final sets = await catalogWith().fetchAllSets();
      final winterspell = sets.firstWhere((s) => s.code == '11');

      expect(winterspell.releasedAt, DateTime(2026, 2, 13));
      expect(sets.first.releasedAt, DateTime(2023, 8, 18));
    });

    test('types promo codes as promo and core codes as expansion', () async {
      // A set-type filter is only worth offering if the split is real: the
      // numbered promo runs and the named event promos are promos, and every
      // retail set is an expansion.
      final sets = await catalogWith().fetchAllSets();
      String typeOf(String code) =>
          sets.firstWhere((s) => s.code == code).setType;

      expect(typeOf('p1'), 'promo');
      expect(typeOf('cp'), 'promo');
      expect(typeOf('1'), 'expansion');
      expect(typeOf('11'), 'expansion');
    });

    test('stores every set code in the casing the app queries with', () async {
      // Lorcast answers to "P1" and not "p1", but the rest of the app stores,
      // queries and compares codes in lowercase - the repository lowercases the
      // code before it asks for a set. Keeping the provider's casing here meant
      // nine promo and event sets were requested as "p1" and answered 404.
      final sets = await catalogWith().fetchAllSets();

      expect(sets.map((s) => s.code), contains('p1'));
      expect(sets.map((s) => s.code), isNot(contains('P1')));
      expect(sets.every((s) => s.code == s.code.toLowerCase()), isTrue);
    });

    test('reports progress once per set', () async {
      final seen = <(int, int)>[];
      await catalogWith().fetchAllSets(
        onProgress: (done, total) => seen.add((done, total)),
      );

      expect(seen.first, (0, 4));
      expect(seen.last, (4, 4));
      expect(seen.map((t) => t.$2).every((total) => total == 4), isTrue);
    });
  });

  group('cards in a set', () {
    test('asks for a set in the casing the provider needs', () async {
      // The caller hands over the lowercase code the app stores; the request
      // has to carry the provider's own spelling or the set comes back empty.
      final requests = <Uri>[];
      final cards = await catalogWith(requests: requests).fetchCardsInSet('p1');

      expect(
        requests.any((u) => u.path.endsWith('/sets/P1/cards')),
        isTrue,
      );
      expect(
        requests.any((u) => u.path.endsWith('/sets/p1/cards')),
        isFalse,
      );
      expect(cards, isNotEmpty);
    });

    test('stamps the cards it downloads with the lowercase code', () async {
      // Cards stamped with the provider's casing would be stored under a code
      // the set screen never asks for, so the set would look empty even after a
      // successful download.
      final cards = await catalogWith().fetchCardsInSet('p1');

      expect(cards, isNotEmpty);
      expect(cards.every((c) => c.setCode == 'p1'), isTrue);
    });

    test('maps both prices onto the two finishes Lorcana prints', () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);

      // The provider sends decimal strings, not numbers.
      expect(elsa.prices.priceFor(CardFinish.nonfoil), 0.12);
      expect(elsa.prices.priceFor(CardFinish.foil), 0.3);
      expect(elsa.game, CardGame.lorcana);
    });

    test('combines the name with the subtitle that tells printings apart',
        () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);

      // "Elsa" alone is ambiguous between a dozen unrelated cards, so the
      // subtitle is part of the name and part of the oracle id.
      expect(elsa.name, 'Elsa – Concerned Sister');
      expect(elsa.oracleId, TcgCard.normaliseName('Elsa – Concerned Sister'));
    });

    test('leaves the name alone when the card has no subtitle', () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final song = cards.firstWhere((c) => c.id == 'crd_anw');

      expect(song.name, 'A Whole New World');
      expect(song.oracleId, 'a whole new world');
    });

    test('reads the inks a card is played from', () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);
      final song = cards.firstWhere((c) => c.id == 'crd_anw');

      expect(elsa.colors, <String>['Ruby']);
      expect(elsa.colorIdentity, <String>['Ruby']);
      // A handful of cards are two inks, and both are kept.
      expect(song.colors, <String>['Emerald', 'Sapphire']);
    });

    test('reads the collector number, rarity, cost, set and release date',
        () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);

      expect(elsa.collectorNumber, '125');
      expect(elsa.rarity, 'Uncommon');
      expect(elsa.cmc, 3);
      expect(elsa.setCode, '11');
      expect(elsa.setName, 'Winterspell');
      // The card carries its own date, so it has one without the set list.
      expect(elsa.releasedAt, DateTime(2026, 2, 13));
    });

    test('takes the art from the TCGplayer JPEG, never the AVIF', () async {
      // Lorcast serves AVIF only and Flutter cannot be relied on to decode it,
      // so a card with a tcgplayer_id is illustrated from the CDN that serves
      // the same art as JPEG.
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);

      expect(
        elsa.imageUrl(size: 'normal'),
        'https://tcgplayer-cdn.tcgplayer.com/product/673302_400w.jpg',
      );
      expect(
        elsa.imageUrl(size: 'small'),
        'https://tcgplayer-cdn.tcgplayer.com/product/673302_200w.jpg',
      );
      expect(
        elsa.imageUrl(size: 'large'),
        'https://tcgplayer-cdn.tcgplayer.com/product/673302_in_1000x1000.jpg',
      );
      expect(elsa.imageUrl(size: 'normal'), isNot(contains('.avif')));
    });

    test('falls back to the provider URL for a promo with no TCGplayer id',
        () async {
      // Promos have no TCGplayer product, so the AVIF Lorcast serves is the
      // only art that exists for them. This is the one case where it is used.
      final cards = await catalogWith().fetchCardsInSet('cp');
      final promo = cards.firstWhere((c) => c.id == promoId);

      expect(
        promo.imageUrl(size: 'normal'),
        'https://cards.lorcast.io/card/digital/normal/$promoId.avif?1755566321',
      );
      expect(promo.extras['tcgplayerId'], isNull);
      expect(promo.name, 'A Whole New World');
    });

    test('composes the type line from the type and the classifications',
        () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);
      final song = cards.firstWhere((c) => c.id == 'crd_anw');

      expect(elsa.typeLine, 'Character - Storyborn, Hero, Queen, Sorcerer');
      // A Song has no classifications, and so no dash.
      expect(song.typeLine, 'Action, Song');
    });

    test('appends keywords to the rules text', () async {
      // "Evasive" is printed on the card but is not spelled out in the text,
      // and search reads this field.
      final cards = await catalogWith().fetchCardsInSet('11');
      final anna = cards.firstWhere((c) => c.id == 'crd_anna1');

      expect(anna.oracleText, contains('LET IT GO'));
      expect(anna.oracleText, contains('Evasive'));
    });

    test('keeps the stats a character has and the move cost a location has',
        () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);
      final palace = cards.firstWhere((c) => c.id == 'crd_palace');

      expect(elsa.extras['inkwell'], isTrue);
      expect(elsa.extras['strength'], 2);
      expect(elsa.extras['willpower'], 2);
      expect(elsa.extras['lore'], 2);
      expect(elsa.extras['classifications'],
          <String>['Storyborn', 'Hero', 'Queen', 'Sorcerer']);
      expect(elsa.extras['legalities'], <String, Object?>{'core': 'legal'});

      // A Location has a move cost and no strength at all, so the stat keys
      // are absent rather than zero.
      expect(palace.extras['moveCost'], 2);
      expect(palace.extras.containsKey('strength'), isFalse);
      expect(palace.artist, 'Jenna Gray');
    });

    test('leaves a finish unpriced when the provider quotes only the other',
        () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final anna = cards.firstWhere((c) => c.id == 'crd_anna1');

      expect(anna.prices.priceFor(CardFinish.nonfoil), 1.5);
      expect(anna.prices.priceFor(CardFinish.foil), isNull);
    });

    test('turns an unparseable price into null rather than zero', () async {
      // A card the provider has no market for is unpriced: showing it as $0.00
      // would sort it to the bottom of every value list and read as a quote.
      final cards = await catalogWith().fetchCardsInSet('11');
      final palace = cards.firstWhere((c) => c.id == 'crd_palace');

      expect(palace.prices.priceFor(CardFinish.nonfoil), isNull);
      expect(palace.prices.priceFor(CardFinish.foil), isNull);
      expect(palace.prices.priceFor(CardFinish.nonfoil), isNot(0));
      expect(palace.prices.isEmpty, isTrue);
    });

    test('spells a rarity the way a collector writes it', () async {
      // The wire value is "Super_rare"; the badge and the rarity filter both
      // show this string, so the separator is normalised rather than leaking a
      // wire artefact into the UI.
      final cards = await catalogWith().fetchCardsInSet('11');
      final superRare = cards.firstWhere((c) => c.collectorNumber == '130');

      expect(superRare.rarity, 'Super Rare');
      expect(cards.every((c) => !c.rarity.contains('_')), isTrue);
    });

    test('reads a promotional printing with no prices at all', () async {
      final cards = await catalogWith().fetchCardsInSet('cp');
      final promo = cards.single;

      expect(promo.prices.priceFor(CardFinish.nonfoil), isNull);
      expect(promo.prices.priceFor(CardFinish.foil), isNull);
      expect(promo.releasedAt, DateTime(2024, 5, 17));
      expect(promo.rarity, 'Promo');
    });

    test('orders a set by collector number', () async {
      final cards = await catalogWith().fetchCardsInSet('11');

      expect(
        cards.map((c) => c.collectorNumber),
        <String>['1', '42', '125', '130', '204'],
      );
    });

    test('downloads the whole set in one request, not one per card', () async {
      final requests = <Uri>[];
      await catalogWith(requests: requests).fetchCardsInSet('11');

      expect(
        requests.where((u) => RegExp(r'/sets/11/cards$').hasMatch(u.path)),
        hasLength(1),
      );
      // Nothing is fetched per card: the set response already holds every
      // field a row shows, prices included.
      expect(requests.where((u) => RegExp(r'/cards/[^/]+$').hasMatch(u.path)),
          isEmpty);
      // The second call is the one-off set-list read that teaches the adapter
      // the provider's own casing for set codes. It happens at most once per
      // process, never per set and never per card.
      expect(requests.where((u) => u.path.endsWith('/sets')), hasLength(1));
      expect(requests, hasLength(2));
    });

    test('reads the set list once however many sets are opened', () async {
      final requests = <Uri>[];
      final catalog = catalogWith(requests: requests);

      await catalog.fetchCardsInSet('11');
      await catalog.fetchCardsInSet('cp');
      await catalog.fetchCardsInSet('p1');

      expect(requests.where((u) => u.path.endsWith('/sets')), hasLength(1));
    });

    test('still resolves a numbered set with no help from the set list',
        () async {
      // The fallback matters when the list cannot be read at all: a numbered
      // code is the same string in either casing, so it must not become
      // undownloadable just because the lookup failed.
      final requests = <Uri>[];
      final cards = await catalogWith(setsBody: null, requests: requests)
          .fetchCardsInSet('11');

      expect(cards, isNotEmpty);
      expect(
        requests.any((u) => RegExp(r'/sets/11/cards$').hasMatch(u.path)),
        isTrue,
      );
    });

    test('answers empty for a set the provider does not hold', () async {
      expect(await catalogWith().fetchCardsInSet('nope'), isEmpty);
    });
  });

  group('single cards', () {
    test('resolves a card by its Lorcast id', () async {
      final card = await catalogWith().fetchCardById(elsaId);

      expect(card, isNotNull);
      expect(card!.name, 'Elsa – Concerned Sister');
      expect(card.setCode, '11');
      expect(card.setName, 'Winterspell');
      expect(card.collectorNumber, '125');
      expect(card.cmc, 3);
      expect(card.colors, <String>['Ruby']);
      expect(card.typeLine, 'Character - Storyborn, Hero, Queen, Sorcerer');
    });

    test('dates a card fetched by id, because the card carries its own date',
        () async {
      final card = await catalogWith().fetchCardById(elsaId);

      expect(card!.releasedAt, DateTime(2026, 2, 13));
    });

    test('answers null for a card the provider does not hold', () async {
      expect(await catalogWith().fetchCardById('crd_missing'), isNull);
    });
  });

  group('search', () {
    test('resolves each hit without a second request per hit', () async {
      final requests = <Uri>[];
      final results = await catalogWith(requests: requests).search('elsa');

      // Results arrive as full cards, so a hit is showable as it lands.
      expect(results.map((c) => c.name),
          <String>['Elsa – Concerned Sister', 'Elsa – Snow Queen']);
      expect(results.first.rarity, 'Uncommon');
      expect(results.first.prices.priceFor(CardFinish.nonfoil), 0.12);
      // The search call itself is the only request: no hit is re-fetched by id.
      final perCard = requests.where((u) =>
          RegExp(r'/cards/[^/]+$').hasMatch(u.path) &&
          !u.path.endsWith('/cards/search'));
      expect(perCard, isEmpty);
      expect(requests, hasLength(1));
    });

    test('keeps two cards called Elsa apart', () async {
      // Grouping printings by the bare name would merge unrelated cards, so
      // the oracle id is built from the name and the subtitle together.
      final results = await catalogWith().search('elsa');

      expect(results, hasLength(2));
      expect(results.first.oracleId, isNot(results.last.oracleId));
      expect(results.last.oracleId,
          TcgCard.normaliseName('Elsa – Snow Queen'));
    });

    test('asks the provider for the term it searches', () async {
      final requests = <Uri>[];
      await catalogWith(requests: requests).search('elsa');

      final search =
          requests.firstWhere((u) => u.path.endsWith('/cards/search'));
      expect(search.queryParameters['q'], 'elsa');
    });

    test('honours the ceiling the caller asked for', () async {
      final results = await catalogWith().search('elsa', limit: 1);

      expect(results, hasLength(1));
      expect(results.single.name, 'Elsa – Concerned Sister');
    });

    test('answers empty when the search itself fails', () async {
      // A search is a convenience, never a reason to show an error screen.
      expect(await catalogWith(searchFails: true).search('elsa'), isEmpty);
    });
  });

  group('printings', () {
    test('reports none, because Lorcast reprints across sets', () async {
      // The repository falls back to the local cache, which keys reprints by
      // the oracle id this catalogue writes onto each card.
      expect(await catalogWith().fetchPrintingsOf('elsa concerned sister'),
          isEmpty);
    });
  });

  group('refreshing prices', () {
    test('re-reads each printing by id', () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final elsa = cards.firstWhere((c) => c.id == elsaId);

      final requests = <Uri>[];
      final fresh = await catalogWith(requests: requests).refreshPrices([elsa]);

      expect(fresh, hasLength(1));
      expect(fresh.single.id, elsaId);
      expect(fresh.single.prices.priceFor(CardFinish.nonfoil), 0.12);
      expect(
        requests.where((u) => RegExp(r'/cards/[^/]+$').hasMatch(u.path)),
        hasLength(1),
      );
    });

    test('does nothing when there is nothing to refresh', () async {
      expect(await catalogWith().refreshPrices(const []), isEmpty);
    });
  });

  group('game vocabulary', () {
    test('offers the two finishes a Lorcana collector sorts by', () {
      expect(
        CardGame.lorcana.finishes,
        <CardFinish>[CardFinish.nonfoil, CardFinish.foil],
      );
    });

    test('buckets an ink the provider does not name as uninked', () async {
      final cards = await catalogWith().fetchCardsInSet('11');
      final mickey = cards.firstWhere((c) => c.id == 'crd_mickey');

      // Guessing one of the six would paint that ink's slice of the allocation
      // chart with a card that is not in it.
      expect(mickey.colors, <String>['Rainbow']);
      expect(
        CardGame.lorcana.bucketFor(mickey.colors.first),
        LorcanaInk.inconsolable,
      );
      expect(CardGame.lorcana.bucketFor('Rainbow'), LorcanaInk.inconsolable);
    });

    test('addresses the set and card by Lorcast ids', () {
      final catalog = catalogWith();
      expect(catalog.game, CardGame.lorcana);
      expect(catalog.sourceName, 'Lorcast');
    });
  });
}
