import 'package:arcanum/domain/models/card_game.dart';

/// Translates between a deck on a device and its rows in the account, and says
/// which of two copies of a deck is the one to keep.
///
/// A deck is two things on both sides, and the app already says so: the deck row
/// is a deck as stored - its identity, its name, its format, its notes - and its
/// lines are the cards in it. The account holds the same split in two tables,
/// because a whole-deck payload can only be resolved as a whole, and a rule that
/// resolves a deck as a whole silently discards one device's afternoon
/// (docs/deck-sync.md section 1.2). So there are two translations here and two
/// comparisons, and both are pure functions of rows: what a merge decides is
/// weighed without a network, a database or a clock.
///
/// The conflict rule is the collection's rule - the later edit wins and a tie
/// goes to the account - applied one level finer than the collection applies it.
/// On the deck **row** it is applied per field, through [fieldWins]: a deck's
/// name, format and notes are three independent edits with three clocks, because
/// `DeckDao._touch` stamps the deck's `updated_at` every time a card is added,
/// set, moved or removed. Under a row-level clock, an afternoon of adding cards
/// on one device is the same edit as the rename made on another, and its payload
/// carries the name it still had - so the rename is reverted on both devices.
/// On the **contents** it is applied per line, through [lineWins], because a
/// line is edited on its own: one card added, one count changed, one board
/// swapped.
///
/// The one thing a clock on the row still decides is the mark: whether the deck
/// is there at all. A deletion is not a field of a deck, it is a fact about the
/// row, and the only clock a content edit leaves on that row is `updated_at`.
/// That is what makes the design's revival true - adding a card to a deck
/// somebody deleted on another device brings the deck back, with that card in it
/// and every other card still there - and it is the collection's rule read
/// exactly as the collection reads it: a removal is an edit made at a moment, so
/// it beats an older edit and loses to a newer one.
abstract final class AccountDeck {
  /// The account's unique constraint on a deck: `unique (user_id, sync_id)`.
  ///
  /// The client's own identity is half of it, because the account's `id` is
  /// `generated always as identity` and a client cannot supply a value for such
  /// a column - and a client cannot name a conflict target it cannot supply a
  /// value for, which is what a push upserts against. That is what makes a push
  /// safe to repeat after a connection drops mid-flight.
  static const String conflictTarget = 'user_id,sync_id';

  /// The account's key on a line, and the conflict target its push upserts
  /// against. The same shape as the collection's unique index, for the same
  /// reason: it is what makes a removal and a revival one row rather than two.
  static const String lineConflictTarget =
      'user_id,deck_sync_id,card_id,board';

  /// The payload for one deck, read out of this device's `decks` table.
  ///
  /// The owner is deliberately absent, as it is for a holding: the column
  /// defaults to `auth.uid()`, so the database fills it in from the session and
  /// a client can neither forget it nor claim to be somebody else.
  ///
  /// Everything else is sent every time, null included. The account writes an
  /// upsert as an insert ... on conflict do update of the columns the payload
  /// names, so a key left out means "leave whatever is there" - and what is
  /// there for a field this device has no clock for may be another device's
  /// newer edit. A value and its clock travel together for the same reason: a
  /// name with somebody else's clock beside it would be a row claiming an edit
  /// nobody made.
  ///
  /// `sync_id` must already be on the row. A deck that has never travelled and
  /// came from an archive written before v16 has none, and the sync mints one
  /// before it hands the row over, through the one function in the app that
  /// decides what an identity is.
  static Map<String, Object?> row(Map<String, Object?> deck, CardGame game) =>
      <String, Object?>{
        'game': game.id,
        'sync_id': deck['sync_id'],
        'name': (deck['name'] as String?) ?? '',
        'format_id': (deck['format_id'] as String?) ?? '',
        'notes': deck['notes'],
        'name_at': _iso(edited(deck['name_at'])),
        'format_at': _iso(edited(deck['format_at'])),
        'notes_at': _iso(edited(deck['notes_at'])),
        // Sent even when it is null, like the collection's, and for the same
        // reason: what is there for a deck being added back is the tombstone
        // that would keep it deleted forever.
        'deleted_at': _iso(edited(deck['deleted_at'])),
        'created_at': _iso(moment(deck['created_at'])),
        'updated_at': _iso(moment(deck['updated_at'])),
      };

