// Reading the catalogue from the server, and proving it is the same catalogue
// the device would have derived for itself.
//
//   flutter test test/catalog/supabase_catalog_test.dart
//
// The standard this file is held to is the committed one: tool/catalog holds
// 440 real Lorcast card rows and all 24 sets, derived from the Dart client and
// asserted from the other side by tool/catalog/test_id_parity.py. Those vectors
// are exactly the shape PostgREST answers with - booleans as booleans, extras
// as a JSON object, dates as days - so feeding them through this reader is the
// whole round trip: server row to TcgCard to the row SQLite stores, compared
// against the row the provider client's own parse produces.
//
// Nothing here touches the network. The table is a fake, which is the point of
// CatalogTable existing at all.

import 'dart:convert';
import 'dart:io';

import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/catalog_table.dart';
import 'package:arcanum/data/catalog/supabase_catalog.dart';
import 'package:arcanum/data/db/catalog_row.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

const String _vectorPath = 'tool/catalog/catalog_id_vectors.json.gz';

/// The committed rows both languages are held to.
Map<String, dynamic> _vectors() {
  final File file = File(_vectorPath);
  if (!file.existsSync()) {
    fail(
      '$_vectorPath is missing; test/catalog/catalog_id_parity_test.dart '
      'regenerates it with --dart-define=UPDATE_ID_VECTORS=true',
    );
  }
  return jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())))
      as Map<String, dynamic>;
}

/// A catalogue that answers out of a list, the way PostgREST answers out of a
/// table.
///
/// It filters and pages honestly rather than replaying a canned answer, because
/// the things worth testing here are what the reader asks for - which page, in
/// which order, how many requests for a list of ids - and a fake that ignored
/// its arguments could not tell a right request from a wrong one.
class _ScriptedTable implements CatalogTable {
  _ScriptedTable({
    this.setRows = const <Map<String, Object?>>[],
    this.cardRows = const <Map<String, Object?>>[],
    this.priceRows = const <Map<String, Object?>>[],
  });

  final List<Map<String, Object?>> setRows;
  final List<Map<String, Object?>> cardRows;
  final List<Map<String, Object?>> priceRows;

  /// Every page asked for, in order.
  final List<(int, int)> pages = <(int, int)>[];

  /// Every group of ids asked for in one request.
  final List<List<String>> idBatches = <List<String>>[];

  /// Every LIKE pattern the search asked for, per query.
  final List<String> namePatterns = <String>[];
  final List<String> textPatterns = <String>[];

  List<Map<String, Object?>> _page(
    List<Map<String, Object?>> rows,
    int offset,
    int limit,
  ) => rows.skip(offset).take(limit).toList();

  @override
  Future<List<Map<String, Object?>>> sets(
    CardGame game, {
    required int offset,
    required int limit,
  }) async {
    pages.add((offset, limit));
    return _page(setRows, offset, limit);
  }

  @override
  Future<List<Map<String, Object?>>> cardsInSet(
    CardGame game,
    String setCode, {
    required int offset,
    required int limit,
  }) async {
    pages.add((offset, limit));
    return _page(
      <Map<String, Object?>>[
        for (final row in cardRows)
          if (row['set_code'] == setCode) row,
      ],
      offset,
      limit,
    );
  }

  @override
  Future<List<Map<String, Object?>>> cardsByIds(
    CardGame game,
    List<String> ids,
  ) async {
    idBatches.add(ids);
    final wanted = ids.toSet();
    return <Map<String, Object?>>[
      for (final row in cardRows)
        if (wanted.contains(row['id'])) row,
    ];
  }

