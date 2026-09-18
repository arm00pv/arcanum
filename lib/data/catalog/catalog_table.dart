import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// The shared catalogue, as one query at a time.
///
/// A seam rather than the client itself, for the reason [AccountTable] is one:
/// what has to be right when the network is wrong is the routing and the
/// fallback, and neither is a thing to verify by watching a browser. A test
/// supplies a table that answers instantly, returns nothing, or throws, and
/// reads back exactly which requests the catalogue made.
///
/// Every method here is one request written in PostgREST's own terms - an
/// offset, a limit, a pattern - because that is the only part of the read path
/// a fake cannot stand in for. Deciding what to ask for, in what order, and
/// what to do with the answer belongs above this line.
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

  /// Printings whose name matches the LIKE [pattern], newest printing first.
  Future<List<Map<String, Object?>>> cardsByName(
    CardGame game,
    String pattern, {
    required int limit,
  });

  /// Printings whose name or rules text matches the LIKE [pattern].
  Future<List<Map<String, Object?>>> cardsByText(
    CardGame game,
    String pattern, {
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

  /// How much of an id filter is allowed to travel in the URL.
  ///
  /// A request line has a size an intermediary is free to refuse, and an id
  /// here is a provider's own string: Lorcana's are 36 characters, and nothing
  /// says the next game's are not longer. The bound is therefore on the filter
  /// rather than on a number of ids, and it sits comfortably inside the 8 kB
  /// request line every reverse proxy in front of PostgREST accepts.
  static const int _maxFilterChars = 3500;

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

  @override
  Future<List<Map<String, Object?>>> cardsByIds(
    CardGame game,
    List<String> ids,
  ) async {
    final out = <Map<String, Object?>>[];
    for (final List<String> batch in idBatches(ids)) {
      final List<Map<String, dynamic>> rows = await _client()
          .from(_cards)
          .select()
          .eq('game', game.id)
          .inFilter('id', batch);
      out.addAll(rows.map(Map<String, Object?>.from));
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

  @override
  Future<List<Map<String, Object?>>> cardsByName(
    CardGame game,
    String pattern, {
    required int limit,
  }) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_cards)
        .select()
        .eq('game', game.id)
        .ilike('name', pattern)
        .order('released_at', ascending: false, nullsFirst: false)
        .order('id')
        .limit(limit);
    return rows.map(Map<String, Object?>.from).toList();
  }

  @override
  Future<List<Map<String, Object?>>> cardsByText(
    CardGame game,
    String pattern, {
    required int limit,
  }) async {
    final List<Map<String, dynamic>> rows = await _client()
        .from(_cards)
        .select()
        .eq('game', game.id)
        .or('name.ilike.$pattern,oracle_text.ilike.$pattern')
        .order('released_at', ascending: false, nullsFirst: false)
        .order('id')
        .limit(limit);
    return rows.map(Map<String, Object?>.from).toList();
  }

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
  static List<List<String>> idBatches(List<String> ids) {
    final batches = <List<String>>[];
    var batch = <String>[];
    var used = 0;
    for (final String id in ids) {
      if (batch.isNotEmpty && used + id.length + 1 > _maxFilterChars) {
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
