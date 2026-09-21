import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/uuid.dart';
import 'package:arcanum/data/sync/account_deck.dart';
import 'package:arcanum/data/sync/deck_table.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// Keeps one game's decks, and the cards in them, in step between this device
/// and the account.
///
/// The account becomes the copy every device can see, as it already is for the
/// collection. This device's database stops being the only copy and becomes a
/// cache of it: readable, writable and complete while offline, and reconciled
/// the moment there is a connection.
///
/// A deck travels as a row, and its contents travel as rows of their own, for
/// two different reasons. The deck row is one row because a deck *is* one thing -
/// a name, a format and some notes - and it is resolved per field, because those
/// three are edited independently ([AccountDeck.fieldWins]). The contents are
/// rows rather than a document on the deck row because a deck editing session is
/// not one edit: a collector adds four Chieftains, removes two War Marshals and
/// moves a Sol Ring, and a second device does the same on the same evening. Each
/// of those is one line, and lines are resolved against each other one at a time,
/// so both devices keep what they did.
///
/// A removal travels as a mark on the row, exactly as it does in the collection:
/// a deck is never deleted outright and neither is a line, so a removal arrives
/// at the account as an edit and comes back to every other device as one. Nothing
/// here has to know which rows are marks; what it does have to get right is the
/// order it works in, which is what [sync] is for.
class DeckSync {
  DeckSync({required this.table, required this.db});

  /// The account's side.
  final DeckTable table;

  /// This device's side.
  final Database db;

  static const String _decks = 'decks';
  static const String _lines = 'deck_cards';

  /// The newest edit this device has carried up, by game.
  ///
  /// The deck side of what a watcher has to ask: not whether a deck has changed
  /// but whether the account has been told, and only a push can answer that. It
  /// is recorded where pushes happen rather than kept by whoever asks, so every
  /// push - a sign-in's, a watcher's - leaves it correct.
  ///
  /// Held for the life of the process and never written down, for the reason the
  /// collection's is: it is knowledge about the account, and a session begins by
  /// reading the account's own copy. A value kept past a sign-in would describe
  /// rows that are no longer there, since restoring an archive brings rows with
  /// their own older stamps.
  final Map<String, int> _carried = <String, int>{};

  /// Sends everything this device holds for one game up to the account.
  ///
  /// Everything, including the decks and the lines removed here: a removal is the
  /// only record that something left, so a push that skipped those rows would
  /// leave the removal on this device and nowhere else.
  ///
  /// Decks are written before their lines, because the account's foreign key from
  /// a line to its deck refuses a line whose deck is not there yet. That is the
  /// one real difference from the collection's push, which is a single upsert of
  /// one array: two tables cannot be one statement.
  ///
  /// Returns how many rows were sent, and records the newest stamp among them as
  /// what this device has carried up - after the account answers and never
  /// before, so a push that failed does not look like one that worked.
  Future<int> push(CardGame game) async {
    final List<Map<String, Object?>> decks = await db.query(
      _decks,
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
    );
    if (decks.isEmpty) return 0;

    final List<Map<String, Object?>> lines = await _linesOf(game);
    final int sent = await _send(game, decks, lines);
    _carried[game.id] = _newest(<List<Map<String, Object?>>>[decks, lines]);
    return sent;
  }

  /// Carries up the decks and lines this device has changed since it last did.
  ///
  /// The counterpart to [push] rather than a second version of it, and it exists
  /// for the same trap: an upsert never asks what the account holds, so a device
  /// sending a deck it has not touched since it last pushed is how a browser left
  /// closed for a week clears a rename somebody made on another browser while it
  /// was away. Only rows stamped since the last push travel here, and those are
  /// the rows this device has actually edited - so nothing this device has no
  /// news about is ever sent, and the news it does have is the newest it knows.
  ///
  /// A line whose deck has not moved can still travel on its own: it is one row
  /// of one deck that is already on the account, and the account's key for it is
  /// the deck's identity rather than the deck row.
  Future<int> pushAhead(CardGame game) async {
    final int since = _carried[game.id] ?? 0;
    final List<Map<String, Object?>> decks = await db.query(
      _decks,
      where: 'game = ? AND updated_at > ?',
      whereArgs: <Object?>[game.id, since],
    );
    final List<Map<String, Object?>> lines = await db.rawQuery(
      'SELECT c.* FROM $_lines c JOIN $_decks d ON d.id = c.deck_id '
      'WHERE d.game = ? AND c.updated_at > ?',
      <Object?>[game.id, since],
    );
    if (decks.isEmpty && lines.isEmpty) return 0;

    final int sent = await _send(game, decks, lines);
    _carried[game.id] = _newest(<List<Map<String, Object?>>>[decks, lines]);
    return sent;
  }

