// Tests for the Heroicc Digimon catalogue adapter.
//
//   flutter test test/catalog/digimon_catalog_test.dart
//
// Nothing here touches the network: the adapter takes a Dio instance, so these tests
// hand it one backed by an adapter serving canned JSON:API envelopes.
//
// The fixtures are the shapes the live data has, kept awkward on purpose: a release
// names its cards by id and nothing more, a parallel printing is a card of its own
// with its base card's number, a card names the release it is filed under rather than
// the set its number names, 77 cards of the game name no release at all, a release
// without a date is one of the six, and the rarity is a code rather than a word.
// Each of those is a case where this path degrades quietly rather than failing
// loudly, which is why they are pinned here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/digimon_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// One release as the set list states it: an id and a meta of name, count and date.
Map<String, Object?> release(
  String slug,
  String name, {
  int cards = 0,
  String? date,
}) => <String, Object?>{
  'type': 'release',
  'id': '/releases/en/$slug',
  'links': <String, Object?>{'self': 'https://api.heroi.cc/releases/en/$slug'},
  'meta': <String, Object?>{
    'name': name,
    'cards': cards,
    if (date != null) 'date': date,
  },
};

/// A card record, with the release it is filed under named the way the source does.
Map<String, Object?> card(
  String id, {
  required String name,
  required String number,
  String rarity = 'C',
  String category = 'digimon',
  String? type,
  String? form,
  int? level,
  int? dp,
  int? playCost,
  List<String> colors = const <String>['red'],
  int parallelId = 0,
  String? effect,
  String? inherited,
  List<String> releases = const <String>[],
}) => <String, Object?>{
  'type': 'card',
  'id': '/cards/en/$id',
  'attributes': <String, Object?>{
    'name': name,
    'number': number,
    'rarity': rarity,
    'category': category,
    'color': colors,
    'parallel-id': parallelId,
    'image': 'https://images.heroi.cc/cards/en/$id.webp',
    'language': 'en',
    'notes': 'Booster TEST SET',
    if (type != null) 'type': type,
    if (form != null) 'form': form,
    if (level != null) 'level': level,
    if (dp != null) 'dp': dp,
    if (playCost != null) 'play-cost': playCost,
    if (effect != null) 'effect': effect,
    if (inherited != null) 'inherited-effect': inherited,
  },
  'relationships': <String, Object?>{
    'releases': <String, Object?>{
      'data': <Map<String, Object?>>[
        for (final String slug in releases)
          <String, Object?>{'type': 'release', 'id': '/releases/en/$slug'},
      ],
    },
  },
};

/// A card id as a release lists it: an id and a link, no attributes.
Map<String, Object?> cardId(String id) => <String, Object?>{
  'type': 'card',
  'id': '/cards/en/$id',
  'links': <String, Object?>{'self': 'https://api.heroi.cc/cards/en/$id'},
};

/// Serves canned envelopes in place of the network.
///
/// Four routes: the release list, one release, one card, and the search. Every
/// request is recorded, so a test can assert how many were made and what they
/// carried - which is the whole of this catalogue's cost story, since a set is one
/// request for the ids and one per card.
class _FakeHeroicc implements HttpClientAdapter {
  _FakeHeroicc({this.failAll = false});

  /// Whether every request fails, for the paths that must narrow rather than raise.
  bool failAll;

  /// Ids the card route refuses, so a test can make one card fail inside a set.
  final Set<String> broken = <String>{};

  final List<Uri> requests = <Uri>[];

  static const List<Map<String, Object?>> releases = <Map<String, Object?>>[
    <String, Object?>{
      'type': 'release',
      'id': '/releases/en/bt-08',
      'meta': <String, Object?>{
        'name': 'NEW AWAKENING [BT-08]',
        'cards': 3,
        'date': '2022-05-13',
      },
    },
    <String, Object?>{
      'type': 'release',
      'id': '/releases/en/st-01',
      'meta': <String, Object?>{'name': 'GAIA RED [ST-01]', 'cards': 1, 'date': '2021-01-29'},
    },
    <String, Object?>{
      'type': 'release',
      'id': '/releases/en/other-promos',
      'meta': <String, Object?>{'name': 'Other Promos', 'cards': 1},
    },
  ];