  /// The payload for one line, read out of this device's `deck_cards` table.
  ///
  /// The deck is named by the identity that crosses the wire rather than by the
  /// local integer id, which means nothing to the account. `game` is copied
  /// onto the line because the account's table carries it: nothing that changes
  /// a deck's name, format or notes has any path that changes its game, so a
  /// line's game is fixed when the line is created, and it is what lets the
  /// account be asked for one game's lines in one request.
  static Map<String, Object?> line(
    Map<String, Object?> entry,
    String deckSyncId,
    CardGame game,
  ) => <String, Object?>{
    'game': game.id,
    'deck_sync_id': deckSyncId,
    'card_id': entry['card_id'],
    'board': (entry['board'] as String?) ?? 'main',
    'quantity': (entry['quantity'] as num?)?.toInt() ?? 1,
    'sort': (entry['sort'] as num?)?.toInt() ?? 0,
    'category': (entry['category'] as String?) ?? '',
    'updated_at': _iso(moment(entry['updated_at'])),
    'deleted_at': _iso(edited(entry['deleted_at'])),
  };

  /// Which of two copies of one field of a deck is the one to keep.
  ///
  /// The later edit wins, and a tie goes to the account - the copy every device
  /// can see, so letting the local one win a tie would leave two devices holding
  /// two answers to the same moment. A field with no stamp has never been edited
  /// since v16, and loses to any stamped value: that is what makes a deck from
  /// before this version merge correctly the first time it meets the account.
  ///
  /// A removal is not a special case of this, and that is the point of it being
  /// a timestamp: deleting a deck is an edit made at a moment, so it beats an
  /// older edit and loses to a newer one, which is exactly what adding a card to
  /// the deck is.
  static bool fieldWins(DateTime? local, DateTime? remote) =>
      remote != null && (local == null || !remote.isBefore(local));

  /// Whether the account's copy of a deck's row is the one to keep.
  ///
  /// This decides one thing and only one: the mark. Whether the deck is there,
  /// or has been deleted, is a fact about the row rather than a field of it, and
  /// `updated_at` is the only clock a content edit leaves behind. The name, the
  /// format and the notes are decided by [fieldWins] and are not read here.
  static bool rowWins(DateTime local, DateTime remote) =>
      !remote.isBefore(local);

  /// Whether the account's copy of a line is the one to keep - the collection's
  /// rule, one row down: the later edit wins, a tie goes to the account.
  static bool lineWins(DateTime local, DateTime remote) =>
      !remote.isBefore(local);

  /// The game a row belongs to, or null when it names one this build cannot
  /// place.
  ///
  /// Read out of the row rather than known in advance, because a change arrives
  /// on its own with nothing to say which vault it belongs to: a subscription
  /// filters by account, not by game, so a browser hears about every game it
  /// owns and has to file each row where it came from. Both deck tables carry
  /// the game on the row - on the deck because that is what a deck is, and on
  /// the line because it is fixed when the line is created - which is what makes
  /// this a reading rather than a join.
  ///
  /// [CardGame.fromId] answers Magic for anything it does not recognise, which is
  /// the right default for a preference somebody edited by hand and the wrong one
  /// here: a row for a game this build has never heard of would be filed under
  /// Magic, and a game shipped on the account would quietly put its decks into a
  /// vault they are not in.
  static CardGame? gameOf(Map<String, Object?> row) {
    final Object? id = row['game'];
    if (id is! String) return null;
    for (final CardGame game in CardGame.values) {
      if (game.id == id) return game;
    }
    return null;
  }

