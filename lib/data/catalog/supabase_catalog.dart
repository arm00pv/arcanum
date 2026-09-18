import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/catalog_table.dart';
import 'package:arcanum/data/db/catalog_row.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A game's catalogue, read from the project's own Postgres.
///
/// The rows are the ones the device would have derived for itself - the
/// importer mirrors the provider clients' own rules and a committed vector file
/// holds the two languages to the same answer - so this class is not a third
/// way of building a card. It asks the shared tables the same questions the
/// repository used to ask Lorcast, hands the answer to the same mapper the
/// local database is read through, and leaves everything above it unchanged.
///
/// What it must not do is answer with less than it has. Every method here
/// either returns what the catalogue holds or throws; whether that is good
/// enough for the collector is [RoutedCatalog]'s decision, and that decision is
/// the only thing standing between a broken import and a browser whose Sets tab
/// is empty.
class SupabaseCatalog extends CardCatalog {
  SupabaseCatalog({
    required this.game,
    required CatalogTable table,
    bool web = kIsWeb,
  }) : _table = table,
       _web = web;

  @override
  final CardGame game;

  final CatalogTable _table;

  /// Whether the art these rows carry has to be asked for through the relay.
  ///
  /// A parameter rather than a read of [kIsWeb] at the point of use, so both
  /// addresses can be asserted in one test run - the same reason [CardArt.host]
  /// takes one.
  final bool _web;

  @override
  String get sourceName => 'Arcanum';

  /// How many rows one request asks for.
  ///
  /// Supabase caps a PostgREST response at 1,000 rows, so this is a ceiling
  /// rather than a preference: asking for more gets a page of 1,000 and a walk
  /// that believes it has finished.
  static const int _page = 1000;

  /// How many pages one read will follow before giving up.
  ///
  /// A walk ends when a page comes back short, which it cannot do if the rows
  /// it is paging over are being written while it reads. The cap turns that
  /// into a bounded read rather than a loop that never returns.
  static const int _maxPages = 200;

