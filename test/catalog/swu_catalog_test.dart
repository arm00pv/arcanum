// Tests for the Star Wars: Unlimited catalogue adapter.
//
//   flutter test test/catalog/swu_catalog_test.dart
//
// Nothing here touches the network: the adapter takes a Dio instance, so these
// tests hand it one backed by an adapter serving canned Strapi envelopes.
//
// The fixtures are the awkward shapes the live data has, kept awkward on purpose:
// a hyperspace record carries a cardNumber of its own that counts something other
// than the card, a leader's own art is landscape, a token is listed beside the
// cards, a promo is filed inside the retail set it promotes, and the set list
// carries no card count at all so every count is a second request. Each of those
// is a case where this path degrades quietly rather than failing loudly, which is
// why they are pinned here.

import 'dart:convert';
import 'dart:typed_data';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/swu_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// One relation the way the source writes it: an object under 'data'.
Map<String, Object?> relation(Map<String, Object?> attributes) =>
    <String, Object?>{
      'data': <String, Object?>{'id': 1, 'attributes': attributes},
    };

/// A relation that holds a list, which is how aspects, traits and variant types
/// arrive.
Map<String, Object?> listOf(List<String> names) => <String, Object?>{
  'data': <Map<String, Object?>>[
    for (final String name in names)
      <String, Object?>{'id': 1, 'attributes': <String, Object?>{'name': name}},
  ],
};

/// One card record, wrapped the way the card list wraps it.
Map<String, Object?> record(Map<String, Object?> attributes) =>
    <String, Object?>{'id': 1, 'attributes': attributes};

/// The base leader: a portrait tile drawn from the unit face of a landscape card.
final Map<String, Object?> luke = record(<String, Object?>{
  'cardUid': '111',
  'cardId': '111',
  'cardNumber': 5,
  'cardCount': 252,
  'serialCode': '0101005',
  'title': 'Luke Skywalker',
  'subtitle': 'Faithful Friend',
  'artist': 'Borja Pindado',
  'artFrontHorizontal': true,
  'cost': 6,
  'hp': 7,
  'power': 4,
  'text': 'Action [1 resource, exhaust]: Give a Shield token to a [Heroism] unit.',
  'epicAction': 'Epic Action: If you control 6 or more resources, deploy this leader.',
  'hyperspace': false,
  'showcase': false,
  'unique': true,
  'rules': null,
  'artFront': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Leader.png',
    'width': 418,
    'height': 300,
  }),
  'artBack': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Unit.png',
    'width': 300,
    'height': 418,
  }),
  'expansion': relation(<String, Object?>{
    'code': 'SOR',
    'name': 'Spark of Rebellion',
  }),
  'type': relation(<String, Object?>{'name': 'Leader'}),
  'type2': relation(<String, Object?>{'name': 'Leader Unit'}),
  'rarity': relation(<String, Object?>{'name': 'Special'}),
  'aspects': listOf(<String>['Vigilance', 'Heroism']),
  'traits': listOf(<String>['Force']),
  'arenas': listOf(<String>['Ground']),
  'keywords': listOf(<String>[]),
  'variantTypes': listOf(<String>['Standard']),
  'variantOf': <String, Object?>{'data': null},
});

/// The hyperspace printing of that leader: its own number is 1, its base's is 5.
final Map<String, Object?> lukeHyperspace = record(<String, Object?>{
  'cardUid': '222',
  'cardNumber': 1,
  'cardCount': 252,
  'serialCode': '0102001',
  'title': 'Luke Skywalker',
  'subtitle': 'Faithful Friend',
  'artFrontHorizontal': true,
  'hyperspace': true,
  'showcase': false,
  'text': 'Action [1 resource, exhaust]: Give a Shield token to a [Heroism] unit.',
  'artFront': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Leader_HS.png',
    'width': 418,
    'height': 300,
  }),
  'artBack': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Unit_HS.png',
    'width': 300,
    'height': 418,
  }),
  'expansion': relation(<String, Object?>{
    'code': 'SOR',
    'name': 'Spark of Rebellion',
  }),
  'type': relation(<String, Object?>{'name': 'Leader'}),
  'rarity': relation(<String, Object?>{'name': 'Special'}),
  'aspects': listOf(<String>['Vigilance', 'Heroism']),
  'variantTypes': listOf(<String>['Hyperspace']),
  'variantOf': relation(<String, Object?>{
    'cardUid': '111',
    'cardNumber': 5,
  }),
});