  /// Every card this fake holds, keyed by id.
  static final Map<String, Map<String, Object?>> cards =
      <String, Map<String, Object?>>{
    for (final Map<String, Object?> record in <Map<String, Object?>>[
      card('BT8-022', name: 'SnowAgumon', number: 'BT8-022', type: 'Dinosaur',
          form: 'Rookie', level: 3, dp: 2000, playCost: 3, colors: <String>['blue'],
          effect: '[On Play] Trash the top digivolution card.',
          releases: <String>['bt-08']),
      // A parallel printing filed under a release its number does not name.
      card('BT5-007_P3', name: 'Agumon', number: 'BT5-007', rarity: 'R',
          type: 'Reptile', form: 'Rookie', level: 3, dp: 2000, playCost: 3,
          parallelId: 3, inherited: '[Your Turn] This Digimon gets +1000 DP.',
          releases: <String>['bt-08']),
      card('ST1-01', name: 'Koromon', number: 'ST1-01', category: 'digi-egg',
          level: 2, colors: <String>['red'], releases: <String>['st-01']),
      // A card the source files under no release at all: its number is the only
      // word on which set it belongs to.
      card('P-001', name: 'Promo Agumon', number: 'P-001', releases: <String>[]),
    ])
      record['id']! as String: record,
  };

