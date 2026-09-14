// Tests for the tcgcsv catalogue adapter, which serves One Piece, Star Wars:
// Unlimited, Digimon, Dragon Ball Super: Fusion World and Gundam.
//
//   flutter test test/catalog/tcgcsv_catalog_test.dart
//
// Nothing here touches the network. The adapter takes a Dio instance, so these
// tests hand it one backed by an adapter serving canned payloads recorded from
// the live service, and answer 404 for anything a test did not route.
//
// The fixtures are trimmed slices of live responses, kept awkward on purpose:
// a booster box sits in the same product list as the cards and carries no
// collector number, a One Piece product's name has its number glued into it, a
// parallel art is a second product sharing the first one's number, a Digimon
// number carries its rarity on the end, a Star Wars: Unlimited number is a
// fraction of the set, and one product is quoted in foil only. Every one of
// those is a case where the parsing has to be right rather than lucky.

import 'dart:typed_data';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/tcgcsv_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The One Piece group list, trimmed: a booster set, a starter deck and a
/// release event run, whose abbreviations are spelled the way the shop spells
/// them and not the way the cards print them.
const String onePieceGroupsJson = '''
{"results":[
  {"groupId":3188,"name":"Romance Dawn","abbreviation":"OP01",
   "isSupplemental":false,"publishedOn":"2022-12-02T00:00:00"},
  {"groupId":24749,"name":"Starter Deck 31: RED Monkey.D.Luffy",
   "abbreviation":"ST-31","isSupplemental":false,
   "publishedOn":"2026-01-16T00:00:00"},
  {"groupId":24834,"name":"The Dominance of God Release Event Cards",
   "abbreviation":"OP18 RE","isSupplemental":false,
   "publishedOn":"2026-11-13T00:00:00"}
]}
''';

/// Romance Dawn's products: a booster pack with no collector number, two
/// cards, and a parallel art of the first - a separate product, with its own
/// id, carrying the same printed number.
const String onePieceProductsJson = '''
{"results":[
  {"productId":450085,"name":"Romance Dawn - Booster Pack",
   "cleanName":"Romance Dawn Booster Pack",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/450085_200w.jpg",
   "categoryId":68,"groupId":3188,"extendedData":[]},
  {"productId":453505,"name":"Trafalgar Law (002)",
   "cleanName":"Trafalgar Law 002",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/453505_200w.jpg",
   "categoryId":68,"groupId":3188,
   "extendedData":[
     {"name":"Rarity","value":"L"},
     {"name":"Number","value":"OP01-002"},
     {"name":"Description","value":"[Activate:Main] <em>(You may rest DON!!)</em>:<br>If you have 5 Characters, return 1.<br><br>"},
     {"name":"Color","value":"Green;Red"},
     {"name":"CardType","value":"Leader"},
     {"name":"Life","value":"4"},
     {"name":"Subtypes","value":"Heart Pirates;Supernovas"}]},
  {"productId":453506,"name":"Trafalgar Law (002) (Parallel)",
   "cleanName":"Trafalgar Law 002 Parallel",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/453506_200w.jpg",
   "categoryId":68,"groupId":3188,
   "extendedData":[
     {"name":"Rarity","value":"L"},
     {"name":"Number","value":"OP01-002"},
     {"name":"Description","value":"[Activate:Main] <em>(You may rest DON!!)</em>:<br>If you have 5 Characters, return 1.<br><br>"},
     {"name":"Color","value":"Green;Red"},
     {"name":"CardType","value":"Leader"},
     {"name":"Subtypes","value":"Heart Pirates;Supernovas"}]},
  {"productId":453600,"name":"Nami (010)",
   "cleanName":"Nami 010",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/453600_200w.jpg",
   "categoryId":68,"groupId":3188,
   "extendedData":[
     {"name":"Rarity","value":"C"},
     {"name":"Number","value":"OP01-010"},
     {"name":"Description","value":"[On Play] Draw 1 card."},
     {"name":"Color","value":"Blue"},
     {"name":"CardType","value":"Character"},
     {"name":"Cost","value":"3"},
     {"name":"Subtypes","value":"Straw Hat Crew"}]}
]}
''';