/// A unit, whose own art is already portrait.
final Map<String, Object?> cellBlockGuard = record(<String, Object?>{
  'cardUid': '333',
  'cardNumber': 229,
  'cardCount': 252,
  'serialCode': '0101229',
  'title': 'Cell Block Guard',
  'subtitle': null,
  'artFrontHorizontal': false,
  'cost': 2,
  'hp': 3,
  'power': 2,
  'text': 'Sentinel.',
  'artFront': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_229_Cell_Block_Guard.png',
    'width': 300,
    'height': 418,
  }),
  'artBack': <String, Object?>{'data': null},
  'expansion': relation(<String, Object?>{
    'code': 'SOR',
    'name': 'Spark of Rebellion',
  }),
  'type': relation(<String, Object?>{'name': 'Unit'}),
  'rarity': relation(<String, Object?>{'name': 'Common'}),
  'aspects': listOf(<String>['Command']),
  'variantTypes': listOf(<String>['Standard']),
  'variantOf': <String, Object?>{'data': null},
});

/// A token, which is listed beside the cards and is not one.
final Map<String, Object?> shieldToken = record(<String, Object?>{
  'cardUid': '444',
  'cardNumber': 2,
  'cardCount': 252,
  'serialCode': '0101T02',
  'title': 'Shield',
  'expansion': relation(<String, Object?>{
    'code': 'SOR',
    'name': 'Spark of Rebellion',
  }),
  'type': relation(<String, Object?>{'name': 'Token Upgrade'}),
  'variantTypes': listOf(<String>[]),
});

/// A prerelease promo of the same leader, filed inside the set it promotes.
final Map<String, Object?> lukePromo = record(<String, Object?>{
  'cardUid': '555',
  'cardNumber': 1,
  'cardCount': 252,
  'serialCode': '0104001',
  'title': 'Luke Skywalker',
  'subtitle': 'Faithful Friend',
  'artFrontHorizontal': true,
  'text': 'Action [1 resource, exhaust]: Give a Shield token to a [Heroism] unit.',
  'artFront': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Promo.png',
    'width': 418,
    'height': 300,
  }),
  'artBack': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/SWH_01_005_Luke_Skywalker_Promo_Unit.png',
    'width': 300,
    'height': 418,
  }),
  'expansion': relation(<String, Object?>{
    'code': 'SOR',
    'name': 'Spark of Rebellion',
  }),
  'type': relation(<String, Object?>{'name': 'Leader'}),
  'rarity': relation(<String, Object?>{'name': 'Special'}),
  'variantTypes': listOf(<String>['Prerelease Promo']),
  'variantOf': relation(<String, Object?>{
    'cardUid': '111',
    'cardNumber': 5,
  }),
});

/// A card of another set, so a set download has something to exclude.
final Map<String, Object?> ahsoka = record(<String, Object?>{
  'cardUid': '666',
  'cardNumber': 12,
  'cardCount': 262,
  'serialCode': '0301012',
  'title': 'Ahsoka Tano',
  'subtitle': null,
  'artFrontHorizontal': false,
  'text': 'When Played: Give a unit Sentinel for this phase.',
  'artFront': relation(<String, Object?>{
    'url': 'https://cdn.starwarsunlimited.com/TWI_01_012_Ahsoka_Tano.png',
    'width': 300,
    'height': 418,
  }),
  'expansion': relation(<String, Object?>{
    'code': 'TWI',
    'name': 'Twilight of the Republic',
  }),
  'type': relation(<String, Object?>{'name': 'Unit'}),
  'rarity': relation(<String, Object?>{'name': 'Rare'}),
  'variantTypes': listOf(<String>['Standard']),
  'variantOf': <String, Object?>{'data': null},
});
/// Serves canned envelopes in place of the network.
///
/// The set list answers whole; the card list answers a filter, a paging envelope
/// and an error the way the source does - a refused request is `{data: null,
/// error}` with a status, and an empty answer is an empty list, because the two
/// mean different things to the caller. Every request is recorded, so a test can
/// assert how many were made and what they carried.
class _FakeSwu implements HttpClientAdapter {
  _FakeSwu({this.failAll = false});

