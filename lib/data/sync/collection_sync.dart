import 'package:sqflite/sqflite.dart';

import 'package:arcanum/data/sync/account_collection.dart';
import 'package:arcanum/data/sync/account_table.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';

/// Keeps one game's collection in step between this device and the account.
///
/// The account is the copy every device can see, so it is the one that decides
/// what a collection is. This device's database stops being the collection and
/// becomes a cache of it: readable, writable and complete while offline, and
/// reconciled the moment there is a connection.
///
/// A removal travels the same way as everything else. A holding is never
/// deleted outright - it is the same row with `deleted_at` set - so a card
/// removed here arrives on the account as an edit and comes back to every other
/// device as an edit, and a card removed elsewhere arrives here as one. Nothing
/// in this file has to know which rows are tombstones; what it does have to get
/// right is the order it works in, which is what [sync] is for.
class CollectionSync {
  const CollectionSync({required this.table, required this.db});

  /// The account's side.
  final AccountTable table;

  /// This device's side.
  final Database db;

  static const String _local = 'collection_entries';

  /// Sends everything this device holds for one game up to the account.
  ///
  /// Everything, including the holdings removed here: a removal is the only
  /// record that a card left, so a push that skipped those rows would leave the
  /// removal on this device and nowhere else.
  ///
  /// Returns how many were sent, which is what a progress line or a test wants
  /// to know - not a number the caller has to count itself.
  Future<int> push(CardGame game) async {
    final List<Map<String, Object?>> local = await db.query(
      _local,
      where: 'game = ?',
      whereArgs: <Object?>[game.id],
    );
    if (local.isEmpty) return 0;

    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final Map<String, Object?> row in local)
        AccountCollection.row(CollectionEntry.fromRow(row), game),
    ];
    await table.upsert(rows);
    return rows.length;
  }

  /// Brings the account's holdings for one game down, keeping the newer copy.
  ///
  /// Removed holdings come down with the rest - a device that cannot see a
  /// deletion is a device that will push the card back up - and they arrive as
  /// ordinary rows with a deletion stamped on them.
  ///
  /// Returns how many holdings the account offered, whether or not each one
  /// changed anything here: a caller that needs "how many are in my collection"
  /// wants the account's count, not the count of rows that happened to differ.
  Future<int> pull(CardGame game) async {
    final List<Map<String, Object?>> remote = await table.fetch(game);
    for (final Map<String, Object?> row in remote) {
      final CollectionEntry? entry = AccountCollection.entry(row);
      if (entry == null) continue;
      await _merge(game, row, entry);
    }
    return remote.length;
  }

  /// Brings the account's collection down, then this device's back up.
  ///
  /// Pull first, and the order is not cosmetic. A push is an upsert of whatever
  /// this device happens to hold, and an upsert never asks whether the account
  /// has moved on: a device asleep for a week would send its stale copy of a
  /// card its owner had deleted on another phone and clear the deletion while
  /// sending it. Merging the account's copy in first means the rows pushed
  /// afterwards are already the winner of every comparison, so the blind write
  /// puts the right thing there.
  ///
  /// The offline promise the other order was for survives it. Work done offline
  /// is newer than the account's copy of the same holding, so the merge leaves
  /// it exactly where it is and the push that follows is what carries it up.
  Future<void> sync(CardGame game) async {
    await pull(game);
    await push(game);
  }

  /// Writes one account holding here, if the account's copy is the newer one.
  Future<void> _merge(
    CardGame game,
    Map<String, Object?> row,
    CollectionEntry remote,
  ) async {
    final List<Map<String, Object?>> existing = await db.query(
      _local,
      where:
          'game = ? AND card_id = ? AND finish = ? AND condition = ? '
          'AND language = ? AND binder = ?',
      whereArgs: <Object?>[
        game.id,
        remote.cardId,
        remote.finish.code,
        remote.condition.code,
        remote.language,
        remote.binder,
      ],
      limit: 1,
    );

    final Map<String, Object?> payload = <String, Object?>{
      ...remote.toRow(),
      'game': game.id,
    };

    if (existing.isEmpty) {
      await db.insert(_local, payload);
      return;
    }

    final CollectionEntry local = CollectionEntry.fromRow(existing.first);
    if (!AccountCollection.accountWins(local, row)) return;
    await db.update(
      _local,
      payload,
      where: 'id = ?',
      whereArgs: <Object?>[existing.first['id']],
    );
  }
}