/// Romance Dawn's prices: both finishes on the leader, the parallel art quoted
/// in foil only and above the original, and nothing at all for the box.
const String onePiecePricesJson = '''
{"results":[
  {"productId":453505,"lowPrice":1.44,"midPrice":2.20,"highPrice":8.00,
   "marketPrice":2.14,"directLowPrice":null,"subTypeName":"Normal"},
  {"productId":453505,"lowPrice":3.10,"midPrice":3.40,"highPrice":9.00,
   "marketPrice":3.46,"directLowPrice":null,"subTypeName":"Foil"},
  {"productId":453506,"lowPrice":1250.0,"midPrice":1300.0,"highPrice":1500.0,
   "marketPrice":999.52,"directLowPrice":null,"subTypeName":"Foil"},
  {"productId":453600,"lowPrice":0.10,"midPrice":0.15,"highPrice":0.40,
   "marketPrice":0.12,"directLowPrice":null,"subTypeName":"Normal"}
]}
''';

/// A starter deck's products, where the same card is numbered against another
/// set - which is what a scan of it reads off the card.
const String starterProductsJson = '''
{"results":[
  {"productId":700001,"name":"Monkey.D.Luffy (001)",
   "cleanName":"Monkey D Luffy 001",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/700001_200w.jpg",
   "categoryId":68,"groupId":24749,
   "extendedData":[
     {"name":"Rarity","value":"L"},
     {"name":"Number","value":"ST31-001"},
     {"name":"Color","value":"Red"},
     {"name":"CardType","value":"Leader"}]}
]}
''';

/// Star Wars: Unlimited's group list, where the abbreviation is the set code
/// the cards do not print.
const String swuGroupsJson = '''
{"results":[
  {"groupId":24660,"name":"Ashes of the Empire","abbreviation":"ASH",
   "isSupplemental":false,"publishedOn":"2025-03-14T00:00:00"}
]}
''';

/// An Unlimited card: a number as a fraction of the set, and an aspect field
/// that holds an aspect and an alignment at once.
const String swuProductsJson = '''
{"results":[
  {"productId":800001,"name":"Grand Admiral Thrawn",
   "cleanName":"Grand Admiral Thrawn",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/800001_200w.jpg",
   "categoryId":79,"groupId":24660,
   "extendedData":[
     {"name":"Rarity","value":"Legendary"},
     {"name":"Number","value":"94/264"},
     {"name":"Description","value":"When Played: draw a card."},
     {"name":"Aspect","value":"Command;Villainy"},
     {"name":"CardType","value":"Leader"},
     {"name":"Traits","value":"Imperial;Officer"},
     {"name":"Cost","value":"5"}]}
]}
''';

/// Digimon's group list: the provider spells the set 'BT-26' and the card
/// prints 'BT26-052'.
const String digimonGroupsJson = '''
{"results":[
  {"groupId":24623,"name":"Timeless Bonds","abbreviation":"BT-26",
   "isSupplemental":false,"publishedOn":"2026-06-26T00:00:00"}
]}
''';

/// A Digimon card: a number with the rarity stuck on the end, and the game's
/// own fields.
const String digimonProductsJson = '''
{"results":[
  {"productId":900001,"name":"Agumon",
   "cleanName":"Agumon",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/900001_200w.jpg",
   "categoryId":63,"groupId":24623,
   "extendedData":[
     {"name":"Rarity","value":"Common"},
     {"name":"Number","value":"BT26-052 C"},
     {"name":"Description","value":"[On Play] Draw 1."},
     {"name":"Color","value":"Red"},
     {"name":"CardType","value":"Digimon"},
     {"name":"LevelLv","value":"3"},
     {"name":"PlayCost","value":"3"},
     {"name":"DigimonForm","value":"Rookie"},
     {"name":"DigimonType","value":"Reptile"}]}
]}
''';

/// A set the provider lists twice: Digimon's Timeless Bonds and its release
/// event cards share the abbreviation BT-26, and both runs print BT26.
const String sharedCodeGroupsJson = '''
{"results":[
  {"groupId":24623,"name":"Timeless Bonds","abbreviation":"BT-26",
   "isSupplemental":false,"publishedOn":"2026-06-26T00:00:00"},
  {"groupId":24824,"name":"Timeless Bonds Release Event Cards",
   "abbreviation":"BT-26","isSupplemental":false,
   "publishedOn":"2026-08-28T00:00:00"}
]}
''';

