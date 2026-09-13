import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// Persists the daily price observations the app accumulates over time.
///
/// Rows are keyed by (card, finish, date, source) so several providers can
/// coexist for the same day without clobbering each other. When a series is
/// read back, sources are resolved by [sourcePriority] so a real market series
/// always wins over a locally recorded snapshot.
///
/// History is partitioned by game: a Magic card and a Pokémon card never share a
/// series, and the portfolio curves are tracked separately.
class HistoryDao {
  HistoryDao(this._db);

  final Database _db;

  /// Lower index wins when two sources disagree about the same day.
  ///
  /// `backfill` leads because it carries TCGplayer market prices — the same
  /// series Scryfall's `usd` field reports — so the chart lines up exactly with
  /// the price shown on screen. `mtgstocks` then extends the curve backwards
  /// beyond the 90-day window that backfill covers, and `snapshot` fills in
  /// anything the app recorded itself.
  static const sourcePriority = <String>[
    'backfill',
    'companion',
    // Written by the first release that had samplers; kept so those rows keep
    // the priority they were stored with.
    'pokemon_backfill',
    'mtgstocks',
    'snapshot',
    'manual',
  ];

  static int _priority(String source) {
    final i = sourcePriority.indexOf(source);
    return i < 0 ? sourcePriority.length : i;
  }