  /// Every set the catalogue holds for the game.
  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final rows = await _everyPage(
      (int offset, int limit) =>
          _table.sets(game, offset: offset, limit: limit),
      onProgress: onProgress,
    );
    return [
      for (final row in rows) CatalogRow.setFromRow(game, _localRow(row)),
    ];
  }

  /// Every printing of one set, in collector-number order.
  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final rows = await _everyPage(
      (int offset, int limit) =>
          _table.cardsInSet(game, setCode, offset: offset, limit: limit),
      onProgress: onProgress,
    );
    return [for (final row in rows) _card(row)];
  }

  /// A single printing by provider id.
  @override
  Future<TcgCard?> fetchCardById(String id) async {
    final row = await _table.cardById(game, id);
    return row == null ? null : _card(row);
  }

  /// The printings among [ids] the catalogue holds, in as few requests as the
  /// ids allow.
  ///
  /// One call for the whole list rather than one per id. That is not an
  /// optimisation of a detail: this is the method resolveMissingCards
  /// reconciles a whole collection through, and against a source that answers
  /// an id at a time it is the reason a first sign-in takes an afternoon
  /// rather than a minute.
  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    if (ids.isEmpty) return const <String, TcgCard>{};
    final rows = await _table.cardsByIds(game, ids);
    final out = <String, TcgCard>{};
    for (final row in rows) {
      final card = _card(row);
      out[card.id] = card;
    }
    return out;
  }

  /// Free-text search over the whole game, in one request.
  ///
  /// The ordering the app searches by - a name that *starts with* the query,
  /// then a name that contains it, then the newest printing - is a predicate
  /// PostgREST cannot order by, which is why this is the catalogue's own search
  /// rather than two filtered reads stitched together. It matters to the
  /// caller: [CatalogRepository.search] stores what arrives and re-reads it
  /// from SQLite, so results that came back in a different order would be shown
  /// in one.
  ///
  /// The query goes as the collector typed it. Escaping the two characters that
  /// mean something to a pattern is the search's own business - see
  /// `catalog_search` in tool/catalog/0003_read_functions.sql - because that
  /// endpoint is reachable by anything holding the publishable key, and a caller
  /// that forgot would be one keystroke from asking for the whole catalogue.
  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <TcgCard>[];
    final rows = await _table.search(game, q, limit: limit);
    return [for (final row in rows) _card(row)];
  }

  /// The printings a collector number names.
  ///
  /// [CatalogDao.searchByNumber] keeps its own answer for everything this
  /// device has downloaded, and this is what answers for everything it has not:
  /// a browser that has just signed in holds a collection whose rows name their
  /// cards by id and no catalogue to resolve them against, so a collector
  /// typing a number would otherwise see nothing at all.
  @override
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) async {
    final rows = await _table.cardsByNumber(
      game,
      codeCandidates: query.codeCandidates,
      number: query.number,
      standalone: query.standalone,
      limit: limit,
    );
    return [for (final row in rows) _card(row)];
  }

  /// Every printing the catalogue files under one grouping id.
  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    final rows = await _table.cardsByOracleId(game, groupId);
    return [for (final row in rows) _card(row)];
  }

  /// Current prices for the printings the catalogue quotes.
  ///
  /// Only printings that have a price row come back, and that is deliberate
  /// rather than tidy. A row is the only evidence that a number was ever read,
  /// and the caller stamps every card it is handed with the moment it was
  /// refreshed - so a printing returned with no prices would carry no prices
  /// *and* today's date, which is worse than being left alone.
  ///
  /// Prices are filled by their own importers and the table is empty for every
  /// game at the time of writing, which is why the answer is usually nothing at
  /// all: the router then asks the provider, exactly as the app does today.
  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const <TcgCard>[];
    final rows = await _table.prices(game, [
      for (final TcgCard c in cards) c.id,
    ]);

    final finishes = <String, Map<String, double?>>{};
    final secondary = <String, Map<String, double?>>{};
    final observed = <String, DateTime>{};
    for (final row in rows) {
      final String? id = row['card_id'] as String?;
      final String? code = row['code'] as String?;
      final double? price = _price(row['price']);
      if (id == null || code == null || price == null) continue;
      final into = row['kind'] == 'secondary' ? secondary : finishes;
      (into[id] ??= <String, double?>{})[code] = price;
      final DateTime? seen = _day(row['observed_on']);
      if (seen != null) observed[id] = seen;
    }

    return <TcgCard>[
      for (final TcgCard card in cards)
        if (finishes.containsKey(card.id) || secondary.containsKey(card.id))
          card.copyWith(
            prices: TcgPrices(
              byFinish: finishes[card.id] ?? const <String, double?>{},
              secondary: secondary[card.id] ?? const <String, double?>{},
              updatedAt: observed[card.id],
            ),
          ),
    ];
  }

  /// Every row a paged read has, one request per page.
  ///
  /// Progress is reported as rows read rather than as a fraction of a total,
  /// because PostgREST states no total unless it is asked to count the table,
  /// and counting a quarter of a million rows is a second query a walk does not
  /// need to answer with.
  Future<List<Map<String, Object?>>> _everyPage(
    Future<List<Map<String, Object?>>> Function(int offset, int limit) page, {
    void Function(int done, int total)? onProgress,
  }) async {
    final rows = <Map<String, Object?>>[];
    for (var read = 0; read < _maxPages; read++) {
      final answer = await page(rows.length, _page);
      rows.addAll(answer);
      onProgress?.call(rows.length, rows.length);
      if (answer.length < _page) break;
    }
    return rows;
  }

  /// One printing, from the row the catalogue answered with.
  TcgCard _card(Map<String, Object?> row) =>
      CatalogRow.cardFromRow(game, _localRow(row));

  /// A shared row, in the shape the local mapper reads.
  ///
  /// Three differences between the two databases, none of which is a column
  /// name and all of which are therefore easy to miss. Postgres stores a
  /// boolean where SQLite stores 0/1, and the mapper reads those columns as
  /// integers - a real boolean there is a type error rather than a wrong
  /// answer. Postgres stores extras as jsonb, and the mapper reads JSON text.
  ///
  /// The third is the one the design does not mention. Art is not data that
  /// travels: a browser fetches the picture itself, and three of the hosts
  /// these catalogues draw from refuse to name the browser that asks. The
  /// importer runs on a host with no origin to satisfy, so it stores the URL
  /// the provider published - and a browser that used it verbatim would show a
  /// broken image for exactly the game this step ships. [CardArt.host] is that
  /// rule, applied here because this is the last place that knows which
  /// platform is reading the row.
  Map<String, Object?> _localRow(Map<String, Object?> row) {
    final out = Map<String, Object?>.of(row);
    for (final MapEntry<String, Object?> entry in row.entries) {
      if (entry.value is bool) {
        out[entry.key] = entry.value == true ? 1 : 0;
      }
    }
    final Object? extras = row['extras'];
    out['extras_json'] = extras == null ? null : jsonEncode(extras);
    out.remove('extras');
    for (final String column in _imageColumns) {
      final Object? url = row[column];
      if (url is String && url.isNotEmpty) {
        out[column] = CardArt.host(url, web: _web);
      }
    }
    return out;
  }

  /// The columns that hold an address for a picture.
  static const List<String> _imageColumns = <String>[
    'image_small',
    'image_normal',
    'image_large',
    'image_art_crop',
    'image_png',
    'back_image_small',
    'back_image_normal',
  ];

  /// A price, whether PostgREST sends it as a number or as text.
  static double? _price(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw.trim());
    return null;
  }

  /// A date column as a day, which is all the sampler's stamp claims to be.
  static DateTime? _day(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