/// The release event run's own product list, numbered with the set it belongs
/// to rather than with a set of its own.
const String releaseEventProductsJson = '''
{"results":[
  {"productId":900002,"name":"Agumon (Release Event)",
   "cleanName":"Agumon Release Event",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/900002_200w.jpg",
   "categoryId":63,"groupId":24824,
   "extendedData":[
     {"name":"Rarity","value":"None"},
     {"name":"Number","value":"BT26-010 C"},
     {"name":"Color","value":"Red"},
     {"name":"CardType","value":"Digimon"},
     {"name":"PlayCost","value":"4"},
     {"name":"DigimonForm","value":"Rookie"}]}
]}
''';

/// Fusion World's group list: the shop spells the set 'FB-11' and the card
/// prints 'FB11-073'.
const String dragonBallGroupsJson = '''
{"results":[
  {"groupId":24716,"name":"Brightness of Hope","abbreviation":"FB-11",
   "isSupplemental":false,"publishedOn":"2026-08-28T00:00:00"}
]}
''';

/// A Fusion World Leader: the number the card prints, the colour that gates the
/// deck it goes in, and a trait field the other games do not have.
const String dragonBallProductsJson = '''
{"results":[
  {"productId":701195,"name":"Shallot/Giblet // Shallet",
   "cleanName":"Shallot Giblet Shallet",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/701195_200w.jpg",
   "categoryId":80,"groupId":24716,
   "extendedData":[
     {"name":"Rarity","value":"Leader"},
     {"name":"Number","value":"FB11-073"},
     {"name":"Description","value":"[Auto] When this card is placed in your Leader Area."},
     {"name":"Color","value":"Yellow"},
     {"name":"CardType","value":"Leader"},
     {"name":"Cost","value":"0"},
     {"name":"Power","value":"15000/20000"},
     {"name":"Character Traits","value":"Saiyan;God"}]}
]}
''';

/// Gundam's group list, spelled 'ST-11' by the shop and printed 'ST11-001'.
const String gundamGroupsJson = '''
{"results":[
  {"groupId":24800,"name":"Starter Deck 11: Aquatic Assault",
   "abbreviation":"ST-11","isSupplemental":false,
   "publishedOn":"2026-05-15T00:00:00"}
]}
''';

/// A Gundam unit: two colours, a level, a zone it may be deployed to, a pilot
/// that links to it and a rarity code carrying a treatment's plus signs.
const String gundamProductsJson = '''
{"results":[
  {"productId":716364,"name":"Char's Z'Gok",
   "cleanName":"Char s Z Gok",
   "imageUrl":"https://tcgplayer-cdn.tcgplayer.com/product/716364_200w.jpg",
   "categoryId":86,"groupId":24800,
   "extendedData":[
     {"name":"Rarity","value":"LR++"},
     {"name":"Number","value":"ST11-001"},
     {"name":"Description","value":"[During Pair] While 2 or more other friendly (Marine) Units are in play."},
     {"name":"Level","value":"4"},
     {"name":"Cost","value":"3"},
     {"name":"CardType","value":"Unit"},
     {"name":"Color","value":"Blue;Green"},
     {"name":"Trait","value":"(Zeon) (Marine)"},
     {"name":"Link Condition","value":"[Char Aznable]"},
     {"name":"Attack Points","value":"3"},
     {"name":"Hit Points","value":"3"},
     {"name":"Zone","value":"Earth;Space"}]}
]}
''';

/// Serves canned payloads in place of the network.
class _FakeTcgcsv implements HttpClientAdapter {
  _FakeTcgcsv(this._respond, this.requests);

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
    final body = _respond(uri);
    final reply = <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    };
    if (body == null) {
      return ResponseBody.fromString(
        '{"error":"not found"}',
        404,
        headers: reply,
      );
    }
    return ResponseBody.fromString(body, 200, headers: reply);
  }

  @override
  void close({bool force = false}) {}
}

