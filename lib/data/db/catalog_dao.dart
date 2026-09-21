import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/codes.dart';
import 'package:arcanum/data/db/catalog_row.dart';
import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/set_completion.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// How a set list should be ordered.
enum SetSort {
  /// Newest release first — the default browsing order.
  newest,

  /// Oldest first, for collectors walking the history of the game.
  oldest,

  /// Alphabetical by name.
  name,

  /// Largest sets first.
  size,

  /// Furthest along first, so the sets worth finishing are the ones on screen.
  ///
  /// Only meaningful with a completion figure alongside, which is why the
  /// ordering itself happens in the screen rather than in SQL: the counts come
  /// from a table this query does not join.
  progress,
}

/// Persistence for the card catalogue (sets and printings).
///
/// Every method is scoped to one game, and no query can ever return rows from
/// two games at once. Card data is effectively immutable, so a set is only
/// re-fetched when the caller explicitly asks for it; prices are stored
/// alongside the printing and refreshed on their own schedule.
class CatalogDao {
  CatalogDao(this._db);

  final Database _db;

  // ------------------------------------------------------------------- sets

  /// Inserts or updates a batch of sets for one game.
  ///
  /// A published card count is never replaced by a zero. Not every provider
  /// states one in its set list - Lorcast states none anywhere - and the size is
  /// then learned from the set's own card list and written back by
  /// [setCardCount]. Without this an ordinary refresh of the set list would wipe
  /// every size the app had learned, which is both a lie in the row and the end
  /// of sorting sets by size.
  Future<void> upsertSets(CardGame game, List<TcgSet> sets) async {
    if (sets.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final known = await _setCardCounts(game, [for (final s in sets) s.code]);
    final batch = _db.batch();
    for (final s in sets) {
      final learned = known[s.code] ?? 0;
      batch.insert('sets', {
        'game': game.id,
        'code': s.code,
        'id': s.id,
        'name': s.name,
        'set_type': s.setType,
        'released_at': s.releasedAt?.toIso8601String().split('T').first,
        'card_count': s.cardCount > 0 ? s.cardCount : learned,
        'printed_size': s.printedSize,
        'icon_svg_uri': s.iconSvgUri,
        'logo_uri': s.logoUri,
        'series': s.series,
        'digital': s.digital ? 1 : 0,
        'foil_only': s.foilOnly ? 1 : 0,
        'nonfoil_only': s.nonfoilOnly ? 1 : 0,
        'parent_set_code': s.parentSetCode,
        'block_code': s.blockCode,
        'block': s.block,
        'collector_number_start': s.collectorNumberStart,
        'fetched_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// The stored card count for each of [codes], where one is known.
  Future<Map<String, int>> _setCardCounts(
    CardGame game,
    List<String> codes,
  ) async {
    final out = <String, int>{};
    for (var i = 0; i < codes.length; i += 400) {
      final chunk = codes.sublist(
        i,
        i + 400 > codes.length ? codes.length : i + 400,
      );
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT code, card_count FROM sets WHERE game = ? AND code IN ($marks)',
        [game.id, ...chunk],
      );
      for (final r in rows) {
        final count = (r['card_count'] as num?)?.toInt() ?? 0;
        if (count > 0) out[r['code'] as String] = count;
      }
    }
    return out;
  }

  /// All cached sets for a game, ordered by [sort].
  Future<List<TcgSet>> sets(
    CardGame game, {
    String? search,
    Set<String>? types,
    bool includeDigital = false,
    SetSort sort = SetSort.newest,
  }) async {
    final where = <String>['game = ?'];
    final args = <Object?>[game.id];
    if (search != null && search.trim().isNotEmpty) {
      final like = '%${search.trim()}%';
      final folded = Codes.fold(search);
      if (folded.isEmpty) {
        where.add('(name LIKE ? OR code LIKE ?)');
        args
          ..add(like)
          ..add(like);
      } else {
        // The code as printed, as well as the code as stored: SQLite has no
        // regular expressions to fold with, so the column is rebuilt without
        // its separators one replace() at a time (see Codes).
        where.add(
          '(name LIKE ? OR code LIKE ? '
          'OR ${Codes.foldedSql('code')} LIKE ?)',
        );
        args
          ..add(like)
          ..add(like)
          ..add('%$folded%');
      }
    }
    if (types != null && types.isNotEmpty) {
      where.add('set_type IN (${List.filled(types.length, '?').join(',')})');
      args.addAll(types);
    }
    if (!includeDigital) where.add('digital = 0');

    final orderBy = switch (sort) {
      SetSort.newest => 'released_at DESC NULLS LAST, name ASC',
      SetSort.oldest => 'released_at ASC NULLS LAST, name ASC',
      SetSort.name => 'name COLLATE NOCASE ASC',
      SetSort.size => 'card_count DESC',
      // The database cannot order by completion - the counts live in the
      // collection, not in this table - so it falls back to the default order
      // and the screen re-sorts what comes back.
      SetSort.progress => 'released_at DESC NULLS LAST, name ASC',
    };

    final rows = await _db.query(
      'sets',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: orderBy,
    );
    return rows.map((r) => CatalogRow.setFromRow(game, r)).toList();
  }

  /// A single set by code.
  Future<TcgSet?> set(CardGame game, String code) async {
    final rows = await _db.query(
      'sets',
      where: 'game = ? AND code = ?',
      whereArgs: [game.id, code],
      limit: 1,
    );
    return rows.isEmpty ? null : CatalogRow.setFromRow(game, rows.first);
  }

  /// Distinct set types present in a game's cache, with counts.
  Future<Map<String, int>> setTypeCounts(
    CardGame game, {
    bool includeDigital = false,
  }) async {
    final rows = await _db.rawQuery(
      'SELECT set_type, COUNT(*) AS n FROM sets WHERE game = ? '
      '${includeDigital ? '' : 'AND digital = 0 '}'
      'GROUP BY set_type ORDER BY n DESC',
      [game.id],
    );
    return {
      for (final r in rows) (r['set_type'] as String): (r['n'] as num).toInt(),
    };
  }

  /// How many sets of a game are cached.
  Future<int> setCount(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM sets WHERE game = ?',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// When a game's catalogue was last refreshed.
  Future<DateTime?> setsFetchedAt(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT MAX(fetched_at) AS t FROM sets WHERE game = ?',
      [game.id],
    );
    final t = (r.first['t'] as num?)?.toInt();
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }

  /// The key a game's server revision is remembered under.
  ///
  /// `meta` rather than a column, because the client's memory of "which
  /// revision of this game's set list have I read" is not a fact about a set and
  /// not a fact about a card - it is one number per game, and the local database
  /// already has a table for exactly that. It also means no schema change: the
  /// per-set `cards_revision` of section 6 is the half that wants a column, and
  /// this half deliberately does not need one.
  ///
  /// The game is in the key rather than in a second column, so a game that has
  /// never been read from the server simply has no row, and [clearGame] - which
  /// deletes sets and cards - cannot take the revision with it by accident.
  static String setsRevisionKey(CardGame game) => 'catalog_sets_rev:${game.id}';

  /// The revision of a game's set list this device last read, or null.
  ///
  /// Null means "never read one", which is not zero and is not "the sets are
  /// here" - see [setSetsRevision] and [CatalogRepository.loadSets].
  Future<int?> setsRevision(CardGame game) async {
    final rows = await _db.query(
      'meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[setsRevisionKey(game)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return int.tryParse((rows.first['value'] as String?) ?? '');
  }

  /// Records the revision of the set list this device has just read.
  ///
  /// Written *after* a read that came back and never before one: the row is a
  /// claim about what this client has in hand, so a read that failed must leave
  /// the previous number where it was, or the next visit would believe itself
  /// up to date on the strength of a request that never arrived.
  ///
  /// What this number is not is permission to show an empty Sets tab. A client
  /// that has read revision 2 and then had its rows deleted - a cleared cache,
  /// Safari evicting the origin, a game removed to reclaim space - has still
  /// read revision 2, and its presence question is answered by the local rows
  /// and by [isCatalogued], exactly as it was before any of this existed.
  Future<void> setSetsRevision(CardGame game, int revision) async {
    await _db.insert('meta', <String, Object?>{
      'key': setsRevisionKey(game),
      'value': '$revision',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The key a game's server price revision is remembered under.
  ///
  /// The same `meta` row as [setsRevisionKey], written under the name section 6
  /// of docs/catalogue-server-side.md gives it. A key of its own rather than a
  /// second value behind one key, because the two revisions move independently:
  /// a night's price import moves one of them and a set list that has not changed
  /// moves neither, so a client that had read one must not be able to mistake it
  /// for the other. The game is in the key for the reason it is in the sets key -
  /// a game never read from the server simply has no row, and [clearGame] cannot
  /// take the revision with it by accident.
  static String pricesRevisionKey(CardGame game) =>
      'catalog_prices_rev:${game.id}';

  /// The price revision this device last read for a game, or null.
  ///
  /// Null means "never read one", and is not zero and not "the prices are here" -
  /// see [setPricesRevision] and [CatalogRepository.refreshStalePrices]. A row
  /// this build cannot parse reads as null too, which sends the next visit to the
  /// server: the safe direction, and the same one [setsRevision] takes.
  Future<int?> pricesRevision(CardGame game) async {
    final rows = await _db.query(
      'meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[pricesRevisionKey(game)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return int.tryParse((rows.first['value'] as String?) ?? '');
  }

  /// Records the price revision this device has just read.
  ///
  /// Written *after* a read that came back and never before one, exactly as
  /// [setSetsRevision] is: the row is a claim about what this client has in hand,
  /// so a read that failed must leave the previous number where it was, or the
  /// next visit would believe its prices current on the strength of a request
  /// that never arrived.
  ///
  /// What it is not is permission to show a price. A client that has read
  /// revision 3 and then lost its rows - a cleared cache, Safari evicting the
  /// origin - has still read revision 3, and whether it holds a price is a
  /// question for the rows themselves.
  Future<void> setPricesRevision(CardGame game, int revision) async {
    await _db.insert('meta', <String, Object?>{
      'key': pricesRevisionKey(game),
      'value': '$revision',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// How much of each cached set the collector owns, keyed by set code.
  ///
  /// Counted in binder slots, not printings, because that is the unit every
  /// screen already counts in. Yu-Gi-Oh! lists one card several times over - by
  /// rarity and by region - and a collector who owns Blue-Eyes at LOB-000 has
  /// not left two thirds of that slot empty. A slot is a name at a collector
  /// number, which is the identity `groupIntoSlots` uses, folded to lowercase
  /// so a provider that varies the case of a name does not invent a second
  /// slot.
  ///
  /// One query for the whole game rather than one per set: a game can hold a
  /// thousand sets, and a progress bar per row is not worth a thousand round
  /// trips to SQLite.
  Future<Map<String, SetCompletion>> setCompletion(CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT s.code AS code,
             s.name AS name,
             s.card_count AS published,
             (SELECT COUNT(DISTINCT lower(c.name) || '#' || c.collector_number)
                FROM cards c
               WHERE c.game = s.game AND c.set_code = s.code) AS slots,
             (SELECT COUNT(DISTINCT lower(c.name) || '#' || c.collector_number)
                FROM collection_entries e
                JOIN cards c ON c.id = e.card_id AND c.game = e.game
               WHERE e.game = s.game AND c.set_code = s.code
                 AND e.deleted_at IS NULL) AS owned
        FROM sets s
       WHERE s.game = ?
    ''',
      [game.id],
    );

    return {
      for (final r in rows)
        (r['code'] as String): SetCompletion(
          code: r['code'] as String,
          name: (r['name'] as String?) ?? '',
          owned: (r['owned'] as num?)?.toInt() ?? 0,
          total: (r['slots'] as num?)?.toInt() ?? 0,
          published: (r['published'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  // ------------------------------------------------------------------ cards

  /// Columns a thinner record is allowed to be silent about.
  ///
  /// Every one of these is nullable catalogue metadata that a partial answer
  /// simply does not carry. Prices are deliberately absent: a refresh is meant
  /// to replace them, and holding a stale quote because today's answer was
  /// empty would show a price no provider currently stands behind.
  static const _fillable = <String>[
    'oracle_id',
    'set_name',
    'layout',
    'type_line',
    'oracle_text',
    'mana_cost',
    'cmc',
    'colors',
    'color_identity',
    'artist',
    'flavor_text',
    'image_small',
    'image_normal',
    'image_large',
    'image_art_crop',
    'image_png',
    'back_image_small',
    'back_image_normal',
    'edhrec_rank',
    'released_at',
    'extras_json',
  ];

  /// Fills the gaps in [row] from what is already stored.
  ///
  /// The same printing arrives in very different states of completeness. A set
  /// download knows its release date, its art and its rules; a search hit, or a
  /// price refresh, may know none of them. Replacing blindly let the thinner
  /// record win, so searching for a card could blank the release date its set
  /// had already stored - and Pokémon is where that bites, because TCGdex's
  /// card response carries no date and Scryfall's always does.
  static void _keepKnownFields(
    Map<String, Object?> row,
    Map<String, Object?> prior,
  ) {
    for (final key in _fillable) {
      final stored = prior[key];
      if (stored == null || stored == '') continue;
      final incoming = row[key];
      if (incoming == null || incoming == '') row[key] = stored;
    }
    // 'unknown' is the catalogue's word for "the provider did not say", not a
    // rarity a card can have, so it never displaces a real one.
    if (row['rarity'] == 'unknown') {
      final stored = prior['rarity'];
      if (stored is String && stored.isNotEmpty && stored != 'unknown') {
        row['rarity'] = stored;
      }
    }
  }

  /// The stored rows for [ids], keyed by id.
  Future<Map<String, Map<String, Object?>>> _rowsById(
    CardGame game,
    List<String> ids,
  ) async {
    final out = <String, Map<String, Object?>>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT * FROM cards WHERE game = ? AND id IN ($marks)',
        [game.id, ...chunk],
      );
      for (final r in rows) {
        out[r['id'] as String] = r;
      }
    }
    return out;
  }

  /// Inserts or updates printings, without letting a partial answer erase what
  /// is already known about one.
  Future<void> upsertCards(CardGame game, List<TcgCard> cards) async {
    if (cards.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final prior = await _rowsById(game, [for (final c in cards) c.id]);
    final batch = _db.batch();
    for (final c in cards) {
      final row = CatalogRow.cardToRow(game, c, now);
      final stored = prior[c.id];
      if (stored != null) _keepKnownFields(row, stored);
      batch.insert('cards', row, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Marks a set as fully catalogued.
  Future<void> markCatalogued(CardGame game, String setCode) async {
    await _db.update(
      'sets',
      {'catalogued_at': DateTime.now().millisecondsSinceEpoch},
      where: 'game = ? AND code = ?',
      whereArgs: [game.id, setCode],
    );
  }

  /// Records how many printings a set actually delivered.
  ///
  /// Not every provider publishes a card count up front: Lorcast's set list
  /// carries none at all, so the only place the real number exists is the set's
  /// own card list. Writing it back once that list has been read is what makes
  /// the set row show a size, and what stops [isCatalogued] from deciding the
  /// set is never complete.
  Future<void> setCardCount(CardGame game, String setCode, int count) async {
    if (count <= 0) return;
    await _db.update(
      'sets',
      {'card_count': count},
      where: 'game = ? AND code = ? AND card_count < ?',
      whereArgs: [game.id, setCode, count],
    );
  }

  /// When the shop was last asked for this set's printings, or null if never.
  ///
  /// The answer is what tells a set the shop has published nothing for apart
  /// from one that has never been looked up. They look identical on screen and
  /// are not the same problem: one is a tap away from being solved and the other
  /// is nobody's to solve.
  Future<DateTime?> cataloguedAt(CardGame game, String setCode) async {
    final rows = await _db.query(
      'sets',
      columns: <String>['catalogued_at'],
      where: 'game = ? AND code = ?',
      whereArgs: <Object?>[game.id, setCode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    // The column is a counter defaulting to zero, not a nullable timestamp, so
    // zero is "never" rather than the first second of 1970.
    final at = (rows.first['catalogued_at'] as num?)?.toInt() ?? 0;
    return at <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// True when every printing of a set is already stored.
  Future<bool> isCatalogued(CardGame game, String setCode) async {
    final r = await _db.rawQuery(
      'SELECT s.card_count AS expected, s.catalogued_at AS asked, '
      '  (SELECT COUNT(*) FROM cards c WHERE c.game = s.game AND c.set_code = s.code) AS actual '
      'FROM sets s WHERE s.game = ? AND s.code = ?',
      [game.id, setCode],
    );
    if (r.isEmpty) return false;
    final expected = (r.first['expected'] as num?)?.toInt() ?? 0;
    final actual = (r.first['actual'] as num?)?.toInt() ?? 0;
    // Pokémon sets report both a printedTotal and a secret-card total that can
    // disagree with the API's card list, so a small shortfall still counts as
    // catalogued.
    //
    // A set whose provider publishes no count at all is catalogued as soon as
    // anything from it is stored: expecting zero cards forever would mean
    // re-downloading the set on every visit.
    if (expected <= 0) {
      if (actual > 0) return true;
      // Nothing stored, and nothing expected. If the shop was asked and answered
      // nothing - an unreleased group page, a run of promos it has never stocked
      // - that answer stands for a day rather than being asked again on every
      // visit. A day is the interval because a group page with no products on it
      // is exactly what a set about to be released looks like.
      final asked = (r.first['asked'] as num?)?.toInt() ?? 0;
      if (asked <= 0) return false;
      return DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(asked),
          ) <
          const Duration(days: 1);
    }
    return actual >= (expected * 0.98).floor();
  }

  /// Every stored printing of a set, ordered by collector number.
  ///
  /// This is the ordering collectors expect: cards sit in the same sequence as
  /// a physical binder.
  Future<List<TcgCard>> cardsInSet(CardGame game, String setCode) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND set_code = ?',
      whereArgs: [game.id, setCode],
      orderBy: 'collector_sort ASC, collector_number ASC',
    );
    return rows.map((r) => CatalogRow.cardFromRow(game, r)).toList();
  }

  /// A single printing by provider id.
  Future<TcgCard?> cardById(CardGame game, String id) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND id = ?',
      whereArgs: [game.id, id],
      limit: 1,
    );
    return rows.isEmpty ? null : CatalogRow.cardFromRow(game, rows.first);
  }

  /// A single printing, addressed the way a deck list writes one.
  ///
  /// `(LEA) 161` is how every deck site, every trade list and every spreadsheet
  /// names a card, and it is the only address that survives a card being
  /// reprinted: a name alone matches thirty printings and picks the wrong one.
  /// Set codes are folded to lowercase because that is how they are stored.
  Future<TcgCard?> cardByNumber(
    CardGame game,
    String setCode,
    String collectorNumber,
  ) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND set_code = ? AND collector_number = ?',
      whereArgs: <Object?>[game.id, setCode.toLowerCase(), collectorNumber],
      limit: 1,
    );
    return rows.isEmpty ? null : CatalogRow.cardFromRow(game, rows.first);
  }

  /// Every printing of this name in this set, cheapest-first by number.
  Future<List<TcgCard>> cardsByNameInSet(
    CardGame game,
    String name,
    String setCode,
  ) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND set_code = ? AND name = ? COLLATE NOCASE',
      whereArgs: <Object?>[game.id, setCode.toLowerCase(), name.trim()],
      orderBy: 'collector_sort ASC, collector_number ASC',
    );
    return rows
        .map((Map<String, Object?> r) => CatalogRow.cardFromRow(game, r))
        .toList();
  }

  /// Many printings by id, keyed by id.
  Future<Map<String, TcgCard>> cardsByIds(
    CardGame game,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const {};
    final out = <String, TcgCard>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT * FROM cards WHERE game = ? AND id IN ($marks)',
        [game.id, ...chunk],
      );
      for (final r in rows) {
        final c = CatalogRow.cardFromRow(game, r);
        out[c.id] = c;
      }
    }
    return out;
  }

  /// The ids in [ids] that no printing is stored for.
  ///
  /// A collection names its cards by id while the catalogue arrives set by set,
  /// so the two only line up once something has asked for the printing. This is
  /// how a caller about to spend requests on the network finds out what to ask
  /// for, and it answers from one query rather than a read per id: on a device
  /// that has just signed in the answer is usually every id, and on one that has
  /// been used for a while it is none of them.
  Future<List<String>> missingCardIds(CardGame game, List<String> ids) async {
    if (ids.isEmpty) return const [];
    final known = <String>{};
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT id FROM cards WHERE game = ? AND id IN ($marks)',
        [game.id, ...chunk],
      );
      for (final r in rows) {
        known.add(r['id'] as String);
      }
    }
    return <String>[
      for (final id in ids)
        if (!known.contains(id)) id,
    ];
  }

  /// Every printing sharing a group id (all reprints of a card).
  Future<List<TcgCard>> printingsOf(CardGame game, String groupId) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND oracle_id = ?',
      whereArgs: [game.id, groupId],
      orderBy: 'released_at ASC NULLS LAST',
    );
    return rows.map((r) => CatalogRow.cardFromRow(game, r)).toList();
  }

  /// Search across everything cached for a game, newest first.
  ///
  /// Matches the name or the rules text, because those are the two things the
  /// search screen promises and the only two the cached catalogue can answer
  /// offline. Name matches come first: someone typing "Charizard" wants the
  /// card, not the twelve cards that mention it in their rules.
  ///
  /// This is the local half of a search. It can only answer for cards the user
  /// has already browsed, which is why the repository still asks the provider
  /// when it comes up short.
  Future<List<TcgCard>> searchCached(
    CardGame game,
    String query, {
    int limit = 80,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final rows = await _db.rawQuery(
      'SELECT * FROM cards WHERE game = ? AND (name LIKE ? COLLATE NOCASE '
      'OR oracle_text LIKE ? COLLATE NOCASE) '
      'ORDER BY (name LIKE ? COLLATE NOCASE) DESC, '
      '  (name LIKE ? COLLATE NOCASE) DESC, '
      '  released_at DESC NULLS LAST LIMIT ?',
      [game.id, '%$q%', '%$q%', '$q%', '%$q%', limit],
    );
    return rows.map((r) => CatalogRow.cardFromRow(game, r)).toList();
  }

  /// Printings named by their collector number, or null when [query] is not a
  /// number query at all.
  ///
  /// Null is the answer for "Charizard", and it is what keeps the caller on the
  /// name-and-text path. A number is only believed when the query is nothing but
  /// the number, or when the part in front of it turns out to be a set code this
  /// game actually has - the catalogue is the only thing that knows, which is
  /// why the parse happens here rather than in the caller.
  ///
  /// Scoped to one game, like every other read of this table: "#001" means a
  /// different card in Digimon, in Magic and in Yu-Gi-Oh!, and the same id in
  /// two games is two printings, not one.
  ///
  /// A bare number is matched across the whole game and comes back ordered by
  /// set, newest first. That is not a tidy answer, and it is the true one: the
  /// number is not unique by itself, so the caller is given every printing that
  /// carries it, each labelled with the set it is in.
  Future<List<TcgCard>?> searchByNumber(
    CardGame game,
    String query, {
    int limit = 80,
  }) async {
    final CollectorQuery? parsed = CollectorQuery.parse(query);
    if (parsed == null) return null;

    String? code;
    for (final String candidate in parsed.codeCandidates) {
      code = await _setCodeMatching(game, candidate);
      if (code != null) break;
    }
    if (code == null && !parsed.standalone) return null;

    final where = <String>['game = ?'];
    final args = <Object?>[game.id];
    if (code != null) {
      where.add('${Codes.foldedSql('set_code')} = ?');
      args.add(Codes.fold(code));
    }
    // Padded or not: Digimon prints "001" where Magic prints "1", and a
    // collector asking for #1 means the same card in both. Separators are
    // already gone, so the fold here is only about the leading zeroes.
    where.add(
      "(collector_number = ? COLLATE NOCASE "
      "OR ltrim(collector_number, '0') = ltrim(?, '0') COLLATE NOCASE)",
    );
    args
      ..add(parsed.number)
      ..add(parsed.number);

    final rows = await _db.rawQuery(
      'SELECT * FROM cards WHERE ${where.join(' AND ')} '
      'ORDER BY (collector_number = ? COLLATE NOCASE) DESC, '
      '  released_at DESC NULLS LAST, set_code, collector_sort, '
      '  collector_number '
      'LIMIT ?',
      <Object?>[...args, parsed.number, limit],
    );
    return rows.map((r) => CatalogRow.cardFromRow(game, r)).toList();
  }

  /// The stored code of the set whose folded code is [foldedCode], or null.
  ///
  /// The fold is the same one set search uses, so a query naming "BT-26" finds
  /// the set stored as "BT26" (see [Codes]).
  Future<String?> _setCodeMatching(CardGame game, String foldedCode) async {
    final rows = await _db.rawQuery(
      'SELECT code FROM sets WHERE game = ? AND ${Codes.foldedSql('code')} = ? '
      'LIMIT 1',
      <Object?>[game.id, foldedCode],
    );
    return rows.isEmpty ? null : rows.first['code'] as String;
  }

  /// How many printings of a game are cached.
  Future<int> cardCount(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM cards WHERE game = ?',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Updates only the market prices for a batch of printings.
  Future<void> updatePrices(CardGame game, List<TcgCard> cards) async {
    if (cards.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final c in cards) {
      batch.update(
        'cards',
        {
          'prices_json': jsonEncode(c.prices.toJson()),
          'prices_updated_at': now,
        },
        where: 'game = ? AND id = ?',
        whereArgs: [game.id, c.id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// When prices were last refreshed for a printing.
  Future<DateTime?> pricesUpdatedAt(CardGame game, String cardId) async {
    final rows = await _db.query(
      'cards',
      columns: ['prices_updated_at'],
      where: 'game = ? AND id = ?',
      whereArgs: [game.id, cardId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final t = (rows.first['prices_updated_at'] as num?)?.toInt();
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }

  /// When any price for a game was last refreshed.
  ///
  /// A valuation is only as fresh as the prices behind it, and a report that
  /// wants to print a date has to ask for the newest one it has rather than
  /// assume today.
  Future<DateTime?> latestPricesAt(CardGame game) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(prices_updated_at) AS t FROM cards WHERE game = ?',
      [game.id],
    );
    if (rows.isEmpty) return null;
    final t = (rows.first['t'] as num?)?.toInt();
    return t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
  }

  /// Removes every cached row for a game, used to reclaim space.
  Future<void> clearGame(CardGame game) async {
    final batch = _db.batch();
    batch.delete('cards', where: 'game = ?', whereArgs: [game.id]);
    batch.delete('sets', where: 'game = ?', whereArgs: [game.id]);
    await batch.commit(noResult: true);
  }
}
