import 'dart:math' as math;

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
  CollectionSync({required this.table, required this.db});

  /// The account's side.
  final AccountTable table;

  /// This device's side.
  final Database db;

  static const String _local = 'collection_entries';

  /// The newest edit this device has carried up, by game.
  ///
  /// What a watcher has to ask is not whether the collection has changed but
  /// whether the account has been told, and only a push can answer that. So the
  /// answer is recorded where pushes happen rather than kept by whoever asks,
  /// and every push - a sign-in's, a watcher's - leaves it correct.
  ///
  /// Held for the life of the process and never written down. It is knowledge
  /// about the account, and a session begins by reading the account's own copy;
  /// a value kept past that sign-in would describe a collection that is no
  /// longer there, since restoring an archive brings rows with their own older
  /// stamps. Being wrong in the other direction costs one push, and this one
  /// costs a change that never travels at all.
  final Map<String, int> _carried = <String, int>{};

  /// Sends everything this device holds for one game up to the account.
  ///
  /// Everything, including the holdings removed here: a removal is the only
  /// record that a card left, so a push that skipped those rows would leave the
  /// removal on this device and nowhere else.
  ///
  /// Returns how many were sent, which is what a progress line or a test wants
  /// to know - not a number the caller has to count itself.
  ///
  /// The newest stamp in what was sent becomes what this device has carried up.
  /// Recorded after the account answers and never before: a push that failed
  /// must not look like one that worked, or the edit it was carrying would sit
  /// waiting for a next edit that may never come, which is the bug this file is
  /// here to prevent, arrived at from the other side.
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
    _carried[game.id] = _newest(local);
    return rows.length;
  }

  /// Carries up the holdings this device has changed since it last did.
  ///
  /// The counterpart to [push] rather than a second version of it. A whole-game
  /// push answers for the whole game because that is what a sign-in is asking;
  /// it is also blind, and there is a trap in that: an upsert never asks what
  /// the account holds, so a device sending a row it has not touched since it
  /// last pushed is how a browser left closed for a week clears a removal
  /// somebody made on another browser while it was away. Only the rows stamped
  /// since the last push travel here, and those are the rows this device has
  /// actually edited - so nothing this device has no news about is ever sent,
  /// and the news it does have is the newest this device knows.
  ///
  /// Returns how many were sent, and nothing at all when the account already
  /// has everything this device holds.
  Future<int> pushAhead(CardGame game) async {
    final List<Map<String, Object?>> local = await db.query(
      _local,
      where: 'game = ? AND updated_at > ?',
      whereArgs: <Object?>[game.id, _carried[game.id] ?? 0],
    );
    if (local.isEmpty) return 0;

    final List<Map<String, Object?>> rows = <Map<String, Object?>>[
      for (final Map<String, Object?> row in local)
        AccountCollection.row(CollectionEntry.fromRow(row), game),
    ];
    await table.upsert(rows);
    _carried[game.id] = _newest(local);
    return rows.length;
  }

  /// The games holding an edit the account has not been told about.
  ///
  /// The most recently edited first, so the game somebody is working in is the
  /// one being brought current, which is the one they will look at.
  ///
  /// One query for all of them, because this is asked on a timer and a timer
  /// that costs nine queries to be told nothing has happened is a timer that
  /// shows up in a profile. A game whose rows have not moved - or which has no
  /// rows at all - is not in the answer, and a watch that gets an empty list
  /// makes no request.
  Future<List<CardGame>> ahead() async {
    final List<Map<String, Object?>> held = await db.rawQuery(
      'SELECT game, MAX(updated_at) AS newest FROM $_local '
      'GROUP BY game ORDER BY newest DESC',
    );
    final List<CardGame> moved = <CardGame>[];
    for (final Map<String, Object?> row in held) {
      final String id = row['game'] as String? ?? '';
      final int newest = (row['newest'] as num?)?.toInt() ?? 0;
      if (newest > (_carried[id] ?? 0)) moved.add(CardGame.fromId(id));
    }
    return moved;
  }

  /// The newest edit among [rows] - what the account has just been told.
  static int _newest(List<Map<String, Object?>> rows) => rows.fold<int>(
    0,
    (int newest, Map<String, Object?> row) =>
        math.max(newest, (row['updated_at'] as num?)?.toInt() ?? 0),
  );

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
      await mergeRow(game, row);
    }
    return remote.length;
  }

  /// Writes one account holding here, if the account's copy is the newer one.
  ///
  /// The same comparison a pull makes, for a row that arrived on its own. A
  /// change the account announces and a change a pull brings down are the same
  /// fact, and a second rule for weighing them would be a second answer to
  /// which copy of a holding the collection is - so there is one, and both
  /// paths go through it.
  ///
  /// Answers whether it changed anything, which is what a caller that has to
  /// decide whether to disturb a screen needs to know.
  Future<bool> mergeRow(CardGame game, Map<String, Object?> row) async {
    final CollectionEntry? entry = AccountCollection.entry(row);
    if (entry == null) return false;
    return _merge(game, row, entry);
  }

  /// Brings the account's holdings for one game down, answering whether any of
  /// them was newer than this device's copy.
  ///
  /// [pull] asked a different question - how many holdings the account has -
  /// and that count cannot answer this one: nine games the account holds
  /// thousands of rows for would be nine games announced every time a browser
  /// reconnects, most of them to show the collection that is already on screen.
  Future<bool> pullChanged(CardGame game) async {
    bool moved = false;
    for (final Map<String, Object?> row in await table.fetch(game)) {
      if (await mergeRow(game, row)) moved = true;
    }
    return moved;
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
  ///
  /// Answers whether it wrote, so that whoever asked can tell a change that
  /// moved this collection from one that was already here.
  Future<bool> _merge(
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
      return true;
    }

    final CollectionEntry local = CollectionEntry.fromRow(existing.first);
    if (!AccountCollection.accountWins(local, row)) return false;
    await db.update(
      _local,
      payload,
      where: 'id = ?',
      whereArgs: <Object?>[existing.first['id']],
    );
    return true;
  }
}
