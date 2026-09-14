import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';

/// Reads and writes the collector's sealed product.
///
/// One row per kind of box, pack or deck, with a quantity - the same shape as a
/// stack of cards, because a shelf of six booster boxes is a holding in exactly
/// the way six copies of a card are.
///
/// Prices are stored as the last figure anything saw for the product, together
/// with the day it was seen, so a valuation can say how old its own numbers are
/// rather than presenting them as live.
class SealedDao {
  SealedDao(this._db);

  final Database _db;

  /// Everything sealed in one game, newest first.
  Future<List<SealedHolding>> all(CardGame game) async {
    final rows = await _db.query(
      'sealed_products',
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
      orderBy: 'created_at DESC, id DESC',
    );
    return <SealedHolding>[for (final r in rows) _fromRow(r, game)];
  }

  /// One holding by id, or null when it has been deleted.
  Future<SealedHolding?> byId(int id) async {
    final rows = await _db.query(
      'sealed_products',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return _fromRow(row, CardGame.fromId(row['game'] as String?));
  }

  /// Stores a new holding and returns its row id.
  Future<int> insert(SealedHolding holding) async {
    return _db.insert('sealed_products', <String, Object?>{
      'game': holding.game.id,
      'set_code': holding.setCode,
      'set_name': holding.setName,
      'name': holding.name,
      'category': holding.category.id,
      'quantity': holding.quantity,
      'unit_cost': holding.unitCost,
      'unit_value': holding.unitValue,
      'value_as_of': holding.valueAsOf?.millisecondsSinceEpoch,
      'location': holding.location,
      'note': holding.note,
      'product_id': holding.productId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Overwrites an existing holding. Does nothing when the row is gone.
  Future<void> update(SealedHolding holding) async {
    final id = holding.id;
    if (id == null) return;
    await _db.update(
      'sealed_products',
      <String, Object?>{
        'set_code': holding.setCode,
        'set_name': holding.setName,
        'name': holding.name,
        'category': holding.category.id,
        'quantity': holding.quantity,
        'unit_cost': holding.unitCost,
        'unit_value': holding.unitValue,
        'value_as_of': holding.valueAsOf?.millisecondsSinceEpoch,
        'location': holding.location,
        'note': holding.note,
        'product_id': holding.productId,
      },
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Removes a holding.
  Future<void> delete(int id) async {
    await _db.delete(
      'sealed_products',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// How many sealed products are held in a game, counting quantity.
  Future<int> count(CardGame game) async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(quantity), 0) AS n FROM sealed_products '
      'WHERE game = ?',
      <Object?>[game.id],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Records a price for every holding of one product, so a refreshed figure
  /// reaches the whole shelf rather than the row that was open.
  Future<int> priceByProductId({
    required CardGame game,
    required String productId,
    required double unitValue,
    required DateTime asOf,
  }) async {
    if (productId.isEmpty) return 0;
    return _db.update(
      'sealed_products',
      <String, Object?>{
        'unit_value': unitValue,
        'value_as_of': asOf.millisecondsSinceEpoch,
      },
      where: 'game = ? AND product_id = ?',
      whereArgs: <Object?>[game.id, productId],
    );
  }

  static SealedHolding _fromRow(Map<String, Object?> row, CardGame game) {
    final ms = row['value_as_of'] as int?;
    return SealedHolding(
      id: (row['id'] as num?)?.toInt(),
      game: game,
      setCode: (row['set_code'] as String?) ?? '',
      setName: (row['set_name'] as String?) ?? '',
      name: (row['name'] as String?) ?? '',
      category: SealedCategory.fromId(row['category'] as String?),
      quantity: (row['quantity'] as num?)?.toInt() ?? 1,
      unitCost: (row['unit_cost'] as num?)?.toDouble(),
      unitValue: (row['unit_value'] as num?)?.toDouble(),
      valueAsOf: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
      location: (row['location'] as String?) ?? '',
      note: (row['note'] as String?) ?? '',
      productId: (row['product_id'] as String?) ?? '',
    );
  }
}