/// Builds a catalogue wired to those payloads.
///
/// [fail] makes every request answer 404, which is how the provider answers a
/// set it does not hold.
TcgcsvCatalog catalogWith({
  CardGame game = CardGame.onePiece,
  String groups = onePieceGroupsJson,
  String products = onePieceProductsJson,
  String prices = onePiecePricesJson,
  bool fail = false,
  List<Uri>? requests,
}) {
  final adapter = _FakeTcgcsv((Uri uri) {
    if (fail) return null;
    final path = uri.path;
    if (path.endsWith('/groups')) return groups;
    if (path.endsWith('/products')) return products;
    if (path.endsWith('/prices')) return prices;
    return null;
  }, requests ?? <Uri>[]);
  final dio = Dio(BaseOptions(baseUrl: 'https://tcgcsv.com/tcgplayer'));
  dio.httpClientAdapter = adapter;
  return switch (game) {
    CardGame.starWarsUnlimited => TcgcsvCatalog.starWarsUnlimited(dio: dio),
    CardGame.digimon => TcgcsvCatalog.digimon(dio: dio),
    CardGame.dragonBall => TcgcsvCatalog.dragonBall(dio: dio),
    CardGame.gundam => TcgcsvCatalog.gundam(dio: dio),
    _ => TcgcsvCatalog.onePiece(dio: dio),
  };
}

