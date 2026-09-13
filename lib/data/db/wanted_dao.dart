import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// The cards the collector wants but does not own yet.
///
/// A want is a note to self, not a second collection: it holds no quantity, no
/// finish and no condition, because none of them are decided until the card is
/// bought. It is keyed by printing, so wanting a foil and wanting the plain
/// printing are the same want - what is being tracked is the card.
///
/// Wants are per game, exactly as the collections are. Wanting a Lorcana card
/// never shows up under Magic.
class WantedDao {
  WantedDao(this._db);

  final Database _db;

  /// Adds a printing to the list, or leaves it there if it is already wanted.
  ///
  /// Adding a want twice is not an error and must not move it to the top of a
  /// list ordered by when it was wanted; the first time is the one that
  /// mattered.
  Future<void> add(CardGame game, String cardId, {String? note}) async {
    await _db.insert('wanted_cards', <String, Object?>{
      'game': game.id,
      'card_id': cardId,
      'note': note,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Adds many printings at once, as one transaction.
  ///
  /// A set can be missing a few hundred cards, and a few hundred individual
  /// inserts would each be their own transaction and their own disk flush.
  ///
  /// Each row is stamped one millisecond apart, counting down, so the list
  /// still reads most-recently-wanted first while a set added in one go comes
  /// back in the order it was given - which is binder order. Stamping them all
  /// with the same instant left the order to the card ids, and Scryfall ids are
  /// UUIDs, so wanting a whole set produced a list in no order at all.
  Future<int> addAll(CardGame game, Iterable<String> cardIds) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = 0;
    var step = 0;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in cardIds) {
        batch.insert('wanted_cards', <String, Object?>{
          'game': game.id,
          'card_id': id,
          'created_at': now - step,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        step += 1;
      }
      final results = await batch.commit();
      for (final r in results) {
        if (r is int && r > 0) added += 1;
      }
    });
    return added;
  }

  /// Removes a printing from the list. Removing one that is not there is fine.
  Future<void> remove(CardGame game, String cardId) async {
    await _db.delete(
      'wanted_cards',
      where: 'game = ? AND card_id = ?',
      whereArgs: <Object?>[game.id, cardId],
    );
  }

  /// The wanted printings of a game, most recently wanted first.
  Future<List<String>> ids(CardGame game) async {
    final rows = await _db.query(
      'wanted_cards',
      columns: <String>['card_id'],
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
      orderBy: 'created_at DESC, card_id ASC',
    );
    return <String>[for (final r in rows) r['card_id'] as String];
  }

  /// How many printings are wanted in a game.
  Future<int> count(CardGame game) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM wanted_cards WHERE game = ?',
      <Object?>[game.id],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Empties one game's list.
  Future<void> clear(CardGame game) async {
    await _db.delete(
      'wanted_cards',
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
    );
  }
}
