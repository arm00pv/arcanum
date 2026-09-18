import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:arcanum/data/sync/account_collection.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// The account's copy of a game's collection, as the sync needs to see it.
///
/// An interface rather than the client itself, so the merge can be tested
/// against a table that answers instantly and misbehaves on demand. A sync is
/// the one piece of the app that has to be right when the network is wrong, and
/// that is not a thing to verify by watching a browser.
abstract interface class AccountTable {
  /// Writes these holdings, replacing any row that is already the same holding.
  ///
  /// Idempotent by construction: the account's unique index makes a second push
  /// of the same collection a no-op rather than a second copy, which is what
  /// makes a push safe to repeat after a connection drops mid-flight.
  Future<void> upsert(List<Map<String, Object?>> rows);

  /// Every holding of one game that belongs to the signed-in account.
  ///
  /// Removed holdings are included, because they are holdings: the row is still
  /// there with a deletion stamped on it. A fetch that filtered them out would
  /// hide a deletion from the one device that has to hear about it, and that
  /// device would push the card back up on its next sync.
  Future<List<Map<String, Object?>>> fetch(CardGame game);
}

/// The real one, over the account service.
class SupabaseAccountTable implements AccountTable {
  const SupabaseAccountTable(this._client);

  final SupabaseClient _client;

  static const String _table = 'collection_entries';

  @override
  Future<void> upsert(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    await _client
        .from(_table)
        .upsert(rows, onConflict: AccountCollection.conflictTarget);
  }

  @override
  Future<List<Map<String, Object?>>> fetch(CardGame game) async {
    final List<Map<String, dynamic>> rows = await _client
        .from(_table)
        .select()
        .eq('game', game.id);
    return rows.map(Map<String, Object?>.from).toList();
  }
}
