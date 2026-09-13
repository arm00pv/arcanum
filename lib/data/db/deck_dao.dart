import 'package:sqflite/sqflite.dart';

import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// Persistence for decks and the cards in them.
///
/// A deck is a list of printings and how many of each, which is deliberately
/// the same shape as the collection and deliberately a different table: a card
/// in a deck is not a card in a box. Moving a card from one to the other is a
/// decision the collector makes, not something the app should infer.
class DeckDao {
  DeckDao(this._db);

  final Database _db;

  // ------------------------------------------------------------------ decks

  /// Every deck of a game, most recently changed first.
  ///
  /// The counts come from one grouped join rather than a query per deck: a
  /// collector with twenty decks should not pay twenty round trips to draw a
  /// list.
  Future<List<Deck>> decks(CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT d.*,
             COALESCE(SUM(CASE WHEN c.board != 'side' THEN c.quantity END), 0)
               AS card_count,
             COALESCE(SUM(CASE WHEN c.board = 'side' THEN c.quantity END), 0)
               AS side_count,
             COUNT(c.card_id) AS unique_cards
        FROM decks d
        LEFT JOIN deck_cards c ON c.deck_id = d.id
       WHERE d.game = ?
       GROUP BY d.id
       ORDER BY d.updated_at DESC, d.id DESC
    ''',
      <Object?>[game.id],
    );
    return <Deck>[for (final r in rows) _deckFrom(r)];
  }

  /// One deck by id, or null when it has been deleted.
  Future<Deck?> deck(int id) async {
    final rows = await _db.rawQuery(
      '''
      SELECT d.*,
             COALESCE(SUM(CASE WHEN c.board != 'side' THEN c.quantity END), 0)
               AS card_count,
             COALESCE(SUM(CASE WHEN c.board = 'side' THEN c.quantity END), 0)
               AS side_count,
             COUNT(c.card_id) AS unique_cards
        FROM decks d
        LEFT JOIN deck_cards c ON c.deck_id = d.id
       WHERE d.id = ?
       GROUP BY d.id
    ''',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _deckFrom(rows.first);
  }

  /// Creates a deck and returns its id.
  Future<int> createDeck({
    required CardGame game,
    required String name,
    required String formatId,
    String? notes,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.insert('decks', <String, Object?>{
      'game': game.id,
      'name': name,
      'format_id': formatId,
      'notes': notes,
      'created_at': now,
      'updated_at': now,
    });
  }

  /// Renames a deck, changes its format, or edits its notes.
  ///
  /// Only the fields passed are written, so a rename cannot quietly clear the
  /// notes the way a whole-row update would.
  Future<void> updateDeck(
    int id, {
    String? name,
    String? formatId,
    String? notes,
    bool clearNotes = false,
  }) async {
    final values = <String, Object?>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (name != null) values['name'] = name;
    if (formatId != null) values['format_id'] = formatId;
    if (clearNotes) {
      values['notes'] = null;
    } else if (notes != null) {
      values['notes'] = notes;
    }
    await _db.update(
      'decks',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Deletes a deck. Its lines go with it, by the cascade on `deck_cards`.
  Future<void> deleteDeck(int id) async {
    await _db.delete('decks', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// Every deck of a game, as bare records, for the picker on a card.
  Future<List<Deck>> decksContaining(CardGame game, String cardId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT d.* FROM decks d
        JOIN deck_cards c ON c.deck_id = d.id
       WHERE d.game = ? AND c.card_id = ?
       ORDER BY d.updated_at DESC
    ''',
      <Object?>[game.id, cardId],
    );
    return <Deck>[for (final r in rows) _deckFrom(r)];
  }

  // ------------------------------------------------------------- deck cards

  /// The lines of a deck, in board order, with no catalogue data attached.
  Future<List<DeckEntry>> entries(int deckId, CardGame game) async {
    final rows = await _db.query(
      'deck_cards',
      where: 'deck_id = ?',
      whereArgs: <Object?>[deckId],
      orderBy:
          "CASE board WHEN 'commander' THEN 0 WHEN 'main' THEN 1 "
          "WHEN 'side' THEN 2 ELSE 3 END, sort ASC, card_id ASC",
    );
    return <DeckEntry>[
      for (final r in rows)
        DeckEntry(
          cardId: r['card_id'] as String,
          quantity: (r['quantity'] as num?)?.toInt() ?? 0,
          board: DeckBoard.fromCode(r['board'] as String?),
          game: game,
          category: (r['category'] as String?) ?? '',
        ),
    ];
  }

  /// Every card id any deck of this game holds.
  Future<List<String>> cardIdsInDecks(CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT DISTINCT c.card_id AS card_id FROM deck_cards c
        JOIN decks d ON d.id = c.deck_id
       WHERE d.game = ?
    ''',
      <Object?>[game.id],
    );
    return <String>[for (final r in rows) r['card_id'] as String];
  }

  /// Adds copies of a card to a board, or adds to what is already there.
  ///
  /// Adding to a deck that already holds the card increases the count rather
  /// than replacing it, which is what pressing "add" twice means.
  Future<void> addCard(
    int deckId,
    String cardId, {
    DeckBoard board = DeckBoard.main,
    int quantity = 1,
  }) async {
    await _db.rawInsert(
      '''
      INSERT INTO deck_cards (deck_id, card_id, board, quantity, sort)
      VALUES (?, ?, ?, ?, COALESCE(
        (SELECT MAX(sort) + 1 FROM deck_cards WHERE deck_id = ?), 0))
      ON CONFLICT(deck_id, card_id, board)
      DO UPDATE SET quantity = quantity + excluded.quantity
    ''',
      <Object?>[deckId, cardId, board.code, quantity, deckId],
    );
    await _touch(deckId);
  }

  /// Sets the exact number of copies on a board, removing the line at zero.
  Future<void> setQuantity(
    int deckId,
    String cardId,
    DeckBoard board,
    int quantity,
  ) async {
    if (quantity <= 0) {
      await removeCard(deckId, cardId, board);
      return;
    }
    await _db.rawInsert(
      '''
      INSERT INTO deck_cards (deck_id, card_id, board, quantity, sort)
      VALUES (?, ?, ?, ?, COALESCE(
        (SELECT MAX(sort) + 1 FROM deck_cards WHERE deck_id = ?), 0))
      ON CONFLICT(deck_id, card_id, board) DO UPDATE SET quantity = excluded.quantity
    ''',
      <Object?>[deckId, cardId, board.code, quantity, deckId],
    );
    await _touch(deckId);
  }

  /// Moves a line to another board, keeping its count.
  Future<void> moveCard(
    int deckId,
    String cardId,
    DeckBoard from,
    DeckBoard to,
  ) async {
    if (from == to) return;
    final rows = await _db.query(
      'deck_cards',
      where: 'deck_id = ? AND card_id = ? AND board = ?',
      whereArgs: <Object?>[deckId, cardId, from.code],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final quantity = (rows.first['quantity'] as num?)?.toInt() ?? 1;
    await removeCard(deckId, cardId, from, touch: false);
    await addCard(deckId, cardId, board: to, quantity: quantity);
  }

  /// Removes a card from one board of a deck.
  Future<void> removeCard(
    int deckId,
    String cardId,
    DeckBoard board, {
    bool touch = true,
  }) async {
    await _db.delete(
      'deck_cards',
      where: 'deck_id = ? AND card_id = ? AND board = ?',
      whereArgs: <Object?>[deckId, cardId, board.code],
    );
    if (touch) await _touch(deckId);
  }

  /// Empties a deck of its cards, leaving the deck itself.
  Future<void> clearDeck(int deckId) async {
    await _db.delete(
      'deck_cards',
      where: 'deck_id = ?',
      whereArgs: <Object?>[deckId],
    );
    await _touch(deckId);
  }

  /// How many decks hold this printing, so a card can say so.
  Future<int> decksHolding(CardGame game, String cardId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT COUNT(*) AS n FROM deck_cards c
        JOIN decks d ON d.id = c.deck_id
       WHERE d.game = ? AND c.card_id = ?
    ''',
      <Object?>[game.id, cardId],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Stamps a deck as changed, which is what orders the list.
  Future<void> _touch(int deckId) async {
    await _db.update(
      'decks',
      <String, Object?>{'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object?>[deckId],
    );
  }

  static Deck _deckFrom(Map<String, Object?> r) => Deck(
    id: (r['id'] as num).toInt(),
    game: CardGame.fromId(r['game'] as String?),
    name: (r['name'] as String?) ?? '',
    formatId: (r['format_id'] as String?) ?? '',
    notes: r['notes'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (r['created_at'] as num?)?.toInt() ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (r['updated_at'] as num?)?.toInt() ?? 0,
    ),
    cardCount: (r['card_count'] as num?)?.toInt() ?? 0,
    uniqueCards: (r['unique_cards'] as num?)?.toInt() ?? 0,
    sideboardCount: (r['side_count'] as num?)?.toInt() ?? 0,
  );
}
