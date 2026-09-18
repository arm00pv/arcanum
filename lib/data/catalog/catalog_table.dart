import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// The shared catalogue, as one request at a time.
///
/// A seam rather than the client itself, for the reason [AccountTable] is one:
/// what has to be right when the network is wrong is the routing and the
/// fallback, and neither is a thing to verify by watching a browser. A test
/// supplies a table that answers instantly, returns nothing, or throws, and
/// reads back exactly which requests the catalogue made.
///
/// Every method here is one request, said in the terms the request is actually
/// made in - an offset, a limit, a pattern, an array in a body - because that is
/// the only part of the read path a fake cannot stand in for. Deciding what to
/// ask for, in what order, and what to do with the answer belongs above this
/// line.
abstract interface class CatalogTable {
  /// Sets of one game, newest first, [limit] of them from [offset].
  ///
  /// Paged because a game's set list does not fit in one answer: Supabase caps
  /// a PostgREST response at 1,000 rows and Magic alone has 1,049 sets.
  Future<List<Map<String, Object?>>> sets(
    CardGame game, {
    required int offset,
    required int limit,
  });

  /// Printings of one set, in collector-number order, one page of them.
  Future<List<Map<String, Object?>>> cardsInSet(
    CardGame game,
    String setCode, {
    required int offset,
    required int limit,
  });

  /// The printings among [ids] the catalogue holds.
  ///
  /// The batched read the collection sync depends on. Which of the ids can be
  /// answered by one request is this layer's business, and it is never one
  /// request per id.
  Future<List<Map<String, Object?>>> cardsByIds(
    CardGame game,
    List<String> ids,
  );

  /// One printing by id, or null when the catalogue does not hold it.
  Future<Map<String, Object?>?> cardById(CardGame game, String id);

  /// Every printing the catalogue files under one oracle id.
  Future<List<Map<String, Object?>>> cardsByOracleId(
    CardGame game,
    String oracleId,
  );

  /// Printings whose name or rules text matches [query], in the order the local
  /// search ranks them: a name that starts with it, then a name that contains
  /// it, then the newest printing.
  ///
  /// [query] travels as the collector typed it. The escaping that keeps a
  /// percent sign from meaning "everything" belongs to the search the catalogue
  /// runs, and is done there, because this read is also a public endpoint that
  /// anything holding the publishable key can call.
  Future<List<Map<String, Object?>>> search(
    CardGame game,
    String query, {
    required int limit,
  });

  /// The printings a collector number names, for the parse the caller made.
  ///
  /// The candidates, the number and whether the query stands on its own are
  /// [CollectorQuery]'s answers, passed through rather than worked out again:
  /// one grammar, in one language, and this is the request that carries its
  /// result to the catalogue.
  Future<List<Map<String, Object?>>> cardsByNumber(
    CardGame game, {
    required List<String> codeCandidates,
    required String number,
    required bool standalone,
    required int limit,
  });

  /// The current prices the catalogue holds for these printings.
  Future<List<Map<String, Object?>>> prices(CardGame game, List<String> ids);
}

/// The real one, over the Supabase client the web build already holds.
class SupabaseCatalogTable implements CatalogTable {
  /// [client] is a function rather than a client because there is no client
  /// yet when this is built: the catalogue map is wired before
  /// Supabase.initialize has run, and the only build that ever asks this class
  /// anything is one where somebody signed in, long after it has.
  const SupabaseCatalogTable(this._client);

  final SupabaseClient Function() _client;

  static const String _sets = 'catalog_sets';
  static const String _cards = 'catalog_cards';
  static const String _prices = 'catalog_prices';

  static const String _byIds = 'catalog_cards_by_ids';
  static const String _searchFunc = 'catalog_search';
  static const String _byNumber = 'catalog_cards_by_number';

  /// How much of an id filter is allowed to travel in the URL.
  ///
  /// A request line has a size an intermediary is free to refuse, and an id
  /// here is a provider's own string: Lorcana's are 36 characters, and nothing
  /// says the next game's are not longer. The bound is therefore on the filter
  /// rather than on a number of ids, and it sits comfortably inside the 8 kB
  /// request line every reverse proxy in front of PostgREST accepts.
  ///
  /// This is the bound for the reads that are still filters - the prices, whose
  /// table has no RPC yet. The batched card read does not need it: its ids
  /// travel in a request body, so what bounds it is [_maxRowsPerCall].
  static const int _maxFilterChars = 3500;

  /// How many rows one answer may contain.
  ///
  /// Measured against the live project rather than assumed, because it is not
  /// the same number as the URL bound above and it is silent when it is
  /// exceeded: Supabase's REST layer truncates any response at 1,000 rows, and a
  /// `catalog_cards_by_ids` call naming 1,200 ids answers with HTTP 200 and
  /// 1,000 rows. Nothing in the answer says which ones were dropped. The
  /// repository asks about 200 at a time, so this cap is not reached in practice;
  /// it is here so that a future caller that hands over a whole collection
  /// cannot lose the tail of it without a word.
  static const int _maxRowsPerCall = 1000;