  /// Whether every request fails, for the paths that must narrow rather than
  /// raise into the UI.
  bool failAll;

  final List<Uri> requests = <Uri>[];

  /// The sizes the source would state for these sets. They are bigger than the
  /// records this fake holds, which is what makes a one-record count request a
  /// count rather than a page.
  static const Map<String, int> setSizes = <String, int>{
    'SOR': 252,
    'TWI': 262,
    'P25': 40,
  };

  static const List<Map<String, Object?>> sets = <Map<String, Object?>>[
    <String, Object?>{
      'id': 2,
      'attributes': <String, Object?>{
        'code': 'SOR',
        'name': 'Spark of Rebellion',
      },
    },
    <String, Object?>{
      'id': 18,
      'attributes': <String, Object?>{
        'code': 'TWI',
        'name': 'Twilight of the Republic',
      },
    },
    <String, Object?>{
      'id': 38,
      'attributes': <String, Object?>{
        'code': 'P25',
        'name': '2025 Promo',
      },
    },
  ];

  /// Every record this fake holds, in the order the source would list them.
  late final List<Map<String, Object?>> cards = <Map<String, Object?>>[
    luke,
    lukeHyperspace,
    cellBlockGuard,
    shieldToken,
    lukePromo,
    ahsoka,
  ];

  static Map<String, Object?> _attributes(Map<String, Object?> wrapped) =>
      wrapped['attributes']! as Map<String, Object?>;

  static Map<String, Object?>? _relation(
    Map<String, Object?> attributes,
    String key,
  ) {
    final Object? raw = attributes[key];
    if (raw is! Map) return null;
    final Object? data = raw['data'];
    if (data is! Map) return null;
    return data['attributes'] as Map<String, Object?>?;
  }

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
    final Map<String, String> params = options.uri.queryParameters;
    final String path = options.uri.path;

    if (path.endsWith('card-expansions')) {
      return _body(
        jsonEncode(<String, Object?>{
          'data': sets,
          'meta': <String, Object?>{
            'pagination': <String, Object?>{'total': sets.length},
          },
        }),
      );
    }
    if (!path.endsWith('card-list')) {
      return _body(
        '{"data":null,"error":{"status":404,"name":"NotFoundError",'
        '"message":"Not Found"}}',
        404,
      );
    }

    List<Map<String, Object?>> rows = List<Map<String, Object?>>.of(cards);
    final String? code = params['filters[expansion][code][\$eq]'];
    if (code != null) {
      rows = rows
          .where(
            (Map<String, Object?> row) =>
                _relation(_attributes(row), 'expansion')?['code'] == code,
          )
          .toList();
    }
    if (params['filters[variantOf][\$null]'] == 'true') {
      rows = rows
          .where(
            (Map<String, Object?> row) =>
                _relation(_attributes(row), 'variantOf') == null,
          )
          .toList();
    }
    for (
      var i = 0;
      params.containsKey('filters[type][name][\$notIn][$i]');
      i++
    ) {
      final String excluded = params['filters[type][name][\$notIn][$i]']!;
      rows = rows
          .where(
            (Map<String, Object?> row) =>
                _relation(_attributes(row), 'type')?['name'] != excluded,
          )
          .toList();
    }
    final String? uid = params['filters[cardUid][\$eq]'];
    if (uid != null) {
      rows = rows
          .where(
            (Map<String, Object?> row) => _attributes(row)['cardUid'] == uid,
          )
          .toList();
    }
    final List<String> wanted = <String>[
      for (var i = 0; params.containsKey('filters[cardUid][\$in][$i]'); i++)
        params['filters[cardUid][\$in][$i]']!,
    ];
    if (wanted.isNotEmpty) {
      rows = rows
          .where(
            (Map<String, Object?> row) =>
                wanted.contains(_attributes(row)['cardUid']),
          )
          .toList();
    }
    final String? number = params['filters[cardNumber][\$eq]'];
    if (number != null) {
      rows = rows
          .where(
            (Map<String, Object?> row) =>
                _attributes(row)['cardNumber'].toString() == number,
          )
          .toList();
    }
    final String? term = params['filters[\$or][0][title][\$containsi]'];
    if (term != null) {
      final String needle = term.toLowerCase();
      rows = rows.where((Map<String, Object?> row) {
        final Map<String, Object?> attributes = _attributes(row);
        return <String>['title', 'subtitle', 'text'].any(
          (String field) => (attributes[field]?.toString() ?? '')
              .toLowerCase()
              .contains(needle),
        );
      }).toList();
    }

