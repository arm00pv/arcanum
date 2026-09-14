import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';

/// Reads and writes what each set's boxes are assumed to hold.
///
/// One row per set. A print run is one print run: two boxes of the same set hold
/// the same thing, so the composition belongs to the set and not to the box on
/// the shelf, and a collector who states it once has stated it for every sealed
/// copy of that set they own now or later.
///
/// [save] is an upsert against the unique index on (game, set_code), which is
/// what makes that promise hold - there is no path here that leaves two
/// compositions for one set for the reader to choose between.
class BoxDao {
  BoxDao(this._db);

  final Database _db;

  /// The composition stated for a set, or null when none has been stated.
  Future<BoxComposition?> forSet(CardGame game, String setCode) async {
    final rows = await _db.query(
      'box_compositions',
      where: 'game = ? AND set_code = ?',
      whereArgs: <Object?>[game.id, setCode],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Every composition stated for a game, keyed by set code.
  Future<Map<String, BoxComposition>> allForGame(CardGame game) async {
    final rows = await _db.query(
      'box_compositions',
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
    );
    return <String, BoxComposition>{
      for (final Map<String, Object?> row in rows)
        (row['set_code'] as String? ?? ''): _fromRow(row),
    };
  }

  /// How many sets of a game have a composition stated.
  Future<int> count(CardGame game) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM box_compositions WHERE game = ?',
      <Object?>[game.id],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// States what a set's boxes hold, replacing whatever was stated before.
  ///
  /// A composition with nothing in it clears the row instead of storing an empty
  /// one, so 'nothing has been stated' has one representation rather than two.
  Future<void> save(
    CardGame game,
    String setCode,
    BoxComposition composition,
  ) async {
    if (composition.isEmpty) {
      await clear(game, setCode);
      return;
    }
    await _db.insert('box_compositions', <String, Object?>{
      'game': game.id,
      'set_code': setCode,
      'packs': composition.packs,
      'cards_per_pack': composition.cardsPerPack,
      'slots': jsonEncode(composition.toJson()['slots']),
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Forgets what was stated for a set.
  Future<void> clear(CardGame game, String setCode) async {
    await _db.delete(
      'box_compositions',
      where: 'game = ? AND set_code = ?',
      whereArgs: <Object?>[game.id, setCode],
    );
  }

  static BoxComposition _fromRow(Map<String, Object?> row) {
    // The row keeps the size in columns of its own - they are the two numbers a
    // query might reasonably sort or filter on - and the slots as JSON. The
    // stored shape and the model's shape are not the same thing, so the reader
    // puts the columns back together rather than trusting the JSON alone.
    List<Object?> slots = const <Object?>[];
    final raw = row['slots'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) slots = decoded;
      } on FormatException {
        slots = const <Object?>[];
      }
    }
    return BoxComposition.fromJson(<String, Object?>{
      'packs': row['packs'],
      'cardsPerPack': row['cards_per_pack'],
      'slots': slots,
    });
  }
}
