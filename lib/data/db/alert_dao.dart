import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/price_alert.dart';

/// Persistence for standing price alerts.
///
/// Alerts are scoped by game like everything else, so an alert on a Magic
/// printing can never be evaluated against a Pokémon price.
class AlertDao {
  AlertDao(this._db);

  final Database _db;

  /// Every alert for a game, armed ones first and newest first within each.
  Future<List<PriceAlert>> all(CardGame game) async {
    final rows = await _db.query(
      'alerts',
      where: 'game = ?',
      whereArgs: [game.id],
      orderBy: 'triggered_at IS NULL DESC, created_at DESC',
    );
    return rows.map(PriceAlert.fromRow).toList();
  }

  /// Alerts that have not fired yet, across every game.
  ///
  /// Used by the evaluator, which has to check both games regardless of which
  /// one is on screen.
  Future<List<PriceAlert>> armed() async {
    final rows = await _db.query(
      'alerts',
      where: 'triggered_at IS NULL',
      orderBy: 'created_at ASC',
    );
    return rows.map(PriceAlert.fromRow).toList();
  }

  /// Alerts for one printing.
  Future<List<PriceAlert>> forCard(CardGame game, String cardId) async {
    final rows = await _db.query(
      'alerts',
      where: 'game = ? AND card_id = ?',
      whereArgs: [game.id, cardId],
      orderBy: 'created_at DESC',
    );
    return rows.map(PriceAlert.fromRow).toList();
  }

  /// How many alerts have fired and have not been acknowledged.
  Future<int> triggeredCount(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM alerts WHERE game = ? AND triggered_at IS NOT NULL',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Total number of alerts for a game.
  Future<int> count(CardGame game) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM alerts WHERE game = ?',
      [game.id],
    );
    return (r.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Inserts a new alert, returning its row id.
  Future<int> insert(PriceAlert alert) => _db.insert('alerts', alert.toRow());

  /// Records the outcome of an evaluation.
  Future<void> markEvaluated(
    int id, {
    required double? lastValue,
    required bool triggered,
  }) async {
    await _db.update(
      'alerts',
      {
        'last_value': lastValue,
        if (triggered) 'triggered_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Re-arms an alert, resetting its baseline to the supplied price.
  Future<void> rearm(int id, {double? baseline}) async {
    await _db.update(
      'alerts',
      {'triggered_at': null, 'baseline': baseline, 'last_value': baseline},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> update(PriceAlert alert) async {
    if (alert.id == null) return;
    await _db.update(
      'alerts',
      alert.toRow()..remove('id'),
      where: 'id = ?',
      whereArgs: [alert.id],
    );
  }

  Future<void> delete(int id) async {
    await _db.delete('alerts', where: 'id = ?', whereArgs: [id]);
  }

  /// Removes every alert for a game, or every alert when [game] is null.
  Future<void> clear({CardGame? game}) async {
    if (game == null) {
      await _db.delete('alerts');
    } else {
      await _db.delete('alerts', where: 'game = ?', whereArgs: [game.id]);
    }
  }
}