    final bool counting = params['filters[variantOf][\$null]'] == 'true';
    final int total = counting && code != null
        ? (setSizes[code] ?? rows.length)
        : rows.length;
    final int pageSize =
        int.tryParse(params['pagination[pageSize]'] ?? '') ?? 250;
    final int page = int.tryParse(params['pagination[page]'] ?? '') ?? 1;
    final List<Map<String, Object?>> pageRows = rows
        .skip((page - 1) * pageSize)
        .take(pageSize)
        .toList();
    return _body(
      jsonEncode(<String, Object?>{
        'data': pageRows,
        'meta': <String, Object?>{
          'pagination': <String, Object?>{'total': total, 'pageSize': pageSize},
        },
      }),
    );
  }

  static ResponseBody _body(String body, [int status = 200]) =>
      ResponseBody.fromString(body, status, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

/// A catalogue wired to a fake source.
SwuCatalog _catalogOn(_FakeSwu api) {
  final Dio dio = Dio(
    BaseOptions(baseUrl: 'https://admin.starwarsunlimited.com/api/'),
  );
  dio.httpClientAdapter = api;
  return SwuCatalog(dio: dio);
}
void main() {
  group('the set list', () {
    test('is one request for every set, and one more for each count', () async {
      final _FakeSwu api = _FakeSwu();
      final List<TcgSet> sets = await _catalogOn(api).fetchAllSets();

      expect(sets, hasLength(3));
      expect(sets.first.game, CardGame.starWarsUnlimited);
      expect(sets.first.id, 'SOR');
      expect(sets.first.code, 'sor');
      expect(sets.first.name, 'Spark of Rebellion');
      expect(sets.first.cardCount, 252);
      // The source states no release date, so the column is empty rather than
      // guessed at: the sets table sorts on it.
      expect(sets.first.releasedAt, isNull);

      // One listing and one count per set, which is the cost of a source with no
      // set endpoint that carries a count.
      expect(api.requests, hasLength(4));
      expect(api.requests.first.path, endsWith('card-expansions'));
      for (final Uri request in api.requests.skip(1)) {
        expect(request.queryParameters['pagination[pageSize]'], '1');
        expect(request.queryParameters['filters[variantOf][\$null]'], 'true');
      }
    });

    test('counts base printings, with the tokens taken out', () async {
      final _FakeSwu api = _FakeSwu();
      await _catalogOn(api).fetchAllSets();
      final Map<String, String> countQuery = api.requests[1].queryParameters;
      expect(countQuery['filters[type][name][\$notIn][0]'], 'Token Upgrade');
      expect(countQuery['filters[type][name][\$notIn][3]'], 'Force Token');
    });

    test('classifies the runs the publisher names', () async {
      final List<TcgSet> sets = await _catalogOn(_FakeSwu()).fetchAllSets();
      final Map<String, String> types = <String, String>{
        for (final TcgSet set in sets) set.code: set.setType,
      };
      expect(types['sor'], 'expansion');
      expect(types['twi'], 'expansion');
      expect(types['p25'], 'promo');
    });

    test('reports progress once per set', () async {
      final List<(int, int)> progress = <(int, int)>[];
      await _catalogOn(_FakeSwu()).fetchAllSets(
        onProgress: (int done, int total) => progress.add((done, total)),
      );
      expect(progress.first, (0, 3));
      expect(progress.last, (3, 3));
    });

    test('raises rather than answering empty when the source is down', () async {
      await expectLater(
        _catalogOn(_FakeSwu(failAll: true)).fetchAllSets(),
        throwsA(isA<CatalogException>()),
      );
    });
  });

  group('a set download', () {
    test('stores the publisher id verbatim and reads the rest off the record', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('sor');
      final TcgCard luke = cards.firstWhere((TcgCard c) => c.id == '111');

      expect(luke.game, CardGame.starWarsUnlimited);
      expect(luke.setCode, 'sor');
      expect(luke.setName, 'Spark of Rebellion');
      expect(luke.name, 'Luke Skywalker, Faithful Friend');
      expect(luke.collectorNumber, '005');
      expect(luke.collectorNumberSortKey, 5);
      expect(luke.rarity, 'Special');
      expect(luke.typeLine, 'Leader - Leader Unit - Ground');
      expect(luke.oracleText, startsWith('Epic Action: If you control 6'));
      expect(luke.oracleText, contains('Give a Shield token'));
      expect(luke.cmc, 6);
      expect(luke.colors, <String>['Vigilance', 'Heroism']);
      expect(luke.artist, 'Borja Pindado');
      expect(luke.oracleId, '111');
      expect(luke.extras['cardUid'], '111');
      expect(luke.extras['serial'], '0101005');
      expect(luke.extras['power'], 4);
      expect(luke.extras['hp'], 7);
      // The price-history join key, which this source does not publish.
      expect(luke.extras['tcgplayerId'], isNull);
    });

    test('draws a leader from the portrait face of a landscape card', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('sor');
      final TcgCard luke = cards.firstWhere((TcgCard c) => c.id == '111');
      expect(
        luke.imageUris['normal'],
        endsWith('Luke_Skywalker_Unit.png'),
        reason: 'the leader side is landscape and the tile is portrait',
      );
      final TcgCard unit = cards.firstWhere((TcgCard c) => c.id == '333');
      expect(unit.imageUris['normal'], endsWith('Cell_Block_Guard.png'));
      expect(unit.collectorNumber, '229');
      expect(unit.name, 'Cell Block Guard');
    });

    test('gives a treatment its base number, and groups it with the base', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('sor');
      final TcgCard hyperspace = cards.firstWhere((TcgCard c) => c.id == '222');

      expect(
        hyperspace.collectorNumber,
        '005',
        reason: 'the record carries 1 and the card it is a printing of carries 5',
      );
      expect(hyperspace.extras['printedNumber'], 5);
      expect(hyperspace.oracleId, '111');
      expect(hyperspace.extras['variantOf'], '111');
      expect(hyperspace.extras['variantTypes'], <String>['Hyperspace']);
      expect(hyperspace.extras['hyperspace'], true);
      expect(hyperspace.imageUris['normal'], endsWith('Unit_HS.png'));
    });

    test('marks a promo that is filed inside the set it promotes', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('sor');
      final TcgCard promo = cards.firstWhere((TcgCard c) => c.id == '555');
      expect(promo.promo, isTrue);
      expect(promo.collectorNumber, '005');
      expect(cards.firstWhere((TcgCard c) => c.id == '111').promo, isFalse);
    });

    test('drops tokens, which are listed beside the cards and are not cards', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('sor');
      expect(cards.map((TcgCard c) => c.id), isNot(contains('444')));
      expect(cards, hasLength(4));
    });

    test('asks for the set in the publisher spelling of the code', () async {
      final _FakeSwu api = _FakeSwu();
      await _catalogOn(api).fetchCardsInSet('sor');
      expect(
        api.requests.single.queryParameters['filters[expansion][code][\$eq]'],
        'SOR',
      );
    });

    test('answers with the printings of one set and no other', () async {
      final List<TcgCard> cards = await _catalogOn(
        _FakeSwu(),
      ).fetchCardsInSet('twi');
      expect(cards.map((TcgCard c) => c.id), <String>['666']);
    });
  });

  group('one card, and a list of them', () {
    test('answers one printing by the id the publisher gave it', () async {
      final TcgCard? card = await _catalogOn(_FakeSwu()).fetchCardById('222');
      expect(card, isNotNull);
      expect(card!.id, '222');
      expect(card.collectorNumber, '005');
      expect(card.setCode, 'sor');
    });

    test('answers a whole list in one request, keyed by the id asked about', () async {
      final _FakeSwu api = _FakeSwu();
      final Map<String, TcgCard> found = await _catalogOn(
        api,
      ).fetchCardsByIds(<String>['111', '222', '666']);

      expect(found.keys.toSet(), <String>{'111', '222', '666'});
      expect(api.requests, hasLength(1));
      final Map<String, String> params = api.requests.single.queryParameters;
      expect(params['filters[cardUid][\$in][0]'], '111');
      expect(params['filters[cardUid][\$in][2]'], '666');
    });

    test('says nothing for an id the source does not hold', () async {
      expect(await _catalogOn(_FakeSwu()).fetchCardById('999'), isNull);
    });

    test('asks about nothing when it is given nothing', () async {
      final _FakeSwu api = _FakeSwu();
      expect(await _catalogOn(api).fetchCardsByIds(<String>[]), isEmpty);
      expect(await _catalogOn(api).fetchCardById('  '), isNull);
      expect(api.requests, isEmpty);
    });
  });

  group('search', () {
    test('is one request over the name, the subtitle and the rules text', () async {
      final _FakeSwu api = _FakeSwu();
      final List<TcgCard> hits = await _catalogOn(api).search('faithful');

      expect(api.requests, hasLength(1));
      final Map<String, String> params = api.requests.single.queryParameters;
      expect(params['filters[\$or][0][title][\$containsi]'], 'faithful');
      expect(params['filters[\$or][1][subtitle][\$containsi]'], 'faithful');
      expect(params['filters[\$or][2][text][\$containsi]'], 'faithful');
      expect(hits.map((TcgCard c) => c.id), contains('111'));
    });

    test('asks nothing at all for an empty query', () async {
      final _FakeSwu api = _FakeSwu();
      expect(await _catalogOn(api).search('   '), isEmpty);
      expect(api.requests, isEmpty);
    });
  });

  group('a collector number', () {
    test('is answered by the source, inside the set the query named', () async {
      final _FakeSwu api = _FakeSwu();
      final CollectorQuery? query = CollectorQuery.parse('SOR 005');
      expect(query, isNotNull);

      final List<TcgCard> cards = await _catalogOn(
        api,
      ).fetchCardsByNumber(query!);

      final Map<String, String> params = api.requests.single.queryParameters;
      expect(params['filters[expansion][code][\$eq]'], 'SOR');
      expect(params['filters[cardNumber][\$eq]'], '5');
      expect(cards.map((TcgCard c) => c.id), contains('111'));
    });

    test('is refused where the game does not number that way', () async {
      final _FakeSwu api = _FakeSwu();
      final CollectorQuery? query = CollectorQuery.parse('SOR 123a');
      expect(query, isNotNull);
      expect(await _catalogOn(api).fetchCardsByNumber(query!), isEmpty);
      expect(
        api.requests,
        isEmpty,
        reason: 'nothing is asked for a number this game cannot print',
      );
    });
  });

  group('prices', () {
    test('are not asked for, because this source publishes none', () async {
      final _FakeSwu api = _FakeSwu();
      final TcgCard card = (await _catalogOn(api).fetchCardById('111'))!;
      api.requests.clear();
      expect(await _catalogOn(api).refreshPrices(<TcgCard>[card]), isEmpty);
      expect(api.requests, isEmpty);
    });
  });
}
