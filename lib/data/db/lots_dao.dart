import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/domain/portfolio/realised.dart';

/// Stores what each purchase cost and what each sale realised against it.
///
/// The collection table keeps one averaged price per stack, which is what the
/// valuation and the "what did this cost" screens want. It cannot answer what a
/// *part* of a stack cost, and that is the question a sale asks. So the
/// purchases are kept here as well, one row each, and a sale is matched against
/// them oldest first.
class LotsDao {
  /// Creates the DAO over an open database.
  LotsDao(this._db);

  final Database _db;

  /// The lots of one printing, oldest first.
  Future<List<CardLot>> forCard(CardGame game, String cardId) async {
    final rows = await _db.query(
      'card_lots',
      where: 'game = ? AND card_id = ? AND quantity > 0',
      whereArgs: <Object?>[game.id, cardId],
      orderBy: 'acquired_on IS NULL, acquired_on ASC, id ASC',
    );
    return <CardLot>[for (final row in rows) CardLot.fromRow(row, game: game)];
  }

  /// The lots of one stack.
  Future<List<CardLot>> forEntry(CardGame game, int entryId) async {
    final rows = await _db.query(
      'card_lots',
      where: 'game = ? AND entry_id = ? AND quantity > 0',
      whereArgs: <Object?>[game.id, entryId],
      orderBy: 'acquired_on IS NULL, acquired_on ASC, id ASC',
    );
    return <CardLot>[for (final row in rows) CardLot.fromRow(row, game: game)];
  }

  /// Every sale for a game, newest first.
  Future<List<CardSale>> sales(CardGame game) async {
    final rows = await _db.query(
      'card_sales',
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
      orderBy: 'sold_on DESC, id DESC',
    );
    return <CardSale>[
      for (final row in rows) CardSale.fromRow(row, game: game),
    ];
  }

  /// The sales of one printing, newest first.
  Future<List<CardSale>> salesForCard(CardGame game, String cardId) async {
    final rows = await _db.query(
      'card_sales',
      where: 'game = ? AND card_id = ?',
      whereArgs: <Object?>[game.id, cardId],
      orderBy: 'sold_on DESC, id DESC',
    );
    return <CardSale>[
      for (final row in rows) CardSale.fromRow(row, game: game),
    ];
  }

