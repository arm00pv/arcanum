import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/data/sync/account_deck.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// The account's copy of a game's decks and their lines, as the sync needs to
/// see it.
///
/// Two tables rather than one, because the account holds them as two: a deck is
/// written before the lines that point at it, and a line's push is an upsert
/// against a key of its own. An interface rather than the client itself, for the
/// reason the collection's table interface is one: a merge is the one piece of
/// the app that has to
/// be right when the network is wrong, and that is not a thing to verify by
/// watching a browser.
abstract interface class DeckTable {
  /// Writes these decks, replacing any deck that is already the same one.
  ///
  /// Idempotent by construction: the account's `unique (user_id, sync_id)` makes
  /// a second push of the same deck a no-op rather than a second deck, which is
  /// what makes a push safe to repeat after a connection drops mid-flight.
  Future<void> upsertDecks(List<Map<String, Object?>> rows);

  /// Writes these lines, replacing any line that is already the same one.
  ///
  /// Idempotent through the primary key `(user_id, deck_sync_id, card_id,
  /// board)`, and only ever called after [upsertDecks]: the account's foreign
  /// key from a line to its deck means a line whose deck is not there yet is
  /// refused.
  Future<void> upsertLines(List<Map<String, Object?>> rows);

  /// Every deck of one game that belongs to the signed-in account.
  ///
  /// Deleted decks are included, because they are decks: the row is still there
  /// with a deletion stamped on it. A fetch that filtered them out would hide a
  /// deletion from the one device that has to hear about it, and that device
  /// would push the deck back up on its next sync.
  Future<List<Map<String, Object?>>> fetchDecks(CardGame game);

  /// Every line of one game's decks, deleted lines included, for the same reason.
  Future<List<Map<String, Object?>>> fetchLines(CardGame game);
}

/// The real one, over the account service.
class SupabaseDeckTable implements DeckTable {
  const SupabaseDeckTable(this._client);

  final SupabaseClient _client;

  static const String _decks = 'decks';
  static const String _lines = 'deck_cards';

  /// How many rows one answer may contain.
  ///
  /// Supabase's REST layer truncates any response at 1,000 rows and says nothing
  /// about it - a request for 1,200 answers with HTTP 200 and 1,000 rows - so a
  /// pull that is not paged loses the tail of a collector's decks in silence. A
  /// Commander deck is at most a hundred lines and a collector's deck list is
  /// measured in tens, so this is not reached in practice; it is here for the
  /// game where it is.
  static const int _page = 1000;

  @override
  Future<void> upsertDecks(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _client
        .from(_decks)
        .upsert(rows, onConflict: AccountDeck.conflictTarget);
  }

  @override
  Future<void> upsertLines(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _client
        .from(_lines)
        .upsert(rows, onConflict: AccountDeck.lineConflictTarget);
  }

  @override
  Future<List<Map<String, Object?>>> fetchDecks(CardGame game) async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (int offset = 0; ; offset += _page) {
      final List<Map<String, dynamic>> rows = await _client
          .from(_decks)
          .select()
          .eq('game', game.id)
          // The order has to be total, or two pages can repeat one row and lose
          // another: which side of a boundary a row falls on is the server's
          // choice and not the client's.
          .order('sync_id')
          .range(offset, offset + _page - 1);
      out.addAll(rows.map(Map<String, Object?>.from));
      if (rows.length < _page) return out;
    }
  }

  @override
  Future<List<Map<String, Object?>>> fetchLines(CardGame game) async {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (int offset = 0; ; offset += _page) {
      final List<Map<String, dynamic>> rows = await _client
          .from(_lines)
          .select()
          .eq('game', game.id)
          // The server's key, in the server's order, for the reason above.
          .order('deck_sync_id')
          .order('board')
          .order('card_id')
          .range(offset, offset + _page - 1);
      out.addAll(rows.map(Map<String, Object?>.from));
      if (rows.length < _page) return out;
    }
  }
}
