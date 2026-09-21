import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// One game's row of the server's `catalog_meta` table.
///
/// The server publishes nine of these, one per game, and the client reads them
/// in one request. What this half of the design acts on is `sets_revision`: a
/// number that moves whenever a game's set list changes on the server, and the
/// reason a set released this morning can appear in the Sets tab this morning
/// rather than up to seven days later.
///
/// **The revision is an invalidation signal and never a presence signal.** A
/// revision this client has already seen does not mean it holds the sets: the
/// browser's SQLite is disposable, Safari evicts an origin nobody has touched,
/// and [CatalogRepository.clearCachedCatalog] deletes rows while leaving the
/// revision behind. Every one of those leaves a client that has seen revision 2
/// and holds nothing at all. What answers "do I have the sets" is
/// [CatalogDao.isCatalogued] and the local row count, exactly as before; the
/// revision only ever says "what you have is old".
///
/// `prices_revision`, `set_count`, `card_count` and `sets_updated_at` travel
/// in the same row and are deliberately not read here: section 6's price half
/// and the per-set `cards_revision` are separate work with separate costs, and
/// a field nothing acts on is a field that quietly goes wrong.
class CatalogMeta {
  const CatalogMeta({required this.game, required this.setsRevision});

  /// The game this row is about.
  final CardGame game;

  /// The revision of this game's set list on the server.
  ///
  /// Compared against what this device last read, and nothing else.
  final int setsRevision;

  /// The row as a game and a revision, or null when it names no game.
  ///
  /// An id this build does not know is dropped rather than defaulted, and that
  /// is the whole reason this does not call [CardGame.fromId]: that helper
  /// answers Magic for anything it does not recognise, so a tenth game on the
  /// server would have its revision filed against Magic's cache.
  static CatalogMeta? fromRow(Map<String, Object?> row) {
    final Object? id = row['game'];
    if (id is! String) return null;
    CardGame? game;
    for (final CardGame candidate in CardGame.values) {
      if (candidate.id == id) {
        game = candidate;
        break;
      }
    }
    if (game == null) return null;
    return CatalogMeta(
      game: game,
      setsRevision: _revision(row['sets_revision']),
    );
  }

  /// A revision as a number.
  ///
  /// The column is a `bigint`, which PostgREST sends as a JSON number - an
  /// integer while it is one, which is the only range this counter will ever
  /// reach. A null, a string it cannot read or a decimal is treated as zero
  /// rather than throwing: a row the client cannot read is a row it has no
  /// revision for, and refusing to open the Sets tab over one is the worse
  /// failure of the two.
  static int _revision(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }
}

/// The `catalog_meta` read, as one request.
///
/// A seam of its own rather than a tenth method on [CatalogTable], because it is
/// not the same kind of read as everything on that interface: those are per-game
/// card reads, one game's rows at a time, while this is one request that answers
/// for all nine games at once. Folding it in would have every existing
/// implementer of that interface grow a method for a question none of them were
/// written to ask.
///
/// Like [CatalogTable] it exists so the routing and the invalidation rule can be
/// tested without a network: a fake answers with rows, with nothing, or with a
/// thrown error, and no browser is involved in any of the three.
abstract interface class CatalogMetaTable {
  /// Every row of `catalog_meta`, as PostgREST answers `?select=*`.
  Future<List<Map<String, Object?>>> meta();
}

/// The real one, over the Supabase client the web build already holds.
class SupabaseCatalogMetaTable implements CatalogMetaTable {
  /// [client] is a function rather than a client for the reason
  /// [SupabaseCatalogTable] takes one: the catalogue is wired before
  /// `Supabase.initialize` has run, and this is only ever asked afterwards.
  const SupabaseCatalogMetaTable(this._client);

  final SupabaseClient Function() _client;

  static const String _table = 'catalog_meta';

  /// All nine rows, unfiltered.
  ///
  /// One request rather than one per game: the table is nine rows and the whole
  /// of it is cheaper to read than any subset of it, and the caller decides
  /// which row it cares about.
  @override
  Future<List<Map<String, Object?>>> meta() async {
    final List<Map<String, dynamic>> rows = await _client().from(_table).select();
    return rows.map(Map<String, Object?>.from).toList();
  }
}