  /// Inserts or replaces a single observation.
  Future<void> record({
    required CardGame game,
    required String cardId,
    required CardFinish finish,
    required DateTime date,
    required double price,
    String source = 'snapshot',
  }) async {
    if (price.isNaN || price.isInfinite || price < 0) return;
    await _db.insert(
      'price_history',
      {
        'card_id': cardId,
        'game': game.id,
        'finish': finish.code,
        'date': _key(date),
        'price': price,
        'source': source,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Bulk insert, used when importing a backfill pack.
  Future<void> recordMany({
    required CardGame game,
    required String cardId,
    required CardFinish finish,
    required List<PricePoint> points,
    String source = 'backfill',
  }) async {
    if (points.isEmpty) return;
    final batch = _db.batch();
    for (final p in points) {
      if (p.price.isNaN || p.price.isInfinite || p.price < 0) continue;
      batch.insert(
        'price_history',
        {
          'card_id': cardId,
          'game': game.id,
          'finish': finish.code,
          'date': _key(p.date),
          'price': p.price,
          'source': source,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// The merged, de-duplicated, chronologically sorted series for a printing.
  ///
  /// Selects the most recent [days] *observations* rather than everything inside
  /// a window measured back from today. That distinction matters: Pokémon
  /// history comes from a free community archive that stopped updating in
  /// September 2024, and a today-relative cutoff would silently discard the
  /// entire series. For live data the two are equivalent, because the series is
  /// daily.
  Future<List<PricePoint>> series(
    CardGame game,
    String cardId, {
    CardFinish finish = CardFinish.nonfoil,
    int days = 400,
  }) async {
    final rows = await _db.query(
      'price_history',
      columns: ['date', 'price', 'source'],
      where: 'card_id = ? AND game = ? AND finish = ?',
      whereArgs: [cardId, game.id, finish.code],
      orderBy: 'date DESC',
      limit: days,
    );
    return _merge(rows);
  }

  /// Merged series for many printings, keyed by card id.
  Future<Map<String, List<PricePoint>>> seriesForCards(
    CardGame game,
    List<String> cardIds, {
    CardFinish finish = CardFinish.nonfoil,
    int days = 400,
  }) async {
    if (cardIds.isEmpty) return const {};
    final out = <String, List<PricePoint>>{};
    for (var i = 0; i < cardIds.length; i += 400) {
      final chunk = cardIds.sublist(i, i + 400 > cardIds.length ? cardIds.length : i + 400);
      final marks = List.filled(chunk.length, '?').join(',');
      // Newest first, then trimmed per card below, so stale archives survive.
      final rows = await _db.rawQuery(
        'SELECT card_id, date, price, source FROM price_history '
        'WHERE game = ? AND finish = ? AND card_id IN ($marks) '
        'ORDER BY date DESC',
        [game.id, finish.code, ...chunk],
      );
      final grouped = <String, List<Map<String, Object?>>>{};
      for (final r in rows) {
        final id = r['card_id'] as String;
        final list = grouped.putIfAbsent(id, () => []);
        if (list.length < days) list.add(r);
      }
      grouped.forEach((id, rs) => out[id] = _merge(rs));
    }
    return out;
  }

  /// Collapses rows onto one value per calendar day, best source first.
  static List<PricePoint> _merge(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return const [];
    final byDate = <String, ({double price, int rank})>{};
    for (final r in rows) {
      final d = r['date'] as String;
      final price = (r['price'] as num).toDouble();
      final rank = _priority((r['source'] as String?) ?? 'snapshot');
      final prev = byDate[d];
      if (prev == null || rank < prev.rank) byDate[d] = (price: price, rank: rank);
    }
    final dates = byDate.keys.toList()..sort();
    return [
      for (final d in dates) PricePoint(_parseKey(d), byDate[d]!.price),
    ];
  }

  /// How many observations exist for a printing.
  Future<int> observationCount(
    CardGame game,
    String cardId, {
    CardFinish finish = CardFinish.nonfoil,
  }) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM price_history WHERE card_id = ? AND game = ? AND finish = ?',
      [cardId, game.id, finish.code],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Card ids that already have history, used to skip redundant backfills.
  Future<Set<String>> idsWithHistory(CardGame game, {int minPoints = 30}) async {
    final rows = await _db.rawQuery(
      'SELECT card_id FROM price_history WHERE game = ? '
      'GROUP BY card_id HAVING COUNT(*) >= ?',
      [game.id, minPoints],
    );
    return rows.map((r) => r['card_id'] as String).toSet();
  }

  /// Deletes observations older than [days] to keep the database small.
  Future<int> prune({CardGame? game, int days = 900}) async {
    final cutoff = _key(DateTime.now().subtract(Duration(days: days)));
    if (game == null) {
      return _db.delete('price_history', where: 'date < ?', whereArgs: [cutoff]);
    }
    return _db.delete('price_history',
        where: 'game = ? AND date < ?', whereArgs: [game.id, cutoff]);
  }

  /// How many observations a game has accumulated in total.
  Future<int> totalObservations(CardGame game) async {
    final r = await _db.rawQuery(
        'SELECT COUNT(*) AS n FROM price_history WHERE game = ?', [game.id]);
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------ portfolio series

  /// Records today's total portfolio value for a game, overwriting today's row.
  Future<void> recordPortfolioSnapshot({
    required CardGame game,
    required double totalValue,
    required int uniqueCards,
    required int totalCards,
  }) async {
    await _db.insert(
      'portfolio_snapshots',
      {
        'game': game.id,
        'date': _key(DateTime.now()),
        'total_value': totalValue,
        'unique_cards': uniqueCards,
        'total_cards': totalCards,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// The portfolio value series for a game, oldest first.
  Future<List<PricePoint>> portfolioSeries(CardGame game, {int days = 400}) async {
    final cutoff = _key(DateTime.now().subtract(Duration(days: days)));
    final rows = await _db.query(
      'portfolio_snapshots',
      columns: ['date', 'total_value'],
      where: 'game = ? AND date >= ?',
      whereArgs: [game.id, cutoff],
      orderBy: 'date ASC',
    );
    return [
      for (final r in rows)
        PricePoint(_parseKey(r['date'] as String), (r['total_value'] as num).toDouble()),
    ];
  }

  // ------------------------------------------------------------ key/value

  /// Reads a small value from the `meta` table.
  Future<String?> metaValue(String key) async {
    final rows = await _db
        .query('meta', columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// Writes a small value into the `meta` table.
  Future<void> setMetaValue(String key, String value) async {
    await _db.insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --------------------------------------------------------------- helpers

  /// `YYYY-MM-DD` in local time — the granularity the whole app reasons in.
  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime _parseKey(String s) {
    final parts = s.split('-');
    if (parts.length != 3) return DateTime.now();
    return DateTime(
      int.tryParse(parts[0]) ?? 1970,
      int.tryParse(parts[1]) ?? 1,
      int.tryParse(parts[2]) ?? 2,
    );
  }
}