  /// A moment out of a local row: both local tables count milliseconds since the
  /// epoch. Nothing there reads as the epoch, which is older than any edit.
  static DateTime moment(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch((value as num?)?.toInt() ?? 0);

  /// A nullable local stamp, where null is the fact that a field has never been
  /// edited since v16 - which is not the same as the epoch, and must not be
  /// flattened into it.
  static DateTime? edited(Object? value) =>
      value == null ? null : moment(value);

  /// An instant out of an account row, in UTC.
  ///
  /// Postgres writes an instant; this device counts milliseconds. The translation
  /// lives here so a timezone cannot quietly turn one into the other, and a value
  /// the account did not send reads as the epoch - older than every edit, which
  /// is the honest answer for a column that is not there.
  static DateTime instant(Object? value) {
    if (value is String) {
      final DateTime? parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toUtc();
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  /// A nullable instant out of an account row. Null stays null: it is what the
  /// account says about a field nobody has ever edited.
  static DateTime? instantOrNull(Object? value) =>
      value == null ? null : instant(value);

  /// An instant as the account writes one, or null.
  static String? _iso(DateTime? value) => value?.toUtc().toIso8601String();
}

/// A deck as the account holds it.
///
/// Read out of the row the account sends rather than known in advance, because a
/// pull brings rows and this is the shape the merge weighs them in. [from]
/// answers null for a row that is not a deck: the identity is the one field
/// nothing can default, so a row without one is not a deck rather than a deck
/// called nothing.
class RemoteDeck {
  const RemoteDeck({
    required this.syncId,
    required this.name,
    required this.formatId,
    required this.notes,
    required this.createdAt,
    required this.updatedAt,
    this.nameAt,
    this.formatAt,
    this.notesAt,
    this.deletedAt,
  });

  final String syncId;
  final String name;
  final String formatId;
  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// When the account says each field was last edited, or null for a field
  /// nobody has edited since the client began stamping.
  final DateTime? nameAt;
  final DateTime? formatAt;
  final DateTime? notesAt;

  /// When the account says the deck was deleted, or null while it is there.
  final DateTime? deletedAt;

  static RemoteDeck? from(Map<String, Object?> row) {
    final Object? syncId = row['sync_id'];
    if (syncId is! String || syncId.isEmpty) return null;
    return RemoteDeck(
      syncId: syncId,
      name: (row['name'] as String?) ?? '',
      formatId: (row['format_id'] as String?) ?? '',
      notes: row['notes'] as String?,
      nameAt: AccountDeck.instantOrNull(row['name_at']),
      formatAt: AccountDeck.instantOrNull(row['format_at']),
      notesAt: AccountDeck.instantOrNull(row['notes_at']),
      deletedAt: AccountDeck.instantOrNull(row['deleted_at']),
      createdAt: AccountDeck.instant(row['created_at']),
      updatedAt: AccountDeck.instant(row['updated_at']),
    );
  }
}

/// One line of a deck as the account holds it.
class RemoteLine {
  const RemoteLine({
    required this.deckSyncId,
    required this.cardId,
    required this.board,
    required this.quantity,
    required this.sort,
    required this.category,
    required this.updatedAt,
    this.deletedAt,
  });

  final String deckSyncId;
  final String cardId;
  final String board;
  final int quantity;
  final int sort;
  final String category;

  /// The whole of the conflict rule for a line: the later stamp wins, a tie goes
  /// to the account.
  final DateTime updatedAt;

  /// When the account says the card left the deck, or null while it is there.
  final DateTime? deletedAt;

  static RemoteLine? from(Map<String, Object?> row) {
    final Object? cardId = row['card_id'];
    final Object? deckSyncId = row['deck_sync_id'];
    if (cardId is! String || cardId.isEmpty) return null;
    if (deckSyncId is! String || deckSyncId.isEmpty) return null;
    return RemoteLine(
      deckSyncId: deckSyncId,
      cardId: cardId,
      board: (row['board'] as String?) ?? 'main',
      quantity: (row['quantity'] as num?)?.toInt() ?? 1,
      sort: (row['sort'] as num?)?.toInt() ?? 0,
      category: (row['category'] as String?) ?? '',
      updatedAt: AccountDeck.instant(row['updated_at']),
      deletedAt: AccountDeck.instantOrNull(row['deleted_at']),
    );
  }
}