  /// The games holding a deck or a line the account has not been told about.
  ///
  /// The most recently edited first, so the game somebody is working in is the
  /// one being brought current, which is the one they will look at.
  ///
  /// One query for all of them, because this is asked on a timer and a timer that
  /// costs nine queries to be told nothing has happened is a timer that shows up
  /// in a profile. A game whose decks have not moved - or which has none - is not
  /// in the answer, and a watch that gets an empty list makes no request.
  ///
  /// Both tables are read, and the newest of the two decides: adding a card
  /// stamps the deck as well as the line, but a line can also move on its own
  /// when it arrives from the account, and a game that answered only for its
  /// decks would leave that line here.
  Future<List<CardGame>> ahead() async {
    final List<Map<String, Object?>> held = await db.rawQuery(
      'SELECT game, MAX(newest) AS newest FROM ('
      '  SELECT d.game AS game, d.updated_at AS newest FROM $_decks d '
      '  UNION ALL '
      '  SELECT d.game AS game, c.updated_at AS newest FROM $_lines c '
      '    JOIN $_decks d ON d.id = c.deck_id'
      ') GROUP BY game ORDER BY newest DESC',
    );
    final List<CardGame> moved = <CardGame>[];
    for (final Map<String, Object?> row in held) {
      final String id = row['game'] as String? ?? '';
      final int newest = (row['newest'] as num?)?.toInt() ?? 0;
      if (newest > (_carried[id] ?? 0)) moved.add(CardGame.fromId(id));
    }
    return moved;
  }

  /// Brings the account's decks and lines for one game down, keeping the newer
  /// copy of each field and of each line.
  ///
  /// Decks first and then their lines, because a line is stored against the local
  /// deck it belongs to: a line that arrived before its deck would have nowhere
  /// to land.
  ///
  /// Removed decks and removed lines come down with the rest - a device that
  /// cannot see a removal is a device that will push it back up - and they arrive
  /// as ordinary rows with a deletion stamped on them.
  ///
  /// Returns how many rows the account offered, whether or not each one changed
  /// anything here.
  Future<int> pull(CardGame game) async {
    final List<Map<String, Object?>> decks = await table.fetchDecks(game);
    for (final Map<String, Object?> row in decks) {
      await mergeDeck(game, row);
    }
    final List<Map<String, Object?>> lines = await table.fetchLines(game);
    for (final Map<String, Object?> row in lines) {
      await mergeLine(game, row);
    }
    return decks.length + lines.length;
  }

  /// Brings the account's decks down, then this device's back up.
  ///
  /// Pull first, and the order is not cosmetic. A push is an upsert of whatever
  /// this device happens to hold, and an upsert never asks whether the account
  /// has moved on: a device asleep for a week would send its stale copy of a deck
  /// its owner had renamed on another browser and clear the rename while sending
  /// it. Merging the account's copy in first means the rows pushed afterwards are
  /// already the winner of every comparison, so the blind write puts the right
  /// thing there.
  ///
  /// The offline promise the other order was for survives it: work done offline
  /// is newer than the account's copy of the same field or the same line, so the
  /// merge leaves it exactly where it is and the push that follows carries it up.
  Future<void> sync(CardGame game) async {
    await pull(game);
    await push(game);
  }

