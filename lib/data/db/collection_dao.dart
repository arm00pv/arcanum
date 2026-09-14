import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/lots_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/portfolio/lots.dart';

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
        // The stack keeps the blended average, which is the number the
        // valuation and the purchases screen want. The purchase itself is kept
        // as a lot of its own, because what a *part* of the stack cost is a
        // different question and the average cannot answer it.
        await LotsDao.insertLot(
          txn,
          CardLot(
            game: game,
            cardId: cardId,
            entryId: id,
            quantity: quantity,
            unitCost: purchasePrice,
            acquiredOn: purchaseDate ?? now,
            note: notes ?? '',
          ),
        );
        return id;
      }
      final id = await txn.insert('collection_entries', {
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
      await LotsDao.insertLot(
        txn,
        CardLot(
          game: game,
          cardId: cardId,
          entryId: id,
          quantity: quantity,
          unitCost: purchasePrice,
          acquiredOn: purchaseDate ?? now,
          note: notes ?? '',
        ),
      );
      return id;
    });
  }

  static DateTime? _dateFrom(Object? v) =>
      v is int ? DateTime.fromMillisecondsSinceEpoch(v) : null;

  /// Sets an entry's quantity, deleting the row when it reaches zero.
  /// Sets an entry's quantity, deleting the row when it reaches zero.
  ///
  /// The lots follow: copies added by hand become a lot of their own at the
  /// stack's own price, and copies taken off the shelf are disposed of oldest
  /// first without realising anything. Nothing here is a sale - the app has not
  /// been told what became of the cards - so the tax sheet counts only what was
  /// sold, and the screen says how many copies left without one.
  Future<void> setQuantity(int id, int quantity) async {
    if (quantity <= 0) {
      await delete(id);
      return;
    }
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'collection_entries',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final game = CardGame.fromId(row['game'] as String?);
      final before = (row['quantity'] as num?)?.toInt() ?? 0;
      final added = quantity - before;

      await txn.update(
        'collection_entries',
        {
          'quantity': quantity,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      if (added > 0) {
        await LotsDao.insertLot(
          txn,
          CardLot(
            game: game,
            cardId: row['card_id'] as String? ?? '',
            entryId: id,
            quantity: added,
            unitCost: (row['purchase_price'] as num?)?.toDouble(),
            acquiredOn: _dateFrom(row['purchase_date']) ?? DateTime.now(),
          ),
        );
      } else if (added < 0) {
        await LotsDao.dispose(txn, game: game, entryId: id, quantity: -added);
      }
    });
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

  /// Removes a stack, and its lots with it.
  ///
  /// A deleted stack is a disposal the app knows nothing about: the copies are
  /// off the shelf and the purchases behind them go with them, so the cost
  /// basis does not sit there waiting to be matched against a sale that was
  /// never recorded. Whatever was sold is recorded as a sale, and that is what
  /// survives.
  Future<void> delete(int id) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'collection_entries',
        columns: ['game'],
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      final game = rows.isEmpty
          ? null
          : CardGame.fromId(rows.first['game'] as String?);
      if (game != null) {
        await txn.delete(
          'card_lots',
          where: 'entry_id = ?',
          whereArgs: <Object?>[id],
        );
      }
      await txn.delete('collection_entries', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> deleteAllForCard(CardGame game, String cardId) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'card_lots',
        where: 'game = ? AND card_id = ?',
        whereArgs: <Object?>[game.id, cardId],
      );
      await txn.delete(
        'collection_entries',
        where: 'game = ? AND card_id = ?',
        whereArgs: [game.id, cardId],
      );
    });
  }

  /// Clears one game's collection, or every game when [game] is null.
  Future<void> clear({CardGame? game}) async {
    await _db.transaction((txn) async {
      if (game == null) {
        await txn.delete('card_lots');
        await txn.delete('collection_entries');
      } else {
        await txn.delete(
          'card_lots',
          where: 'game = ?',
          whereArgs: <Object?>[game.id],
        );
        await txn.delete(
          'collection_entries',
          where: 'game = ?',
          whereArgs: [game.id],
        );
      }
    });
  }
}
