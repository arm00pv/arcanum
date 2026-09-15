import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/codes.dart';
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
    return rows.map((r) => _setFromRow(game, r)).toList();
  }

  /// A single set by code.
  Future<TcgSet?> set(CardGame game, String code) async {
    final rows = await _db.query(
      'sets',
      where: 'game = ? AND code = ?',
      whereArgs: [game.id, code],
      limit: 1,
    );
    return rows.isEmpty ? null : _setFromRow(game, rows.first);
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
               WHERE e.game = s.game AND c.set_code = s.code) AS owned
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
      final row = _cardToRow(game, c, now);
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
    return rows.map((r) => _cardFromRow(game, r)).toList();
  }

  /// A single printing by provider id.
  Future<TcgCard?> cardById(CardGame game, String id) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND id = ?',
      whereArgs: [game.id, id],
      limit: 1,
    );
    return rows.isEmpty ? null : _cardFromRow(game, rows.first);
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
    return rows.isEmpty ? null : _cardFromRow(game, rows.first);
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
    return rows.map((Map<String, Object?> r) => _cardFromRow(game, r)).toList();
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
        final c = _cardFromRow(game, r);
        out[c.id] = c;
      }
    }
    return out;
  }

  /// Every printing sharing a group id (all reprints of a card).
  Future<List<TcgCard>> printingsOf(CardGame game, String groupId) async {
    final rows = await _db.query(
      'cards',
      where: 'game = ? AND oracle_id = ?',
      whereArgs: [game.id, groupId],
      orderBy: 'released_at ASC NULLS LAST',
    );
    return rows.map((r) => _cardFromRow(game, r)).toList();
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
    return rows.map((r) => _cardFromRow(game, r)).toList();
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

  // --------------------------------------------------------------- mapping

  static Map<String, Object?> _cardToRow(CardGame game, TcgCard c, int now) => {
    'id': c.id,
    'game': game.id,
    'oracle_id': c.oracleId,
    'set_code': c.setCode,
    'set_name': c.setName,
    'name': c.name,
    'collector_number': c.collectorNumber,
    'collector_sort': c.collectorNumberSortKey,
    'rarity': c.rarity,
    'layout': c.layout,
    'type_line': c.typeLine,
    'oracle_text': c.oracleText,
    'mana_cost': c.manaCost,
    'cmc': c.cmc,
    'colors': c.colors.join(','),
    'color_identity': c.colorIdentity.join(','),
    'artist': c.artist,
    'flavor_text': c.flavorText,
    'image_small': c.imageUris['small'],
    'image_normal': c.imageUris['normal'],
    'image_large': c.imageUris['large'],
    'image_art_crop': c.imageUris['art_crop'],
    'image_png': c.imageUris['png'],
    'back_image_small': c.faces.length > 1
        ? c.faces[1].imageUris['small']
        : null,
    'back_image_normal': c.faces.length > 1
        ? c.faces[1].imageUris['normal']
        : null,
    'prices_json': jsonEncode(c.prices.toJson()),
    'prices_updated_at': now,
    'digital': c.digital ? 1 : 0,
    'promo': c.promo ? 1 : 0,
    'reprint': c.reprint ? 1 : 0,
    'reserved': c.reserved ? 1 : 0,
    'full_art': c.fullArt ? 1 : 0,
    'booster': c.booster ? 1 : 0,
    'foil': c.foil ? 1 : 0,
    'nonfoil': c.nonfoil ? 1 : 0,
    'edhrec_rank': c.edhrecRank,
    'released_at': c.releasedAt?.toIso8601String().split('T').first,
    'extras_json': c.extras.isEmpty
        ? null
        : jsonEncode(c.extras.map((k, v) => MapEntry(k, v))),
  };

  static TcgCard _cardFromRow(CardGame game, Map<String, Object?> r) => TcgCard(
    game: game,
    id: r['id'] as String,
    oracleId: r['oracle_id'] as String?,
    setCode: r['set_code'] as String,
    setName: (r['set_name'] as String?) ?? '',
    name: r['name'] as String,
    collectorNumber: (r['collector_number'] as String?) ?? '',
    rarity: (r['rarity'] as String?) ?? 'unknown',
    layout: (r['layout'] as String?) ?? '',
    typeLine: r['type_line'] as String?,
    oracleText: r['oracle_text'] as String?,
    manaCost: r['mana_cost'] as String?,
    artist: r['artist'] as String?,
    flavorText: r['flavor_text'] as String?,
    cmc: (r['cmc'] as num?)?.toDouble(),
    colors: _split(r['colors']),
    colorIdentity: _split(r['color_identity']),
    digital: (r['digital'] as int? ?? 0) == 1,
    foil: (r['foil'] as int? ?? 0) == 1,
    nonfoil: (r['nonfoil'] as int? ?? 0) == 1,
    promo: (r['promo'] as int? ?? 0) == 1,
    reprint: (r['reprint'] as int? ?? 0) == 1,
    reserved: (r['reserved'] as int? ?? 0) == 1,
    fullArt: (r['full_art'] as int? ?? 0) == 1,
    booster: (r['booster'] as int? ?? 0) == 1,
    edhrecRank: (r['edhrec_rank'] as num?)?.toInt(),
    releasedAt: _parseDate(r['released_at'] as String?),
    prices: _pricesFrom(r['prices_json']),
    imageUris: _imagesFromRow(r),
    faces: _facesFromRow(r),
    extras: _extrasFrom(r['extras_json']),
  );

  static TcgPrices _pricesFrom(Object? raw) {
    if (raw is! String || raw.isEmpty) return TcgPrices.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return TcgPrices.empty;
      return TcgPrices.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return TcgPrices.empty;
    }
  }

  static Map<String, Object?> _extrasFrom(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _imagesFromRow(Map<String, Object?> r) {
    final out = <String, String>{};
    void put(String key, Object? v) {
      if (v is String && v.isNotEmpty) out[key] = v;
    }

    put('small', r['image_small']);
    put('normal', r['image_normal']);
    put('large', r['image_large']);
    put('art_crop', r['image_art_crop']);
    put('png', r['image_png']);
    return out;
  }

  static List<TcgCardFace> _facesFromRow(Map<String, Object?> r) {
    final back = <String, String>{};
    final bs = r['back_image_small'];
    final bn = r['back_image_normal'];
    if (bs is String && bs.isNotEmpty) back['small'] = bs;
    if (bn is String && bn.isNotEmpty) back['normal'] = bn;
    if (back.isEmpty) return const [];
    // The front face is reconstructed from the top-level images so that
    // imageUrl(face: 0) and imageUrl(face: 1) behave identically.
    return [
      TcgCardFace(
        name: r['name'] as String?,
        typeLine: r['type_line'] as String?,
        text: r['oracle_text'] as String?,
        cost: r['mana_cost'] as String?,
        imageUris: _imagesFromRow(r),
      ),
      TcgCardFace(imageUris: back),
    ];
  }

  static List<String> _split(Object? v) {
    final s = (v as String?) ?? '';
    if (s.isEmpty) return const [];
    return s.split(',').where((e) => e.isNotEmpty).toList();
  }

  static DateTime? _parseDate(String? s) =>
      s == null ? null : DateTime.tryParse(s);

  static TcgSet _setFromRow(CardGame game, Map<String, Object?> r) => TcgSet(
    game: game,
    id: r['id'] as String,
    code: r['code'] as String,
    name: r['name'] as String,
    setType: (r['set_type'] as String?) ?? 'unknown',
    releasedAt: _parseDate(r['released_at'] as String?),
    cardCount: (r['card_count'] as num?)?.toInt() ?? 0,
    printedSize: (r['printed_size'] as num?)?.toInt(),
    iconSvgUri: r['icon_svg_uri'] as String?,
    logoUri: r['logo_uri'] as String?,
    series: r['series'] as String?,
    digital: (r['digital'] as int? ?? 0) == 1,
    foilOnly: (r['foil_only'] as int? ?? 0) == 1,
    nonfoilOnly: (r['nonfoil_only'] as int? ?? 0) == 1,
    parentSetCode: r['parent_set_code'] as String?,
    blockCode: r['block_code'] as String?,
    block: r['block'] as String?,
    collectorNumberStart: (r['collector_number_start'] as num?)?.toInt(),
  );
}