  @override
  Future<Map<String, Object?>?> cardById(CardGame game, String id) async {
    for (final row in cardRows) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  @override
  Future<List<Map<String, Object?>>> cardsByOracleId(
    CardGame game,
    String oracleId,
  ) async => <Map<String, Object?>>[
    for (final row in cardRows)
      if (row['oracle_id'] == oracleId) row,
  ];

  @override
  Future<List<Map<String, Object?>>> cardsByName(
    CardGame game,
    String pattern, {
    required int limit,
  }) async {
    namePatterns.add(pattern);
    if (!pattern.endsWith('%') || pattern.startsWith('%')) {
      fail('a name search asks for a prefix, and this asked for $pattern');
    }
    final String prefix = pattern.substring(0, pattern.length - 1);
    return _page(
      <Map<String, Object?>>[
        for (final row in cardRows)
          if ((row['name'] as String).startsWith(prefix)) row,
      ],
      0,
      limit,
    );
  }

  @override
  Future<List<Map<String, Object?>>> cardsByText(
    CardGame game,
    String pattern, {
    required int limit,
  }) async {
    textPatterns.add(pattern);
    final String needle = pattern.replaceAll('%', '');
    return _page(
      <Map<String, Object?>>[
        for (final row in cardRows)
          if ((row['name'] as String).contains(needle) ||
              ((row['oracle_text'] as String?) ?? '').contains(needle))
            row,
      ],
      0,
      limit,
    );
  }

  @override
  Future<List<Map<String, Object?>>> prices(
    CardGame game,
    List<String> ids,
  ) async {
    idBatches.add(ids);
    final wanted = ids.toSet();
    return <Map<String, Object?>>[
      for (final row in priceRows)
        if (wanted.contains(row['card_id'])) row,
    ];
  }
}

/// The row SQLite would keep for [card], said in the server's own types.
///
/// The two databases differ in three types and nothing else, so the client's
/// row is turned back into the server's - integers to booleans, the extras
/// string to the object it holds - before the two are compared.
Map<String, Object?> asServerRow(Map<String, Object?> vector, TcgCard card) {
  final Map<String, Object?> stored = CatalogRow.cardToRow(
    CardGame.lorcana,
    card,
    0,
  );
  final out = <String, Object?>{};
  for (final String key in vector.keys) {
    if (key == 'extras') {
      final Object? json = stored['extras_json'];
      out[key] = json == null ? null : jsonDecode(json as String);
      continue;
    }
    final Object? value = stored[key];
    out[key] = vector[key] is bool ? value == 1 : value;
  }
  return out;
}

/// A card row of the shape the catalogue holds, with everything a test varies.
Map<String, Object?> cardRow(
  String id, {
  String setCode = '1',
  String name = 'Elsa - Snow Queen',
  String? oracleText,
  String rarity = 'Common',
  bool digital = false,
  String? imageSmall,
  String? backImageSmall,
}) => <String, Object?>{
  'id': id,
  'oracle_id': name.toLowerCase(),
  'set_code': setCode,
  'set_name': 'The First Chapter',
  'name': name,
  'collector_number': '1',
  'collector_sort': 1,
  'rarity': rarity,
  'layout': '',
  'type_line': 'Character',
  'oracle_text': oracleText,
  'mana_cost': null,
  'cmc': null,
  'colors': 'Amber',
  'color_identity': 'Amber',
  'artist': null,
  'flavor_text': null,
  'image_small': imageSmall,
  'image_normal': null,
  'image_large': null,
  'image_art_crop': null,
  'image_png': null,
  'back_image_small': backImageSmall,
  'back_image_normal': null,
  'digital': digital,
  'promo': false,
  'reprint': false,
  'reserved': false,
  'full_art': false,
  'booster': false,
  'foil': false,
  'nonfoil': false,
  'edhrec_rank': null,
  'released_at': '2023-08-18',
  'extras': <String, Object?>{'inkwell': true},
};

/// Structural equality over decoded JSON.
///
/// Written out rather than pulled from package:collection for the same reason
/// the parity test writes its own: a column holding an object or a list is
/// compared by what is in it, not by which instance it is.
bool _sameJson(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final Object? key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!_sameJson(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// An id of the length and shape the provider's are, so a filter that fits one
/// fits them all.
String idAt(int index) => 'crd_${index.toString().padLeft(32, '0')}';

void main() {
  late Map<String, dynamic> vectors;
  late List<Map<String, Object?>> cardVectors;
  late List<Map<String, Object?>> setVectors;

  setUpAll(() {
    vectors = _vectors();
    cardVectors = <Map<String, Object?>>[
      for (final dynamic raw in vectors['cards'] as List<dynamic>)
        Map<String, Object?>.from(raw as Map<dynamic, dynamic>),
    ];
    setVectors = <Map<String, Object?>>[
      for (final dynamic raw in vectors['sets'] as List<dynamic>)
        Map<String, Object?>.from(raw as Map<dynamic, dynamic>),
    ];
  });

  group('the rows the catalogue holds', () {
    test('are the rows this client derives, card for card', () async {
      // The test the whole step rests on. An importer that derives an id, a
      // name or a sort key a character differently from the Dart client leaves
      // a collector holding a card that renders as "--" for ever, and nothing
      // anywhere says why.
      final table = _ScriptedTable(cardRows: cardVectors);
      final catalog = SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
        web: false,
      );

      final byId = <String, Map<String, Object?>>{
        for (final row in cardVectors) row['id'] as String: row,
      };
      final codes = <String>{
        for (final row in cardVectors) row['set_code'] as String,
      };

      var seen = 0;
      final problems = <String>[];
      for (final String code in codes) {
        for (final TcgCard card in await catalog.fetchCardsInSet(code)) {
          final Map<String, Object?>? vector = byId[card.id];
          if (vector == null) {
            problems.add('${card.id} is in the catalogue and in no vector');
            continue;
          }
          final Map<String, Object?> here = asServerRow(vector, card);
          for (final String key in vector.keys) {
            if (!_sameJson(here[key], vector[key])) {
              problems.add(
                '${card.id}: $key comes back as ${here[key]} where the client '
                'derives ${vector[key]}',
              );
            }
          }
          seen++;
        }
      }

      expect(problems, isEmpty, reason: problems.take(6).join('; '));
      expect(seen, cardVectors.length);
    });

    test('are the sets this client derives, set for set', () async {
      final table = _ScriptedTable(setRows: setVectors);
      final catalog = SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
        web: false,
      );

      final byCode = <String, Map<String, Object?>>{
        for (final row in setVectors) row['code'] as String: row,
      };
      final sets = await catalog.fetchAllSets();
      expect(sets.length, setVectors.length);
      for (final TcgSet set in sets) {
        final Map<String, Object?>? vector = byCode[set.code];
        expect(vector, isNotNull, reason: 'set $set.code has no vector');
        expect(
          <String, Object?>{
            'code': set.code,
            'id': set.id,
            'name': set.name,
            'set_type': set.setType,
            'released_at': set.releasedAt?.toIso8601String().split('T').first,
            'card_count': set.cardCount,
            'printed_size': set.printedSize,
            'icon_svg_uri': set.iconSvgUri,
            'logo_uri': set.logoUri,
            'series': set.series,
            'digital': set.digital,
            'foil_only': set.foilOnly,
            'nonfoil_only': set.nonfoilOnly,
            'parent_set_code': set.parentSetCode,
            'block_code': set.blockCode,
            'block': set.block,
            'collector_number_start': set.collectorNumberStart,
          },
          <String, Object?>{
            for (final String key in vector!.keys) key: vector[key],
          },
        );
      }
    });
  });

  group('the columns Postgres types differently', () {
    test('arrive as the local row the mapper reads', () async {
      final table = _ScriptedTable(
        cardRows: <Map<String, Object?>>[cardRow('crd_bools', digital: true)],
      );
      final card = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
        web: false,
      ).fetchCardById('crd_bools');

      expect(card, isNotNull);
      // A boolean read as an integer is a type error in the mapper rather than
      // a wrong answer, so this is the conversion or nothing.
      expect(card!.digital, isTrue);
      expect(card.foil, isFalse);
      // jsonb in, JSON text for the mapper, a map for the caller.
      expect(card.extras, <String, Object?>{'inkwell': true});
    });

    test('the art a browser may not ask for goes through the relay', () async {
      const String direct =
          'https://tcgplayer-cdn.tcgplayer.com/product/544498_400w.jpg';
      const String clean = 'https://cards.scryfall.io/normal/front/a.jpg';
      final table = _ScriptedTable(
        cardRows: <Map<String, Object?>>[
          cardRow('crd_art', imageSmall: direct, backImageSmall: clean),
        ],
      );

      final TcgCard? phone = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
      ).fetchCardById('crd_art');
      expect(phone!.imageUris['small'], direct);

      final TcgCard? browser = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
        web: true,
      ).fetchCardById('crd_art');
      final String? relayed = browser!.imageUris['small'];
      expect(relayed, isNot(direct));
      expect(relayed, CardArt.host(direct, web: true));
      // The back of a card is art too, and it travels the same way.
      expect(browser.faces, hasLength(2));
      expect(browser.faces[1].imageUris['small'], clean);
      // A host that does name the browser is left alone, relay or not.
      expect(
        CardArt.host(clean, web: true),
        clean,
        reason: 'the relay is for the three hosts that refuse the browser',
      );
    });
  });

  group('a list of ids', () {
    test('is one request for the chunk and never one per card', () async {
      final ids = <String>[for (var i = 0; i < 200; i++) idAt(i)];
      final table = _ScriptedTable(
        cardRows: <Map<String, Object?>>[
          for (final String id in ids) cardRow(id),
        ],
      );
      final cards = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
      ).fetchCardsByIds(ids);

      expect(cards.length, 200);
      expect(
        table.idBatches,
        hasLength(1),
        reason: 'the chunk the repository hands over is asked for once',
      );
      expect(table.idBatches.single, ids);
    });

    test('is split only when the filter would not fit a URL', () {
      final List<String> twenty = <String>[
        for (var i = 0; i < 20; i++) idAt(i),
      ];
      expect(SupabaseCatalogTable.idBatches(twenty), hasLength(1));

      final List<String> many = <String>[for (var i = 0; i < 400; i++) idAt(i)];
      final batches = SupabaseCatalogTable.idBatches(many);
      expect(batches.length, greaterThan(1));
      // Nothing lost and nothing reordered: a dropped id is a card that
      // silently never resolves.
      expect(<String>[for (final batch in batches) ...batch], many);
      final sizes = <int>[for (final batch in batches) batch.length];
      expect(sizes.first, greaterThan(10), reason: 'a group is filled');
      expect(SupabaseCatalogTable.idBatches(<String>[]), isEmpty);
    });
  });

  group('a set list longer than one page', () {
    test('is asked for page by page', () async {
      // Magic has 1,049 sets and Supabase answers with 1,000 rows, so the game
      // the design is really written for is the one a single unpaged request
      // would truncate.
      final rows = <Map<String, Object?>>[
        for (var i = 0; i < 1049; i++)
          <String, Object?>{
            'code': 'set$i',
            'id': 'set_$i',
            'name': 'Set $i',
            'set_type': 'expansion',
            'released_at': null,
            'card_count': 0,
          },
      ];
      final table = _ScriptedTable(setRows: rows);
      final sets = await SupabaseCatalog(
        game: CardGame.mtg,
        table: table,
      ).fetchAllSets();

      expect(sets, hasLength(1049));
      expect(table.pages, <(int, int)>[(0, 1000), (1000, 1000)]);
    });
  });

  group('search', () {
    test(
      'puts a name that starts with the query before one that mentions it',
      () async {
        final table = _ScriptedTable(
          cardRows: <Map<String, Object?>>[
            cardRow(
              'crd_anna',
              name: 'Anna - Heir to Arendelle',
              oracleText: 'Sings about Elsa.',
            ),
            cardRow('crd_elsa', name: 'Elsa - Snow Queen'),
          ],
        );
        final results = await SupabaseCatalog(
          game: CardGame.lorcana,
          table: table,
        ).search('Elsa');

        expect(
          <String>[for (final TcgCard c in results) c.id],
          <String>['crd_elsa', 'crd_anna'],
          reason:
              'the local search orders the same way, and the caller re-reads '
              'the cache after storing what arrives',
        );
        expect(table.namePatterns, <String>['Elsa%']);
        expect(table.textPatterns, <String>['%Elsa%']);
      },
    );

    test('is one request when the names alone fill the answer', () async {
      final table = _ScriptedTable(
        cardRows: <Map<String, Object?>>[
          cardRow('crd_elsa', name: 'Elsa - Snow Queen'),
        ],
      );
      final results = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
      ).search('Elsa', limit: 1);

      expect(results, hasLength(1));
      expect(table.namePatterns, hasLength(1));
      expect(table.textPatterns, isEmpty);
    });

    test(
      'escapes the characters that would ask a different question',
      () async {
        final table = _ScriptedTable();
        final catalog = SupabaseCatalog(game: CardGame.lorcana, table: table);
        await catalog.search('50%');
        await catalog.search('a_b');

        expect(table.namePatterns, <String>['50\\%%', 'a\\_b%']);
      },
    );
  });

  group('prices', () {
    test('come back only for the printings the catalogue quotes', () async {
      final table = _ScriptedTable(
        priceRows: <Map<String, Object?>>[
          <String, Object?>{
            'card_id': 'crd_a',
            'kind': 'finish',
            'code': 'nonfoil',
            'price': 1.25,
            'observed_on': '2026-09-18',
          },
          <String, Object?>{
            'card_id': 'crd_a',
            'kind': 'finish',
            'code': 'foil',
            'price': '3.50',
          },
          <String, Object?>{
            'card_id': 'crd_a',
            'kind': 'secondary',
            'code': 'eur',
            'price': 2,
          },
        ],
      );
      const TcgCard a = TcgCard(
        game: CardGame.lorcana,
        id: 'crd_a',
        setCode: '1',
        setName: 'The First Chapter',
        name: 'Elsa - Snow Queen',
        collectorNumber: '1',
        rarity: 'Common',
        prices: TcgPrices(byFinish: <String, double?>{'nonfoil': 99.0}),
      );
      const TcgCard b = TcgCard(
        game: CardGame.lorcana,
        id: 'crd_b',
        setCode: '1',
        setName: 'The First Chapter',
        name: 'Anna - Heir to Arendelle',
        collectorNumber: '2',
        rarity: 'Common',
        prices: TcgPrices(byFinish: <String, double?>{'nonfoil': 99.0}),
      );

      final fresh = await SupabaseCatalog(
        game: CardGame.lorcana,
        table: table,
      ).refreshPrices(<TcgCard>[a, b]);

      expect(
        <String>[for (final TcgCard c in fresh) c.id],
        <String>['crd_a'],
        reason:
            'a printing the catalogue cannot price is left as it was, so '
            'the caller does not stamp it with today',
      );
      expect(fresh.single.prices.byFinish['nonfoil'], 1.25);
      expect(fresh.single.prices.byFinish['foil'], 3.5);
      expect(fresh.single.prices.secondary['eur'], 2.0);
      expect(fresh.single.prices.updatedAt, DateTime(2026, 9, 18));
      expect(table.idBatches.single, <String>['crd_a', 'crd_b']);
    });

    test('are nothing at all when the catalogue holds no rows', () async {
      final fresh =
          await SupabaseCatalog(
            game: CardGame.lorcana,
            table: _ScriptedTable(),
          ).refreshPrices(<TcgCard>[
            const TcgCard(
              game: CardGame.lorcana,
              id: 'crd_a',
              setCode: '1',
              setName: 'The First Chapter',
              name: 'Elsa - Snow Queen',
              collectorNumber: '1',
              rarity: 'Common',
            ),
          ]);
      expect(fresh, isEmpty);
    });
  });
}
