import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';

/// Reads and writes the user's collection.
///
/// The DAO deliberately knows nothing about cards or prices: it stores the
/// physical facts of ownership. Valuation is layered on top by the repository.
///
/// Every method is scoped to one game. A Pokémon entry and a Magic entry can
/// share a printing id in theory and still never collide, because the game is
/// part of the unique key.
class CollectionDao {
  CollectionDao(this._db);

  final Database _db;

  /// All entries for a game, newest first.
  Future<List<CollectionEntry>> all(CardGame game) async {
    final rows = await _db.query(
      'collection_entries',
      where: 'game = ?',
      whereArgs: [game.id],
      orderBy: 'updated_at DESC',
    );
    return rows.map(CollectionEntry.fromRow).toList();
  }

  /// Entries for a single printing.
  Future<List<CollectionEntry>> forCard(CardGame game, String cardId) async {
    final rows = await _db.query(
      'collection_entries',
      where: 'game = ? AND card_id = ?',
      whereArgs: [game.id, cardId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(CollectionEntry.fromRow).toList();
  }

  /// Entries for many printings at once, keyed by card id.
  Future<Map<String, List<CollectionEntry>>> forCards(
    CardGame game,
    List<String> cardIds,
  ) async {
    if (cardIds.isEmpty) return const {};
    final out = <String, List<CollectionEntry>>{};
    // Chunked to stay well under SQLite's variable limit.
    for (var i = 0; i < cardIds.length; i += 400) {
      final chunk = cardIds.sublist(
        i,
        i + 400 > cardIds.length ? cardIds.length : i + 400,
      );
      final marks = List.filled(chunk.length, '?').join(',');
      final rows = await _db.rawQuery(
        'SELECT * FROM collection_entries WHERE game = ? AND card_id IN ($marks)',
        [game.id, ...chunk],
      );
      for (final r in rows) {
        final e = CollectionEntry.fromRow(r);
        out.putIfAbsent(e.cardId, () => []).add(e);
      }
    }
    return out;
  }

  /// Distinct card ids currently owned.
  Future<List<String>> ownedCardIds(CardGame game) async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT card_id FROM collection_entries WHERE game = ?',
      [game.id],
    );
    return rows.map((r) => r['card_id'] as String).toList();
  }

  /// Distinct binder names, excluding the default empty binder.
  Future<List<String>> binders(CardGame game) async {
    final rows = await _db.rawQuery(
      "SELECT DISTINCT binder FROM collection_entries "
      "WHERE game = ? AND binder <> '' ORDER BY binder",
      [game.id],
    );
    return rows.map((r) => r['binder'] as String).toList();
  }

  /// Total number of physical cards owned in a game.
  Future<int> totalCardCount(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) AS n FROM collection_entries WHERE game = ?',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Number of distinct printings owned in a game.
  Future<int> uniqueCount(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(DISTINCT card_id) AS n FROM collection_entries WHERE game = ?',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Adds [quantity] copies of a physical stack, merging into an existing
  /// matching entry when one exists.
  ///
  /// Returns the id of the affected row.
  Future<int> addOrMerge({
    required CardGame game,
    required String cardId,
    required CardFinish finish,
    required CardCondition condition,
    required String language,
    required int quantity,
    double? purchasePrice,
    DateTime? purchaseDate,
    String binder = '',
    String? notes,
  }) async {
    final now = DateTime.now();
    return _db.transaction((txn) async {
      final existing = await txn.query(
        'collection_entries',
        where:
            'game = ? AND card_id = ? AND finish = ? AND condition = ? '
            'AND language = ? AND binder = ?',
        whereArgs: [
          game.id,
          cardId,
          finish.code,
          condition.code,
          language,
          binder,
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final row = existing.first;
        final id = row['id'] as int;
        final newQty = ((row['quantity'] as int?) ?? 0) + quantity;
        // Blend the cost basis when a new purchase price is supplied.
        double? blended = (row['purchase_price'] as num?)?.toDouble();
        if (purchasePrice != null) {
          final oldQty = (row['quantity'] as int?) ?? 0;
          blended = oldQty <= 0
              ? purchasePrice
              : ((blended ?? purchasePrice) * oldQty +
                        purchasePrice * quantity) /
                    newQty;
        }
        await txn.update(
          'collection_entries',
          {
            'quantity': newQty,
            'purchase_price': blended,
            'purchase_date': (purchaseDate ?? _dateFrom(row['purchase_date']))
                ?.millisecondsSinceEpoch,
            if (notes != null && notes.isNotEmpty) 'notes': notes,
            'updated_at': now.millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        return id;
      }
      return txn.insert('collection_entries', {
        'game': game.id,
        'card_id': cardId,
        'finish': finish.code,
        'condition': condition.code,
        'language': language,
        'quantity': quantity,
        'purchase_price': purchasePrice,
        'purchase_date': purchaseDate?.millisecondsSinceEpoch,
        'binder': binder,
        'notes': notes,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
    });
  }

  static DateTime? _dateFrom(Object? v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

  /// Sets an entry's quantity, deleting the row when it reaches zero.
  Future<void> setQuantity(int id, int quantity) async {
    if (quantity <= 0) {
      await delete(id);
      return;
    }
    await _db.update(
      'collection_entries',
      {
        'quantity': quantity,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Removes [quantity] copies, deleting the row if it hits zero.
  Future<void> decrement(int id, [int quantity = 1]) async {
    final rows = await _db.query(
      'collection_entries',
      columns: ['quantity'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final current = (rows.first['quantity'] as int?) ?? 0;
    await setQuantity(id, current - quantity);
  }

  Future<void> updateEntry(CollectionEntry entry) async {
    if (entry.id == null) return;
    final row = entry.copyWith(updatedAt: DateTime.now()).toRow()..remove('id');
    await _db.update(
      'collection_entries',
      row,
      where: 'id = ?',
      whereArgs: [entry.id],
    );
  }

  /// Marks a stack as up for trade, or takes it off the trade pile.
  Future<void> setForTrade(int id, bool forTrade) async {
    await _db.update(
      'collection_entries',
      {
        'for_trade': forTrade ? 1 : 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(int id) async {
    await _db.delete('collection_entries', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteAllForCard(CardGame game, String cardId) async {
    await _db.delete(
      'collection_entries',
      where: 'game = ? AND card_id = ?',
      whereArgs: [game.id, cardId],
    );
  }

  /// Clears one game's collection, or every game when [game] is null.
  Future<void> clear({CardGame? game}) async {
    if (game == null) {
      await _db.delete('collection_entries');
    } else {
      await _db.delete(
        'collection_entries',
        where: 'game = ?',
        whereArgs: [game.id],
      );
    }
  }
}