  /// Records a sale out of one stack, and returns it.
  ///
  /// Everything happens in one transaction, because a sale that took the copies
  /// out of the collection without taking them out of the lots - or the other
  /// way round - would leave a cost basis that disagrees with the shelf.
  ///
  /// Throws [ArgumentError] when the stack is gone or when more copies are sold
  /// than the stack holds; the sheet that calls this validates first, and a
  /// database that says no is the last line of defence rather than the first.
  Future<CardSale> recordSale({
    required CardGame game,
    required CollectionEntry entry,
    required int quantity,
    required double unitPrice,
    required DateTime soldOn,
    double fees = 0,
    String platform = '',
    String note = '',
  }) async {
    final entryId = entry.id;
    if (entryId == null) {
      throw ArgumentError('A sale needs a stack that has been stored.');
    }
    return _db.transaction((Transaction txn) async {
      final held = await _held(txn, entryId);
      if (held == null) {
        throw ArgumentError('That stack is no longer in the collection.');
      }
      if (quantity <= 0) {
        throw ArgumentError('A sale needs at least one copy.');
      }
      if (quantity > held) {
        throw ArgumentError('The stack holds $held copies.');
      }

      final lots = await _lotsForEntry(txn, game, entryId);
      final owned = lots.fold<int>(0, (int a, CardLot lot) => a + lot.quantity);
      final rows = await txn.query(
        'collection_entries',
        where: 'id = ?',
        whereArgs: <Object?>[entryId],
        limit: 1,
      );
      if (owned < held && rows.isNotEmpty) {
        // A stack with no lot behind it - a row written before this version
        // existed, or one left half-written by a crash - gets one at its own
        // price before anything is matched, so a sale is never matched against
        // nothing it can see.
        lots.add(
          CardLot(
            game: game,
            cardId: entry.cardId,
            entryId: entryId,
            quantity: held - owned,
            unitCost: (rows.first['purchase_price'] as num?)?.toDouble(),
            acquiredOn: switch ((rows.first['purchase_date'] as num?)
                ?.toInt()) {
              final int at => DateTime.fromMillisecondsSinceEpoch(at),
              null => null,
            },
          ),
        );
      }

      final match = matchFifo(lots, quantity);
      await _saveLots(txn, match.remaining);

      final sale = CardSale(
        game: game,
        cardId: entry.cardId,
        quantity: quantity,
        unitPrice: unitPrice,
        fees: fees,
        soldOn: soldOn,
        finish: entry.finish,
        condition: entry.condition,
        platform: platform,
        note: note,
        matches: match.matches,
        entryId: entryId,
        language: entry.language,
        binder: entry.binder,
        createdAt: DateTime.now(),
      );

      final id = await txn.insert('card_sales', <String, Object?>{
        ...sale.toRow(),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      final left = held - quantity;
      if (left <= 0) {
        // Selling the last copy takes the stack off the shelf, and a stack
        // leaving the shelf is marked rather than dropped everywhere in this
        // app: a row deleted here is a row the account still holds, and the
        // next sync would put the card they just sold back in the collection.
        final int at = DateTime.now().millisecondsSinceEpoch;
        await txn.update(
          'collection_entries',
          <String, Object?>{'deleted_at': at, 'updated_at': at},
          where: 'id = ?',
          whereArgs: <Object?>[entryId],
        );
      } else {
        await txn.update(
          'collection_entries',
          <String, Object?>{
            'quantity': left,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: <Object?>[entryId],
        );
      }

      return sale.copyWith(id: id);
    });
  }

  /// Undoes a sale: the copies go back where they were, and the record goes.
  ///
  /// The lots come back exactly as they were - the sale kept each lot's own
  /// quantity, price and purchase date - so undoing a sale leaves the cost
  /// basis as it was before it, not as a fresh purchase.
  Future<void> undoSale(CardSale sale) async {
    final id = sale.id;
    if (id == null) return;
    await _db.transaction((Transaction txn) async {
      var entryId = sale.entryId;
      final rows = entryId == null
          ? const <Map<String, Object?>>[]
          : await txn.query(
              'collection_entries',
              where: 'id = ?',
              whereArgs: <Object?>[entryId],
              limit: 1,
            );
      final Map<String, Object?>? row = rows.isEmpty ? null : rows.first;
      if (row == null || row['deleted_at'] != null) {
        // The stack is not on the shelf - sold down to nothing, or removed
        // since - so undoing the sale brings it back with the printing,
        // finish, condition, language and binder the sale recorded. When its
        // row is still there it comes back on that row: inserting a fresh one
        // would collide with the unique index, and writing the copies onto a
        // marked row without clearing the mark would leave them invisible.
        final int at = DateTime.now().millisecondsSinceEpoch;
        final Map<String, Object?> back = <String, Object?>{
          'game': sale.game.id,
          'card_id': sale.cardId,
          'finish': sale.finish.code,
          'condition': sale.condition.code,
          'language': sale.language,
          'quantity': sale.quantity,
          'purchase_price': _averageCost(sale),
          'purchase_date': sale.matches.isEmpty
              ? null
              : sale.matches.first.acquiredOn?.millisecondsSinceEpoch,
          'binder': sale.binder,
          'notes': null,
          'for_trade': 0,
          'deleted_at': null,
          'updated_at': at,
        };
        entryId = row == null
            ? await txn.insert('collection_entries', <String, Object?>{
                ...back,
                'created_at': at,
              })
            : (row['id'] as num).toInt();
        if (row != null) {
          await txn.update(
            'collection_entries',
            back,
            where: 'id = ?',
            whereArgs: <Object?>[entryId],
          );
        }
      } else {
        entryId = (rows.first['id'] as num).toInt();
        await txn.update(
          'collection_entries',
          <String, Object?>{
            'quantity':
                ((rows.first['quantity'] as num?)?.toInt() ?? 0) +
                sale.quantity,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: <Object?>[entryId],
        );
      }

      for (final match in sale.matches) {
        await txn.insert('card_lots', <String, Object?>{
          'game': sale.game.id,
          'card_id': sale.cardId,
          'entry_id': entryId,
          'quantity': match.quantity,
          'unit_cost': match.unitCost,
          'acquired_on': match.acquiredOn?.millisecondsSinceEpoch,
          'note': '',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }

      await txn.delete('card_sales', where: 'id = ?', whereArgs: <Object?>[id]);
    });
  }

  // ------------------------------------------------------- used by other DAOs

  /// Writes a lot, inside a transaction the caller owns.
  ///
  /// The collection DAO calls this while it is adding copies, so the stack and
  /// the purchase behind it are written together or not at all.
  static Future<void> insertLot(DatabaseExecutor txn, CardLot lot) async {
    await txn.insert('card_lots', <String, Object?>{
      ...lot.toRow(),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Takes copies out of a stack's lots without recording a sale.
  ///
  /// This is what happens when a stack is edited down or deleted: the copies
  /// are gone from the collection and the app was not told what became of them,
  /// so nothing is realised. The tax sheet counts what was *sold*, and the
  /// screen says how many copies left without one.
  static Future<void> dispose(
    DatabaseExecutor txn, {
    required CardGame game,
    required int entryId,
    required int quantity,
  }) async {
    if (quantity <= 0) return;
    final rows = await txn.query(
      'card_lots',
      where: 'game = ? AND entry_id = ? AND quantity > 0',
      whereArgs: <Object?>[game.id, entryId],
      orderBy: 'acquired_on IS NULL, acquired_on ASC, id ASC',
    );
    final lots = <CardLot>[
      for (final row in rows) CardLot.fromRow(row, game: game),
    ];
    final match = matchFifo(lots, quantity);
    await _saveLots(txn, match.remaining);
  }

  // ------------------------------------------------------------------ private

  /// The quantity of a stack, or null when it is not on the shelf.
  ///
  /// A stack that was removed is not here to be sold out of: its row survives
  /// so the removal can travel, but its copies are gone and selling from it
  /// would take copies that are not there.
  Future<int?> _held(DatabaseExecutor txn, int entryId) async {
    final rows = await txn.query(
      'collection_entries',
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[entryId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (rows.first['quantity'] as num?)?.toInt() ?? 0;
  }

  Future<List<CardLot>> _lotsForEntry(
    DatabaseExecutor txn,
    CardGame game,
    int entryId,
  ) async {
    final rows = await txn.query(
      'card_lots',
      where: 'game = ? AND entry_id = ? AND quantity > 0',
      whereArgs: <Object?>[game.id, entryId],
      orderBy: 'acquired_on IS NULL, acquired_on ASC, id ASC',
    );
    return <CardLot>[for (final row in rows) CardLot.fromRow(row, game: game)];
  }

  /// Writes lots back with their remaining quantities.
  static Future<void> _saveLots(
    DatabaseExecutor txn,
    List<CardLot> lots,
  ) async {
    for (final lot in lots) {
      if (lot.id == null) {
        if (lot.quantity > 0) await insertLot(txn, lot);
        continue;
      }
      await txn.update(
        'card_lots',
        <String, Object?>{'quantity': lot.quantity},
        where: 'id = ?',
        whereArgs: <Object?>[lot.id],
      );
    }
  }

  /// What the sold copies cost on average, when every one of them is priced.
  static double? _averageCost(CardSale sale) {
    final cost = sale.cost;
    if (cost == null || sale.quantity <= 0) return null;
    return cost / sale.quantity;
  }
}