  /// Writes one account deck here, field by field.
  ///
  /// The same comparison a pull makes, made once per field, and the same one a
  /// change arriving on its own will make when the deck tables are streamed -
  /// there is one rule for which copy of a name, a format or some notes the deck
  /// has, and this is it.
  ///
  /// Answers whether it changed anything, which is what a caller that has to
  /// decide whether to disturb a screen needs to know.
  Future<bool> mergeDeck(CardGame game, Map<String, Object?> row) async {
    final RemoteDeck? remote = RemoteDeck.from(row);
    if (remote == null) return false;

    final List<Map<String, Object?>> existing = await db.query(
      _decks,
      where: 'sync_id = ?',
      whereArgs: <Object?>[remote.syncId],
      limit: 1,
    );

    if (existing.isEmpty) {
      // A deck this device has never seen, including one already deleted
      // elsewhere: it lands as it is, and a deleted one lands hidden rather than
      // not at all - the mark is what stops it being pushed back up.
      await db.insert(_decks, <String, Object?>{
        'game': game.id,
        'name': remote.name,
        'format_id': remote.formatId,
        'notes': remote.notes,
        'created_at': remote.createdAt.millisecondsSinceEpoch,
        'updated_at': remote.updatedAt.millisecondsSinceEpoch,
        'sync_id': remote.syncId,
        'name_at': _millis(remote.nameAt),
        'format_at': _millis(remote.formatAt),
        'notes_at': _millis(remote.notesAt),
        'deleted_at': _millis(remote.deletedAt),
      });
      return true;
    }

    final Map<String, Object?> local = existing.first;
    final Map<String, Object?> values = <String, Object?>{};

    // The three fields a deck can be edited by independently. The clock travels
    // with the value, so the row that comes out of this always says when each of
    // its fields was last touched.
    if (AccountDeck.fieldWins(
      AccountDeck.edited(local['name_at']),
      remote.nameAt,
    )) {
      values['name'] = remote.name;
      values['name_at'] = _millis(remote.nameAt);
    }
    if (AccountDeck.fieldWins(
      AccountDeck.edited(local['format_at']),
      remote.formatAt,
    )) {
      values['format_id'] = remote.formatId;
      values['format_at'] = _millis(remote.formatAt);
    }
    if (AccountDeck.fieldWins(
      AccountDeck.edited(local['notes_at']),
      remote.notesAt,
    )) {
      values['notes'] = remote.notes;
      values['notes_at'] = _millis(remote.notesAt);
    }

    // Whether the deck is there at all is a fact about the row rather than a
    // field of it, and updated_at is the only clock a content edit leaves on that
    // row - which is what lets a card added on another device revive a deck
    // somebody deleted. The name above is not touched by this and this does not
    // touch the name.
    if (AccountDeck.rowWins(
      AccountDeck.moment(local['updated_at']),
      remote.updatedAt,
    )) {
      values['updated_at'] = remote.updatedAt.millisecondsSinceEpoch;
      values['deleted_at'] = _millis(remote.deletedAt);
    }

    if (values.isEmpty) return false;
    await db.update(
      _decks,
      values,
      where: 'id = ?',
      whereArgs: <Object?>[local['id']],
    );
    return true;
  }

  /// Writes one account line here, if the account's copy is the newer one.
  ///
  /// A line is one row of one deck on both sides, keyed the same way - the deck,
  /// the card and the board - so a line that was removed on one device and added
  /// back on it is the same row coming back rather than a second one. That is
  /// what makes the count the new count: a revival writes what the collector
  /// asked for, and nothing here sums two devices' quantities.
  ///
  /// Answers whether it wrote.
  Future<bool> mergeLine(CardGame game, Map<String, Object?> row) async {
    final RemoteLine? remote = RemoteLine.from(row);
    if (remote == null) return false;

    final List<Map<String, Object?>> deck = await db.query(
      _decks,
      columns: <String>['id'],
      where: 'sync_id = ?',
      whereArgs: <Object?>[remote.deckSyncId],
      limit: 1,
    );
    // A line whose deck is not here is not a line: there is nothing for it to be
    // part of, and a local row that pointed at nothing would have nowhere to be
    // shown. Decks are pulled before their lines, so this is a row for a deck the
    // account has not offered.
    if (deck.isEmpty) return false;
    final int deckId = (deck.first['id'] as num).toInt();

    final List<Map<String, Object?>> existing = await db.query(
      _lines,
      where: 'deck_id = ? AND card_id = ? AND board = ?',
      whereArgs: <Object?>[deckId, remote.cardId, remote.board],
      limit: 1,
    );

    final Map<String, Object?> payload = <String, Object?>{
      'deck_id': deckId,
      'card_id': remote.cardId,
      'board': remote.board,
      'quantity': remote.quantity,
      'sort': remote.sort,
      'category': remote.category,
      'updated_at': remote.updatedAt.millisecondsSinceEpoch,
      'deleted_at': _millis(remote.deletedAt),
    };

    if (existing.isEmpty) {
      await db.insert(_lines, payload);
      return true;
    }

    final DateTime local = AccountDeck.moment(existing.first['updated_at']);
    if (!AccountDeck.lineWins(local, remote.updatedAt)) return false;
    await db.update(
      _lines,
      payload,
      where: 'deck_id = ? AND card_id = ? AND board = ?',
      whereArgs: <Object?>[deckId, remote.cardId, remote.board],
    );
    return true;
  }