  @override
  Future<List<Map<String, Object?>>> sets(
    CardGame game, {
    required int offset,
    required int limit,
  }) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_sets)
        .select()
        .eq('game', game.id)
        // The order has to be total. Two sets released the same day sit on
        // either side of a page boundary, and which side depends on the plan
        // the server picked, so without the code tiebreak one page repeats a
        // row and another loses one.
        .order('released_at', ascending: false, nullsFirst: false)
        .order('code')
        .range(offset, offset + limit - 1);
    return rows.map(Map<String, Object?>.from).toList();
  }

  @override
  Future<List<Map<String, Object?>>> cardsInSet(
    CardGame game,
    String setCode, {
    required int offset,
    required int limit,
  }) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_cards)
        .select()
        .eq('game', game.id)
        // Lower case, because that is the form the catalogue stores and the
        // form every other layer of this app hands over.
        .eq('set_code', setCode.toLowerCase())
        .order('collector_sort')
        .order('collector_number')
        .order('id')
        .range(offset, offset + limit - 1);
    return rows.map(Map<String, Object?>.from).toList();
  }

  /// The printings among [ids] the catalogue holds, in as few requests as the
  /// response cap allows.
  ///
  /// One request per chunk rather than one per id, and the ids travel in the
  /// body rather than in a filter. That is what `catalog_cards_by_ids` is for:
  /// a browser that has just signed in resolves a whole collection through this
  /// call, and the URL it used to paste ids into ran out after about eighty of
  /// them.
  @override
  Future<List<Map<String, Object?>>> cardsByIds(
    CardGame game,
    List<String> ids,
  ) async {
    final out = <Map<String, Object?>>[];
    for (final List<String> batch in _chunks(ids, maxCount: _maxRowsPerCall)) {
      out.addAll(
        _rows(
          await _client().rpc(
            _byIds,
            params: <String, Object?>{'p_game': game.id, 'p_ids': batch},
          ),
        ),
      );
    }
    return out;
  }

  @override
  Future<Map<String, Object?>?> cardById(CardGame game, String id) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_cards)
        .select()
        .eq('game', game.id)
        .eq('id', id)
        .limit(1);
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  @override
  Future<List<Map<String, Object?>>> cardsByOracleId(
    CardGame game,
    String oracleId,
  ) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_cards)
        .select()
        .eq('game', game.id)
        .eq('oracle_id', oracleId)
        .order('released_at')
        .order('id');
    return rows.map(Map<String, Object?>.from).toList();
  }

  /// Search over the whole game, one request.
  ///
  /// The ranking the app searches by - a name that starts with the query, then
  /// a name that contains it, then the newest printing - is a predicate
  /// PostgREST cannot order by, which is why this is a function rather than a
  /// filter. It is also the only read that is cheap over a whole catalogue: the
  /// two ILIKEs inside it are what the trigram indexes are on.
  @override
  Future<List<Map<String, Object?>>> search(
    CardGame game,
    String query, {
    required int limit,
  }) async => _rows(
    await _client().rpc(
      _searchFunc,
      params: <String, Object?>{
        'p_game': game.id,
        'p_query': query,
        'p_limit': limit,
      },
    ),
  );

  @override
  Future<List<Map<String, Object?>>> cardsByNumber(
    CardGame game, {
    required List<String> codeCandidates,
    required String number,
    required bool standalone,
    required int limit,
  }) async => _rows(
    await _client().rpc(
      _byNumber,
      params: <String, Object?>{
        'p_game': game.id,
        'p_code_candidates': codeCandidates,
        'p_number': number,
        'p_standalone': standalone,
        'p_limit': limit,
      },
    ),
  );

  @override
  Future<List<Map<String, Object?>>> prices(
    CardGame game,
    List<String> ids,
  ) async {
    final out = <Map<String, Object?>>[];
    for (final List<String> batch in idBatches(ids)) {
      final List<Map<String, dynamic>> rows = await _client()
          .from(_prices)
          .select()
          .eq('game', game.id)
          .inFilter('card_id', batch);
      out.addAll(rows.map(Map<String, Object?>.from));
    }
    return out;
  }

  /// [ids] split into groups whose filter still fits a URL.
  ///
  /// One request per group and never one per id, which is the storm this path
  /// exists to remove: a browser that has just signed in holds a collection of
  /// thousands of rows and no catalogue, and asking the provider once per row
  /// is what makes that a browser left open for an afternoon.
  static List<List<String>> idBatches(List<String> ids) =>
      _chunks(ids, maxChars: _maxFilterChars);

  /// Rows a function answered with, as the maps the mapper reads.
  ///
  /// An RPC answers with the same JSON objects a select does, and nothing here
  /// assumes more than that: a function that answered with something that is not
  /// a list of objects is a broken deployment, and this reads it as no rows
  /// rather than as a crash in the middle of a sign-in.
  static List<Map<String, Object?>> _rows(Object? answer) =>
      <Map<String, Object?>>[
        for (final Object? row in answer is List ? answer : const <Object?>[])
          if (row is Map) Map<String, Object?>.from(row),
      ];

  /// [ids] in groups, bounded by [maxChars] of filter and [maxCount] of ids.
  ///
  /// Both bounds exist because the reads are made in two different places: a
  /// filter travels in the URL and a body does not, but a body's answer still
  /// comes back as a response, and a response is what the platform truncates.
  static List<List<String>> _chunks(
    List<String> ids, {
    int? maxChars,
    int? maxCount,
  }) {
    final batches = <List<String>>[];
    var batch = <String>[];
    var used = 0;
    for (final String id in ids) {
      final bool full =
          (maxCount != null && batch.length >= maxCount) ||
          (maxChars != null && used + id.length + 1 > maxChars);
      if (batch.isNotEmpty && full) {
        batches.add(batch);
        batch = <String>[];
        used = 0;
      }
      batch.add(id);
      used += id.length + 1;
    }
    if (batch.isNotEmpty) batches.add(batch);
    return batches;
  }
}
