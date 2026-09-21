import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/uuid.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// Persistence for decks and the cards in them.
///
/// A deck is a list of printings and how many of each, which is deliberately
/// the same shape as the collection and deliberately a different table: a card
/// in a deck is not a card in a box. Moving a card from one to the other is a
/// decision the collector makes, not something the app should infer.
///
/// Since v16 nothing here deletes a row. A deck that is removed is marked, a
/// line that is removed is marked, and every read filters the marks out - for
/// the reason v15 stopped deleting a stack: the account holds these rows too,
/// and a row that simply vanishes is a row a sync cannot see a removal in. A
/// deck's mark does not touch its lines, so a deck revived by a newer edit is
/// revived whole rather than empty.
///
/// A mark that stays where it is also makes a deletion something the collector
/// can take back, which is what [deletedDecks] and [restoreDeck] are: the list
/// of what has been deleted here, and the edit that puts one of them back. The
/// two are the same fact read and written - nothing is purged, so the list is
/// every deck ever deleted on this device rather than a window of the last few,
/// and undoing one is the newer edit on the row that the account's merge already
/// knows how to weigh.
class DeckDao {
  DeckDao(this._db);

  final Database _db;

  // ------------------------------------------------------------------ decks

  /// Every deck of a game, most recently changed first.
  ///
  /// The counts come from one grouped join rather than a query per deck: a
  /// collector with twenty decks should not pay twenty round trips to draw a
  /// list.
  ///
  /// Both sides of the join are filtered by their marks. A deck that has been
  /// deleted is not in the list, and neither is a line that has been removed
  /// from it - otherwise a removal would still be counted in the deck's size.
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
        LEFT JOIN deck_cards c
          ON c.deck_id = d.id AND c.deleted_at IS NULL
       WHERE d.game = ? AND d.deleted_at IS NULL
       GROUP BY d.id
       ORDER BY d.updated_at DESC, d.id DESC
    ''',
      <Object?>[game.id],
    );
    return <Deck>[for (final r in rows) _deckFrom(r)];
  }

  /// Every deck of a game that has been deleted here, most recently deleted
  /// first.
  ///
  /// The same join as [decks] with the mark the other way round, and the lines
  /// are counted here too: a deck brought back is brought back whole, so what
  /// the collector is choosing between is what each one actually holds. It is
  /// also the honest thing to put beside the name - "Krenko, 98 cards" is a
  /// different answer to "which one was that" than the name alone.
  ///
  /// Nothing purges these rows (§4.3 of the design), so this is every deck the
  /// collector has ever deleted on this device and not the last handful. A list
  /// that quietly stopped at ten would be a list that made a deletion
  /// irreversible again, one deck at a time.
  Future<List<Deck>> deletedDecks(CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT d.*,
             COALESCE(SUM(CASE WHEN c.board != 'side' THEN c.quantity END), 0)
               AS card_count,
             COALESCE(SUM(CASE WHEN c.board = 'side' THEN c.quantity END), 0)
               AS side_count,
             COUNT(c.card_id) AS unique_cards
        FROM decks d
        LEFT JOIN deck_cards c
          ON c.deck_id = d.id AND c.deleted_at IS NULL
       WHERE d.game = ? AND d.deleted_at IS NOT NULL
       GROUP BY d.id
       ORDER BY d.deleted_at DESC, d.id DESC
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
        LEFT JOIN deck_cards c
          ON c.deck_id = d.id AND c.deleted_at IS NULL
       WHERE d.id = ? AND d.deleted_at IS NULL
       GROUP BY d.id
    ''',
      <Object?>[id],
    );
    return rows.isEmpty ? null : _deckFrom(rows.first);
  }

  /// Creates a deck and returns its id.
  ///
  /// The identity the account will know this deck by is minted here, before the
  /// account has ever seen the deck: the account's own id is `generated always as
  /// identity` and a client cannot supply one, so a deck built offline has to
  /// carry a name its own device chose. The name and the format are edits being
  /// made now and are stamped as such - a deck that reached the account with
  /// neither stamped would lose to any edit somebody else had made, which is
  /// right for a deck from before v16 and wrong for one being created in front
  /// of the collector.
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
      'sync_id': Uuid.v4(),
      'name_at': now,
      'format_at': now,
    });
  }

  /// Renames a deck, changes its format, or edits its notes.
  ///
  /// Only the fields passed are written, so a rename cannot quietly clear the
  /// notes the way a whole-row update would.
  ///
  /// Each field passed is stamped with the moment it was edited, and that stamp -
  /// not the row's `updated_at` - is what resolves a disagreement with the
  /// account. A card added to this deck on another device stamps that row and
  /// only that row, so a rename here is not competing with it.
  Future<void> updateDeck(
    int id, {
    String? name,
    String? formatId,
    String? notes,
    bool clearNotes = false,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = <String, Object?>{'updated_at': now};
    if (name != null) {
      values['name'] = name;
      values['name_at'] = now;
    }
    if (formatId != null) {
      values['format_id'] = formatId;
      values['format_at'] = now;
    }
    if (clearNotes) {
      values['notes'] = null;
      values['notes_at'] = now;
    } else if (notes != null) {
      values['notes'] = notes;
      values['notes_at'] = now;
    }
    await _db.update(
      'decks',
      values,
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Marks a deck as deleted, leaving its lines exactly where they are.
  ///
  /// A mark rather than a delete, for the reason v15 marked a stack: the account
  /// holds this row too, and a push that cannot see the removal undoes it, so a
  /// deck deleted here would come back on the next pull. The lines are
  /// deliberately untouched - a deck revived by a later edit has to be revived
  /// whole, and a cascade here would hand the collector a one-card deck with the
  /// same name.
  Future<void> deleteDeck(int id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.update(
      'decks',
      <String, Object?>{'deleted_at': now, 'updated_at': now},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Brings a deleted deck back, as an edit made now.
  ///
  /// The clear of the mark and the new stamp are one statement and both matter,
  /// and they are the whole of this method because they are the whole of what a
  /// deletion is. The stamp is what makes the revival travel: the account
  /// decides whether a deck is there by comparing this row's `updated_at` with
  /// the deletion it is holding, so a deck brought back under its old stamp
  /// would lose that comparison and be deleted again by the next pull - arriving
  /// here as a deck that appeared for a moment and then went. And it is an edit
  /// like any other, which is what the watcher asks about: `ahead()` reads the
  /// newest stamp per game, so an undo is carried up by the same pass that
  /// carries up a rename.
  ///
  /// Only a deleted deck is touched. Putting back a deck that is already there
  /// is not an edit and must not be stamped as one - it would make a deck
  /// nobody has touched look newer than the account's copy of it, and the next
  /// push would then write a row this device never actually changed.
  Future<void> restoreDeck(int id) async {
    await _db.update(
      'decks',
      <String, Object?>{
        'deleted_at': null,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ? AND deleted_at IS NOT NULL',
      whereArgs: <Object?>[id],
    );
  }

  /// Every deck of a game, as bare records, for the picker on a card.
  ///
  /// A deck that has been deleted is not one of them, and neither is a line that
  /// has been removed from a deck - a card screen that says "in 1 deck" about a
  /// deck the collector deleted, or about a card they took out of it, is a lie.
  Future<List<Deck>> decksContaining(CardGame game, String cardId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT d.* FROM decks d
        JOIN deck_cards c ON c.deck_id = d.id AND c.deleted_at IS NULL
       WHERE d.game = ? AND c.card_id = ? AND d.deleted_at IS NULL
       ORDER BY d.updated_at DESC
    ''',
      <Object?>[game.id, cardId],
    );
    return <Deck>[for (final r in rows) _deckFrom(r)];
  }

  // ------------------------------------------------------------- deck cards

  /// The lines of a deck, in board order, with no catalogue data attached.
  ///
  /// Two marks are filtered here and both matter. A line that has been removed
  /// is not a line - it is still in the table, because that is what carries a
  /// removal to the account, and it is not part of the deck. And a line of a
  /// deck that has been deleted is not shown either: the deck is gone from the
  /// list, and the lines of a deck nobody can open are not something any screen
  /// asks for. They are still there, which is what makes a revival whole.
  Future<List<DeckEntry>> entries(int deckId, CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT c.* FROM deck_cards c
        JOIN decks d ON d.id = c.deck_id
       WHERE c.deck_id = ? AND c.deleted_at IS NULL AND d.deleted_at IS NULL
       ORDER BY CASE c.board WHEN 'commander' THEN 0 WHEN 'main' THEN 1
                            WHEN 'side' THEN 2 ELSE 3 END,
                c.sort ASC, c.card_id ASC
    ''',
      <Object?>[deckId],
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
  ///
  /// The ids a sign-in has to fetch the cards for, so it is the decks that are
  /// there and the lines that are in them: a printing named only by a deck the
  /// collector deleted, or by a line they removed from one, is not a printing
  /// this screen will ever have to draw.
  Future<List<String>> cardIdsInDecks(CardGame game) async {
    final rows = await _db.rawQuery(
      '''
      SELECT DISTINCT c.card_id AS card_id FROM deck_cards c
        JOIN decks d ON d.id = c.deck_id
       WHERE d.game = ? AND d.deleted_at IS NULL AND c.deleted_at IS NULL
    ''',
      <Object?>[game.id],
    );
    return <String>[for (final r in rows) r['card_id'] as String];
  }

  /// Adds copies of a card to a board, or adds to what is already there.
  ///
  /// Adding to a deck that already holds the card increases the count rather
  /// than replacing it, which is what pressing "add" twice means.
  ///
  /// Adding to a line that has been removed revives it in place with the new
  /// count, and not as a sum. A collector who removed four Chieftains and then
  /// added one owns one, so the count is what they just added rather than what
  /// the row still remembered - which is the same rule the account applies to a
  /// removed holding. The row is revived rather than inserted beside, because
  /// the primary key is the only thing that decides whether two lines are one
  /// line.
  Future<void> addCard(
    int deckId,
    String cardId, {
    DeckBoard board = DeckBoard.main,
    int quantity = 1,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawInsert(
      '''
      INSERT INTO deck_cards (deck_id, card_id, board, quantity, sort, updated_at)
      VALUES (?, ?, ?, ?, COALESCE(
        (SELECT MAX(sort) + 1 FROM deck_cards WHERE deck_id = ?), 0), ?)
      ON CONFLICT(deck_id, card_id, board) DO UPDATE SET
        quantity = CASE WHEN deck_cards.deleted_at IS NULL
                        THEN deck_cards.quantity + excluded.quantity
                        ELSE excluded.quantity END,
        deleted_at = NULL,
        updated_at = excluded.updated_at
    ''',
      <Object?>[deckId, cardId, board.code, quantity, deckId, now],
    );
    await _touch(deckId);
  }

  /// Sets the exact number of copies on a board, removing the line at zero.
  ///
  /// Setting a count on a line that has been removed revives it the same way
  /// [addCard] does: the count the collector asked for, on the row that is
  /// already there.
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
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawInsert(
      '''
      INSERT INTO deck_cards (deck_id, card_id, board, quantity, sort, updated_at)
      VALUES (?, ?, ?, ?, COALESCE(
        (SELECT MAX(sort) + 1 FROM deck_cards WHERE deck_id = ?), 0), ?)
      ON CONFLICT(deck_id, card_id, board) DO UPDATE SET
        quantity = excluded.quantity,
        deleted_at = NULL,
        updated_at = excluded.updated_at
    ''',
      <Object?>[deckId, cardId, board.code, quantity, deckId, now],
    );
    await _touch(deckId);
  }

  /// Moves a line to another board, keeping its count.
  ///
  /// A move is a removal and an addition, and after v16 a removal is a mark: the
  /// line on the old board is stamped and a line on the new board is written,
  /// which is what the collector sees and what the account is told. A line that
  /// has already been removed is not moved, because there is nothing there to
  /// move.
  Future<void> moveCard(
    int deckId,
    String cardId,
    DeckBoard from,
    DeckBoard to,
  ) async {
    if (from == to) return;
    final rows = await _db.query(
      'deck_cards',
      where: 'deck_id = ? AND card_id = ? AND board = ? AND deleted_at IS NULL',
      whereArgs: <Object?>[deckId, cardId, from.code],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final quantity = (rows.first['quantity'] as num?)?.toInt() ?? 1;
    await removeCard(deckId, cardId, from, touch: false);
    await addCard(deckId, cardId, board: to, quantity: quantity);
  }

  /// Removes a card from one board of a deck, by marking the line.
  ///
  /// The line keeps its quantity and its sort: what the collector did is take
  /// the card out of the deck, and the row is what remembers that it was there.
  /// The mark is a timestamp on the line, so it travels through the same push
  /// and pull as every other change, and it beats an older edit and loses to a
  /// newer one - which is what re-adding the card is.
  Future<void> removeCard(
    int deckId,
    String cardId,
    DeckBoard board, {
    bool touch = true,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.update(
      'deck_cards',
      <String, Object?>{'deleted_at': now, 'updated_at': now},
      where: 'deck_id = ? AND card_id = ? AND board = ?',
      whereArgs: <Object?>[deckId, cardId, board.code],
    );
    if (touch) await _touch(deckId);
  }

  /// Empties a deck of its cards, leaving the deck itself.
  ///
  /// Every line is marked rather than dropped, for the reason [removeCard] marks
  /// one: the account holds these rows, and a push that cannot see the removal
  /// brings the cards back.
  Future<void> clearDeck(int deckId) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    await _db.update(
      'deck_cards',
      <String, Object?>{'deleted_at': now, 'updated_at': now},
      where: 'deck_id = ?',
      whereArgs: <Object?>[deckId],
    );
    await _touch(deckId);
  }

  /// How many decks hold this printing, so a card can say so.
  ///
  /// The decks that are there and the lines that are in them, for the reason
  /// [decksContaining] filters the same two marks.
  Future<int> decksHolding(CardGame game, String cardId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT COUNT(*) AS n FROM deck_cards c
        JOIN decks d ON d.id = c.deck_id
       WHERE d.game = ? AND c.card_id = ?
         AND d.deleted_at IS NULL AND c.deleted_at IS NULL
    ''',
      <Object?>[game.id, cardId],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// Stamps a deck as changed, which is what orders the list.
  ///
  /// Deliberately the row's own clock and not a field's: a card added here
  /// changed the deck, and did not edit its name, its format or its notes. The
  /// merge reads those three stamps, so an afternoon of adding cards cannot
  /// compete with a rename somebody made on another device.
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