  /// Writes these rows to the account, decks before their lines.
  ///
  /// Returns how many rows were sent, which is what a test or a progress line
  /// wants to know rather than a number the caller counts itself.
  Future<int> _send(
    CardGame game,
    List<Map<String, Object?>> decks,
    List<Map<String, Object?>> lines,
  ) async {
    // Identity before payload. A deck that came from an archive written before
    // v16 has none, and the account refuses a deck without one - rather than
    // inventing a second identity for it, which would be one duplicate per push.
    final Map<int, String> identities = await _identities(game);

    await table.upsertDecks(<Map<String, Object?>>[
      for (final Map<String, Object?> deck in decks)
        AccountDeck.row(<String, Object?>{
          ...deck,
          'sync_id': identities[(deck['id'] as num).toInt()],
        }, game),
    ]);

    final List<Map<String, Object?>> payload = <Map<String, Object?>>[];
    for (final Map<String, Object?> line in lines) {
      final String? syncId = identities[(line['deck_id'] as num).toInt()];
      if (syncId == null) continue;
      payload.add(AccountDeck.line(line, syncId, game));
    }
    await table.upsertLines(payload);

    return decks.length + payload.length;
  }

  /// The identity of every deck of one game, minting one where there is none.
  ///
  /// Every deck and not only the ones being pushed, because a line is named on
  /// the wire by its deck's identity: a line that had to wait for its deck to be
  /// edited before it could travel would be a line that never travelled.
  Future<Map<int, String>> _identities(CardGame game) async {
    final List<Map<String, Object?>> rows = await db.query(
      _decks,
      columns: <String>['id', 'sync_id'],
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
    );
    final Map<int, String> identities = <int, String>{};
    for (final Map<String, Object?> row in rows) {
      final int id = (row['id'] as num).toInt();
      String? syncId = row['sync_id'] as String?;
      if (syncId == null || syncId.isEmpty) {
        syncId = Uuid.v4();
        await db.update(
          _decks,
          <String, Object?>{'sync_id': syncId},
          where: 'id = ?',
          whereArgs: <Object?>[id],
        );
      }
      identities[id] = syncId;
    }
    return identities;
  }

  /// Every line of one game's decks, as stored.
  ///
  /// One query and not one per deck: a collector with forty decks should not pay
  /// forty round trips to a database to push the game, and the join is the one
  /// the counts in the deck list already use.
  Future<List<Map<String, Object?>>> _linesOf(CardGame game) => db.rawQuery(
    'SELECT c.* FROM $_lines c JOIN $_decks d ON d.id = c.deck_id '
    'WHERE d.game = ?',
    <Object?>[game.id],
  );

  /// The newest stamp among these rows - what the account has just been told.
  static int _newest(List<List<Map<String, Object?>>> groups) {
    var newest = 0;
    for (final List<Map<String, Object?>> rows in groups) {
      for (final Map<String, Object?> row in rows) {
        newest = math.max(newest, (row['updated_at'] as num?)?.toInt() ?? 0);
      }
    }
    return newest;
  }

  static int? _millis(DateTime? moment) => moment?.millisecondsSinceEpoch;
}