  static const Map<String, List<String>> byRelease = <String, List<String>>{
    'bt-08': <String>['BT8-022', 'BT5-007_P3'],
    'st-01': <String>['ST1-01'],
    'other-promos': <String>[],
  };

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
    final String path = options.uri.path;
    if (path == '/releases/en') {
      return _body(jsonEncode(<String, Object?>{
        'data': <String, Object?>{'type': 'language', 'id': '/releases/en'},
        'included': releases,
      }));
    }
    if (path.startsWith('/releases/en/')) {
      final String slug = path.substring('/releases/en/'.length);
      Map<String, Object?> found = <String, Object?>{
        'meta': <String, Object?>{'name': slug},
      };
      for (final Map<String, Object?> candidate in releases) {
        if (candidate['id'] == '/releases/en/$slug') found = candidate;
      }
      return _body(jsonEncode(<String, Object?>{
        'data': <String, Object?>{'attributes': found['meta']},
        'included': <Map<String, Object?>>[
          for (final String id in byRelease[slug] ?? const <String>[]) cardId(id),
        ],
      }));
    }
    if (path.startsWith('/cards/en/')) {
      final String id = path.substring('/cards/en/'.length);
      if (broken.contains(id)) {
        return _body('{"errors":[{"detail":"nope"}]}', 502);
      }
      final Map<String, Object?>? found = cards['/cards/en/$id'];
      if (found == null) {
        return _body('{"errors":[{"detail":"Not Found"}]}', 404);
      }
      return _body(jsonEncode(<String, Object?>{
        'data': found,
        'included': releases,
      }));
    }
    if (path == '/search') {
      final String q = (options.uri.queryParameters['q'] ?? '').toLowerCase();
      return _body(jsonEncode(<String, Object?>{
        'data': <Map<String, Object?>>[
          for (final Map<String, Object?> record in cards.values)
            if ((record['attributes']! as Map<String, Object?>)['name']!
                        .toString()
                        .toLowerCase()
                    .contains(q) ||
                (record['attributes']! as Map<String, Object?>)['number']!
                    .toString()
                    .toLowerCase()
                    .contains(q))
              record,
        ],
        'included': releases,
      }));
    }
    return _body('{"errors":[{"detail":"Not Found"}]}', 404);
  }

  static ResponseBody _body(String body, [int status = 200]) =>
      ResponseBody.fromString(body, status, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

/// A catalogue wired to a fake source.
DigimonCatalog _catalogOn(_FakeHeroicc api) {
  final Dio dio = Dio(BaseOptions(baseUrl: 'https://api.heroi.cc'));
  dio.httpClientAdapter = api;
  return DigimonCatalog(dio: dio);
}
void main() {
  group('the set list', () {
    test('is one request and carries a count and a date per set', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final List<TcgSet> sets = await _catalogOn(api).fetchAllSets();

      expect(sets, hasLength(3));
      expect(api.requests, hasLength(1));
      expect(api.requests.single.path, '/releases/en');

      final TcgSet awakening = sets.firstWhere((TcgSet s) => s.code == 'bt08');
      expect(awakening.game, CardGame.digimon);
      expect(awakening.id, 'bt-08');
      expect(awakening.name, 'NEW AWAKENING [BT-08]');
      expect(awakening.cardCount, 3);
      expect(awakening.releasedAt, DateTime(2022, 5, 13));
      expect(awakening.setType, 'expansion');

      final TcgSet starter = sets.firstWhere((TcgSet s) => s.code == 'st01');
      expect(starter.setType, 'starter');
      // A release with no date is one of the six the source leaves undated, and
      // the column stays empty rather than being guessed at.
      final TcgSet promos = sets.firstWhere((TcgSet s) => s.code == 'otherpromos');
      expect(promos.setType, 'promo');
      expect(promos.releasedAt, isNull);
    });

    test('reports progress once per release', () async {
      final List<(int, int)> progress = <(int, int)>[];
      await _catalogOn(_FakeHeroicc()).fetchAllSets(
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(progress.first, (0, 3));
      expect(progress.last, (3, 3));
    });

    test('raises rather than answering empty when the source is down', () async {
      await expectLater(
        _catalogOn(_FakeHeroicc(failAll: true)).fetchAllSets(),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('a set download', () {
    test('is one request for the ids and one per card', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final List<TcgCard> cards = await _catalogOn(api).fetchCardsInSet('bt08');

      expect(cards, hasLength(2));
      // The set list, for the release slug the folded code does not spell; the
      // release; and its two cards.
      expect(api.requests, hasLength(4));
      expect(
        api.requests[1].path,
        '/releases/en/bt-08',
        reason: 'the slug the folded code bt08 is stored under',
      );
      expect(
        api.requests.skip(2).map((Uri u) => u.path),
        <String>['/cards/en/BT8-022', '/cards/en/BT5-007_P3'],
        reason: 'the ids the release lists, in the order it lists them',
      );
    });

    test('reads the card, its number and its rarity code', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeHeroicc(),
      ).fetchCardsInSet('bt08');
      final TcgCard snow = cards.firstWhere((TcgCard c) => c.id == 'BT8-022');

      expect(snow.game, CardGame.digimon);
      expect(snow.setCode, 'bt08');
      expect(snow.setName, 'NEW AWAKENING [BT-08]');
      expect(snow.name, 'SnowAgumon');
      expect(snow.collectorNumber, '022');
      expect(snow.collectorNumberSortKey, 22);
      expect(snow.rarity, 'Common');
      expect(snow.rarityCode, 'C');
      expect(snow.typeLine, 'Digimon - Dinosaur - Rookie - Lv.3');
      expect(snow.oracleText, '[On Play] Trash the top digivolution card.');
      expect(snow.cmc, 3);
      expect(snow.colors, <String>['blue']);
      expect(snow.imageUris['normal'],
          'https://images.heroi.cc/cards/en/BT8-022.webp');
      expect(snow.extras['printedNumber'], 'BT8-022');
      expect(snow.extras['parallelId'], 0);
      expect(snow.extras['dp'], 2000);
      // The price-history join key, which this source does not publish.
      expect(snow.extras['tcgplayerId'], isNull);
    });

    test('keeps a parallel printing apart and groups it with its base card', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeHeroicc(),
      ).fetchCardsInSet('bt08');
      final TcgCard parallel =
          cards.firstWhere((TcgCard c) => c.id == 'BT5-007_P3');

      expect(parallel.collectorNumber, '007',
          reason: 'the parallel keeps the number printed on the card');
      expect(parallel.oracleId, 'BT5-007');
      expect(parallel.id, isNot('BT5-007'));
      expect(parallel.rarity, 'Rare');
      expect(parallel.oracleText, contains('+1000 DP'));
    });

    test('files a card under the release it names rather than the set its number does', () async {
      // BT5-007_P3 is printed BT5-007 and filed under bt-08, which is where a
      // collector finds it: the release a card names is the set it belongs to.
      final TcgCard parallel = (await _catalogOn(
        _FakeHeroicc(),
      ).fetchCardById('BT5-007_P3'))!;
      expect(parallel.setCode, 'bt08');
      expect(parallel.setName, 'NEW AWAKENING [BT-08]');
    });

    test('falls back to the number for a card that names no release', () async {
      final TcgCard promo =
          (await _catalogOn(_FakeHeroicc()).fetchCardById('P-001'))!;
      expect(promo.setCode, 'p', reason: 'the set its printed number names');
      expect(promo.setName, 'P', reason: 'and no release name to be had');
    });

    test('a card the source refuses costs that card and no others', () async {
      final _FakeHeroicc api = _FakeHeroicc()..broken.add('BT8-022');
      final List<TcgCard> cards = await _catalogOn(api).fetchCardsInSet('bt08');
      expect(cards.map((TcgCard c) => c.id), <String>['BT5-007_P3']);
    });

    test('a release with no cards is an empty set rather than an error', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeHeroicc(),
      ).fetchCardsInSet('otherpromos');
      expect(cards, isEmpty);
    });
  });

  group('one card, and a list of them', () {
    test('answers one card by its id, with the art host left alone', () async {
      final TcgCard? card = await _catalogOn(_FakeHeroicc()).fetchCardById('ST1-01');
      expect(card, isNotNull);
      expect(card!.id, 'ST1-01');
      expect(card.name, 'Koromon');
      expect(card.collectorNumber, '01');
      expect(card.setCode, 'st01');
      expect(card.oracleId, 'ST1-01');
    });

    test('says nothing for an id the source does not hold', () async {
      expect(await _catalogOn(_FakeHeroicc()).fetchCardById('BT9-999'), isNull);
    });

    test('asks about nothing when it is given nothing', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final Map<String, TcgCard> found =
          await _catalogOn(api).fetchCardsByIds(<String>['', '  ']);
      expect(found, isEmpty);
      expect(api.requests, isEmpty);
    });

    test('answers a list of ids one request at a time, keeping what arrives', () async {
      final _FakeHeroicc api = _FakeHeroicc()..broken.add('ST1-01');
      final Map<String, TcgCard> found = await _catalogOn(api).fetchCardsByIds(
        <String>['BT8-022', 'ST1-01'],
      );
      expect(found.keys, <String>['BT8-022']);
      // Two ids, and the one the source refuses is retried before it is given up
      // on - a 5xx is a failure worth asking again, which is why the count is a
      // floor rather than two.
      expect(api.requests.length, greaterThanOrEqualTo(2));
      expect(
        api.requests.map((Uri u) => u.path),
        contains('/cards/en/BT8-022'),
      );
    });
  });

  group('search', () {
    test('is one request carrying the query', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final List<TcgCard> hits = await _catalogOn(api).search('agumon');

      expect(api.requests, hasLength(1));
      expect(api.requests.single.path, '/search');
      expect(api.requests.single.queryParameters['q'], 'agumon');
      expect(hits.map((TcgCard c) => c.id), contains('BT5-007_P3'));
    });

    test('asks nothing at all for an empty query', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      expect(await _catalogOn(api).search('   '), isEmpty);
      expect(api.requests, isEmpty);
    });
  });

  group('a collector number', () {
    test('is asked as the card prints it, and only the cards carrying it answer', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final CollectorQuery? query = CollectorQuery.parse('BT8-022');
      expect(query, isNotNull);

      final List<TcgCard> cards = await _catalogOn(api).fetchCardsByNumber(query!);

      expect(api.requests.single.queryParameters['q'], 'BT8-022');
      expect(cards.map((TcgCard c) => c.id), <String>['BT8-022']);
    });
  });

  group('prices', () {
    test('are not asked for, because this source publishes none', () async {
      final _FakeHeroicc api = _FakeHeroicc();
      final TcgCard card = (await _catalogOn(api).fetchCardById('BT8-022'))!;
      api.requests.clear();
      expect(await _catalogOn(api).refreshPrices(<TcgCard>[card]), isEmpty);
      expect(api.requests, isEmpty);
    });
  });
}
