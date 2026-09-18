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
/// Nothing here deletes. A holding that exists on the account and not here is
/// pulled in; a holding here and not there is pushed up. That is deliberate for
/// a first cut - a device that has never synced should not be able to empty an
/// account by syncing once - and it is the thing to revisit when deletion has
/// to travel.
class CollectionSync {
  const CollectionSync({required this.table, required this.db});

  /// The account's side.
  final AccountTable table;

  /// This device's side.
  final Database db;

  static const String _local = 'collection_entries';

  /// Sends everything this device holds for one game up to the account.
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

  /// Pushes this device's collection up, then brings the account's back down.
  ///
  /// Push first on purpose. A device that has been used offline is holding work
  /// the account has never seen, and pulling over it first would either lose
  /// that work or make the merge do it in the wrong order.
  Future<void> sync(CardGame game) async {
    await push(game);
    await pull(game);
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