void main() {
  group('sets', () {
    test('are coded the way the card prints them, not the way the shop spells them', () async {
      final catalog = catalogWith();
      final sets = await catalog.fetchAllSets();

      expect(sets.map((TcgSet s) => s.code), <String>[
        'op01',
        'st31',
        'op18re',
      ]);
      expect(sets.map((TcgSet s) => s.name), <String>[
        'Romance Dawn',
        'Starter Deck 31: RED Monkey.D.Luffy',
        'The Dominance of God Release Event Cards',
      ]);
      // The group id is what addresses the set at the provider.
      expect(sets.first.id, '3188');
      expect(sets.first.releasedAt, DateTime(2022, 12, 2));
      expect(sets.first.game, CardGame.onePiece);
    });

    test('are typed from the provider naming', () async {
      final sets = await catalogWith().fetchAllSets();
      expect(sets.map((TcgSet s) => s.setType), <String>[
        'expansion',
        'starter',
        'promo',
      ]);
    });

    test('are asked for once and remembered', () async {
      final requests = <Uri>[];
      final catalog = catalogWith(requests: requests);
      await catalog.fetchAllSets();
      await catalog.fetchCardsInSet('op01');
      // The card download needs the group id, which comes from the set list.
      expect(requests.where((Uri u) => u.path.endsWith('/groups')).length, 1);
    });

    test(
      'that do not exist answer with nothing rather than an error',
      () async {
        final cards = await catalogWith().fetchCardsInSet('nope');
        expect(cards, isEmpty);
      },
    );
  });

  group('one piece cards', () {
    test('drop the sealed product that shares their set', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');

      // The booster pack is in the same list and carries no collector number,
      // which is the structural test that keeps a box out of a binder.
      expect(cards, hasLength(3));
      expect(
        cards.map((TcgCard c) => c.name),
        isNot(contains('Romance Dawn - Booster Pack')),
      );
    });

    test('are ordered by the number printed on them', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');
      expect(cards.map((TcgCard c) => c.collectorNumber), <String>[
        '002',
        '002',
        '010',
      ]);
    });

    test('carry the name without the number glued into it', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');
      final names = cards.map((TcgCard c) => c.name).toSet();
      // The number in the brackets is already the collector number; the art
      // variant is not, and stays.
      expect(names, <String>{
        'Trafalgar Law',
        'Trafalgar Law (Parallel)',
        'Nami',
      });
    });

    test('read the provider short rarity codes as real tiers', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');
      // Live One Piece rarities are C, UC, R, SR, L, SEC and DON!!, and not one
      // of them contains a word the rarity table matches on: without reading the
      // codes every One Piece card wore a grey Unknown badge.
      expect(CardRarity.fromCode('C'), CardRarity.common);
      expect(CardRarity.fromCode('UC'), CardRarity.uncommon);
      expect(CardRarity.fromCode('R'), CardRarity.rare);
      expect(CardRarity.fromCode('SR'), CardRarity.rare);
      expect(CardRarity.fromCode('L'), CardRarity.mythic);
      expect(CardRarity.fromCode('SEC'), CardRarity.mythic);
      expect(CardRarity.fromCode('DON!!'), CardRarity.bonus);
      // Digimon publishes words, bar one: a printing outside the ladder.
      expect(CardRarity.fromCode('None'), CardRarity.special);
      expect(CardRarity.fromCode('Ultimate Rare'), CardRarity.rare);
      expect(CardRarity.fromCode('Secret Rare'), CardRarity.mythic);
      expect(
        cards.map((TcgCard c) => CardRarity.fromCode(c.rarity)).toSet(),
        <CardRarity>{CardRarity.mythic, CardRarity.common},
      );
    });

    test('carry their colours, type line and text', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');
      final leader = cards.first;

      expect(leader.game, CardGame.onePiece);
      expect(leader.id, '3188-453505');
      expect(leader.setCode, 'op01');
      expect(leader.setName, 'Romance Dawn');
      expect(leader.rarity, 'L');
      // Two colours, in the order the card prints them.
      expect(leader.colors, <String>['Green', 'Red']);
      expect(leader.colorIdentity, <String>['Green', 'Red']);
      // Sub-types are printed with slashes and the provider sends semicolons.
      expect(leader.typeLine, 'Leader - Heart Pirates / Supernovas');
      // The provider's letter for the tier: a One Piece Leader is the top of the
      // ladder, and 'L' shares no word with any rarity the other games use.
      expect(CardRarity.fromCode(leader.rarity), CardRarity.mythic);
      expect(leader.cmc, isNull);
      // The provider's markup comes out: it is displayed and searched.
      expect(leader.oracleText, isNot(contains('<')));
      expect(leader.oracleText, contains('If you have 5 Characters'));
      expect(leader.extras['printedNumber'], 'OP01-002');
      expect(leader.extras['cardType'], 'Leader');
      expect(leader.extras['Life'], '4');
    });

    test('carry art on the shop CDN, at three sizes', () async {
      final cards = await catalogWith().fetchCardsInSet('op01');
      expect(cards.first.imageUrl(), contains('/453505_400w.jpg'));
      expect(cards.first.imageUrl(size: 'small'), contains('_200w.jpg'));
      expect(cards.first.imageUrl(size: 'large'), contains('_in_1000x1000'));
    });

    test(
      'are priced per finish, and unpriced where the shop is silent',
      () async {
        final cards = await catalogWith().fetchCardsInSet('op01');
        final leader = cards.firstWhere((TcgCard c) => c.id == '3188-453505');
        final parallel = cards.firstWhere((TcgCard c) => c.id == '3188-453506');
        final nami = cards.firstWhere((TcgCard c) => c.id == '3188-453600');

        expect(leader.prices.priceFor(CardFinish.nonfoil), 2.14);
        expect(leader.prices.priceFor(CardFinish.foil), 3.46);
        // A parallel art quoted in foil only is a foil card, not a card priced
        // twice.
        expect(parallel.prices.priceFor(CardFinish.foil), 999.52);
        expect(parallel.prices.priceFor(CardFinish.nonfoil), isNull);
        expect(nami.prices.priceFor(CardFinish.foil), isNull);
        // A null quote is an absence, never a zero.
        expect(nami.prices.quotedFinishes, <CardFinish>[CardFinish.nonfoil]);
      },
    );

    test(
      'group reprints of one card without merging two different cards',
      () async {
        final cards = await catalogWith().fetchCardsInSet('op01');
        final leader = cards.firstWhere((TcgCard c) => c.id == '3188-453505');
        final parallel = cards.firstWhere((TcgCard c) => c.id == '3188-453506');
        final nami = cards.firstWhere((TcgCard c) => c.id == '3188-453600');

        // Two arts of one Leader are the same card to a collector.
        expect(parallel.oracleId, leader.oracleId);
        expect(nami.oracleId, isNot(leader.oracleId));
        expect(leader.oracleId, contains('trafalgar'));
        expect(leader.oracleId, contains('leader'));
      },
    );

    test('are fetched by id alone, without a search', () async {
      final catalog = catalogWith();
      final card = await catalog.fetchCardById('3188-453600');
      expect(card?.name, 'Nami');
      expect(card?.setCode, 'op01');
      expect(await catalog.fetchCardById('not-an-id'), isNull);
      expect(await catalog.fetchCardById('3188-999999'), isNull);
    });

    test('in a starter deck carry their own set code', () async {
      final cards = await catalogWith(
        products: starterProductsJson,
        prices: '{"results":[]}',
      ).fetchCardsInSet('st31');

      expect(cards.single.setCode, 'st31');
      expect(cards.single.collectorNumber, '001');
      expect(cards.single.extras['printedNumber'], 'ST31-001');
      // The number a scan reads off the card is the one the catalogue keys by.
      expect(cards.single.collectorNumber, '001');
    });
  });

  group('star wars unlimited cards', () {
    test('take their position from a fraction of the set', () async {
      final cards = await catalogWith(
        game: CardGame.starWarsUnlimited,
        groups: swuGroupsJson,
        products: swuProductsJson,
        prices: '{"results":[]}',
      ).fetchCardsInSet('ash');

      expect(cards.single.collectorNumber, '94');
      expect(cards.single.extras['printedNumber'], '94/264');
      expect(cards.single.rarity, 'Legendary');
      expect(cards.single.typeLine, 'Leader - Imperial / Officer');
    });

    test('name their aspect, alignment and all', () async {
      final cards = await catalogWith(
        game: CardGame.starWarsUnlimited,
        groups: swuGroupsJson,
        products: swuProductsJson,
        prices: '{"results":[]}',
      ).fetchCardsInSet('ash');

      expect(cards.single.colors, <String>['Command', 'Villainy']);
      expect(
        CardGame.starWarsUnlimited.dominantBucket(cards.single.colors),
        SwuAspect.command,
      );
    });
  });

  group('digimon cards', () {
    test(
      'take their position from a number with a rarity on the end',
      () async {
        final catalog = TcgcsvCatalog.digimon(
          dio: Dio(BaseOptions(baseUrl: 'https://tcgcsv.com/tcgplayer'))
            ..httpClientAdapter = _FakeTcgcsv((Uri uri) {
              if (uri.path.endsWith('/groups')) return digimonGroupsJson;
              if (uri.path.endsWith('/products')) return digimonProductsJson;
              if (uri.path.endsWith('/prices')) return '{"results":[]}';
              return null;
            }, <Uri>[]),
        );
        final cards = await catalog.fetchCardsInSet('bt26');

        expect(cards.single.collectorNumber, '052');
        expect(cards.single.extras['printedNumber'], 'BT26-052 C');
        expect(cards.single.rarity, 'Common');
        expect(cards.single.colors, <String>['Red']);
        expect(cards.single.typeLine, 'Digimon - Rookie - Reptile - Level 3');
        expect(cards.single.cmc, 3);
        expect(cards.single.game, CardGame.digimon);
      },
    );

    test('a set the provider lists twice is one set, whole', () async {
      // Digimon's Timeless Bonds is two groups under one abbreviation: the
      // booster set and the release event run it was given. Keyed by code - as
      // the app keys sets, so a scanned card resolves - they are one set, and
      // emitting both would have shown only the run and hidden the set it came
      // from.
      final requests = <Uri>[];
      final catalog = TcgcsvCatalog.digimon(
        dio: Dio(BaseOptions(baseUrl: 'https://tcgcsv.com/tcgplayer'))
          ..httpClientAdapter = _FakeTcgcsv((Uri uri) {
            if (uri.path.endsWith('/groups')) return sharedCodeGroupsJson;
            if (uri.path.contains('/63/24824/products')) {
              return releaseEventProductsJson;
            }
            if (uri.path.endsWith('/products')) return digimonProductsJson;
            if (uri.path.endsWith('/prices')) return '{"results":[]}';
            return null;
          }, requests),
      );

      final sets = await catalog.fetchAllSets();
      expect(sets, hasLength(1));
      // The set, not the run: its name, its code and its type.
      expect(sets.single.code, 'bt26');
      expect(sets.single.name, 'Timeless Bonds');
      expect(sets.single.setType, 'expansion');

      requests.clear();
      final cards = await catalog.fetchCardsInSet('bt26');
      // Both groups were asked for, and both runs are in the answer, in
      // collector-number order and under the set's own code and name.
      expect(
        requests.map((Uri u) => u.path).where((String p) => p.contains('/63/')),
        <String>[
          '/tcgplayer/63/24623/products',
          '/tcgplayer/63/24623/prices',
          '/tcgplayer/63/24824/products',
          '/tcgplayer/63/24824/prices',
        ],
      );
      expect(cards.map((TcgCard c) => c.extras['printedNumber']), <String>[
        'BT26-010 C',
        'BT26-052 C',
      ]);
      expect(cards.map((TcgCard c) => c.id), <String>[
        '24824-900002',
        '24623-900001',
      ]);
      for (final card in cards) {
        expect(card.setCode, 'bt26');
        expect(card.setName, 'Timeless Bonds');
      }
      // The release event printing has no rarity ladder to sit on, so it is
      // bucketed as the special printing it is rather than as Unknown.
      expect(CardRarity.fromCode(cards.first.rarity), CardRarity.special);
    });
  });

  group('dragon ball cards', () {
    test('are read from the game\'s own category and colour field', () async {
      final requests = <Uri>[];
      final catalog = TcgcsvCatalog.dragonBall(
        dio: Dio(BaseOptions(baseUrl: 'https://tcgcsv.com/tcgplayer'))
          ..httpClientAdapter = _FakeTcgcsv((Uri uri) {
            if (uri.path.endsWith('/groups')) return dragonBallGroupsJson;
            if (uri.path.endsWith('/products')) return dragonBallProductsJson;
            if (uri.path.endsWith('/prices')) return '{"results":[]}';
            return null;
          }, requests),
      );

      final cards = await catalog.fetchCardsInSet('fb11');
      final card = cards.single;

      expect(card.game, CardGame.dragonBall);
      expect(card.collectorNumber, '073');
      expect(card.extras['printedNumber'], 'FB11-073');
      // Fusion World calls a card's traits its Character Traits and prints them
      // under the card type, which is where the type line puts them.
      expect(card.typeLine, 'Leader - Saiyan / God');
      expect(card.colors, <String>['Yellow']);
      expect(card.cmc, 0);
      expect(card.extras['Power'], '15000/20000');
      // The category id is what addresses the game at the mirror, and it is the
      // one thing a new game can get wrong without anything else failing.
      expect(
        requests.map((Uri u) => u.path).where((String p) => p.contains('/80/')),
        isNotEmpty,
      );
      // A Leader is the card a deck is named after rather than a rung on the
      // rarity ladder, and it grades where One Piece's Leader grades.
      expect(CardRarity.fromCode(card.rarity), CardRarity.mythic);
    });
  });

  group('gundam cards', () {
    test(
      'carry the number the card prints and the fields the game uses',
      () async {
        final requests = <Uri>[];
        final catalog = TcgcsvCatalog.gundam(
          dio: Dio(BaseOptions(baseUrl: 'https://tcgcsv.com/tcgplayer'))
            ..httpClientAdapter = _FakeTcgcsv((Uri uri) {
              if (uri.path.endsWith('/groups')) return gundamGroupsJson;
              if (uri.path.endsWith('/products')) return gundamProductsJson;
              if (uri.path.endsWith('/prices')) return '{"results":[]}';
              return null;
            }, requests),
        );

        final cards = await catalog.fetchCardsInSet('st11');
        final card = cards.single;

        expect(card.game, CardGame.gundam);
        expect(card.collectorNumber, '001');
        expect(card.extras['printedNumber'], 'ST11-001');
        // A unit states its trait, the level it may be deployed at and the zone
        // it deploys to, and all three are what a player searches for.
        expect(
          card.typeLine,
          'Unit - (Zeon) (Marine) - Level 4 - Earth / Space',
        );
        expect(card.colors, <String>['Blue', 'Green']);
        // A deck may use two colours and is built around the first the card
        // prints, which is what the bucket has to be stable against.
        expect(CardGame.gundam.dominantBucket(card.colors), GundamColor.blue);
        expect(card.cmc, 3);
        expect(card.extras['Attack Points'], '3');
        expect(card.extras['Hit Points'], '3');
        expect(card.extras['Link Condition'], '[Char Aznable]');
        expect(
          requests
              .map((Uri u) => u.path)
              .where((String p) => p.contains('/86/')),
          isNotEmpty,
        );
      },
    );

    test('a plus on a rarity code is a treatment, not a rung', () {
      // Gundam ships C+, U+, R+, LR+ and LR++: the plus marks the parallel or
      // foil treatment, which the shop prices as a printing of its own, and the
      // ladder the card sits on is the one under the signs.
      expect(CardRarity.fromCode('C+'), CardRarity.common);
      expect(CardRarity.fromCode('U+'), CardRarity.uncommon);
      expect(CardRarity.fromCode('R+'), CardRarity.rare);
      expect(CardRarity.fromCode('LR+'), CardRarity.mythic);
      expect(CardRarity.fromCode('LR++'), CardRarity.mythic);
      expect(CardRarity.fromCode('Legend Rare'), CardRarity.mythic);
      expect(CardRarity.fromCode('Leader'), CardRarity.mythic);
    });
  });

  group('search and printings', () {
    test('are answered from the phone, because the provider has no index', () async {
      // tcgcsv republishes a shop's catalogue and answers no query about a card
      // name; the repository falls back to what is already cached.
      final requests = <Uri>[];
      final catalog = catalogWith(requests: requests);
      expect(await catalog.search('luffy'), isEmpty);
      expect(await catalog.fetchPrintingsOf('monkeydluffy|leader'), isEmpty);
      expect(requests, isEmpty);
    });
  });

  group('refreshing prices', () {
    test('costs one request per set, not one per card', () async {
      final requests = <Uri>[];
      final catalog = catalogWith(requests: requests);
      final cards = await catalog.fetchCardsInSet('op01');
      requests.clear();

      final fresh = await catalog.refreshPrices(cards);

      expect(requests, hasLength(1));
      expect(requests.single.path, endsWith('/68/3188/prices'));
      // The box has no price at all, so it is not in the answer.
      expect(fresh, hasLength(3));
      expect(
        fresh.firstWhere((TcgCard c) => c.id == '3188-453505').prices.nonfoil,
        2.14,
      );
    });

    test('leaves a card the provider has dropped alone', () async {
      final catalog = catalogWith(prices: '{"results":[]}');
      final cards = await catalog.fetchCardsInSet('op01');
      expect(await catalog.refreshPrices(cards), isEmpty);
      expect(await catalog.refreshPrices(const <TcgCard>[]), isEmpty);
    });
  });

  group('the mirror and the rules it asks for', () {
    test('name the game and the source on every catalogue', () {
      // The credit the UI shows, and the name a failure is reported under.
      expect(
        catalogWith().game,
        CardGame.onePiece,
        reason: 'the default harness builds the One Piece catalogue',
      );
      expect(catalogWith().sourceName, 'tcgcsv');
      expect(
        catalogWith(game: CardGame.starWarsUnlimited).game,
        CardGame.starWarsUnlimited,
      );
      expect(catalogWith(game: CardGame.digimon).game, CardGame.digimon);
    });

    test('and an unreachable mirror is a typed catalogue error', () async {
      // Every request answers 404, which is how the mirror behaves when it is
      // down or when the category has moved. The repository catches this and
      // serves the cache; what it must not do is escape as a raw Dio error.
      final catalog = catalogWith(fail: true);
      await expectLater(
        catalog.fetchAllSets(),
        throwsA(isA<CatalogException>()),
      );
    });

    test('while an unknown set is an empty set, not an error', () async {
      // A code the provider does not hold is a question with no answer, which
      // is the same thing as a set with nothing in it.
      expect(await catalogWith().fetchCardsInSet('nope'), isEmpty);
    });
  });
}
