// The conflict rule for a deck, weighed without a database or a network.
//
//   flutter test test/data/account_deck_test.dart
//
// Two devices editing one deck offline is the case the whole shape exists for:
// one renames it while the other adds cards to it. A row-level clock cannot tell
// those two edits apart, so the merge reads a clock per field - and these tests
// are about that rule and the payloads it reads.

import 'package:arcanum/data/sync/account_deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deck row as this device's `decks` table stores it.
Map<String, Object?> localDeck({
  String syncId = 'a-b-c',
  String name = 'Krenko',
  String formatId = 'commander',
  String? notes,
  int createdAt = 1755000000000,
  int updatedAt = 1755000000000,
  int? nameAt,
  int? formatAt,
  int? notesAt,
  int? deletedAt,
}) => <String, Object?>{
  'id': 1,
  'game': 'mtg',
  'sync_id': syncId,
  'name': name,
  'format_id': formatId,
  'notes': notes,
  'created_at': createdAt,
  'updated_at': updatedAt,
  'name_at': nameAt,
  'format_at': formatAt,
  'notes_at': notesAt,
  'deleted_at': deletedAt,
};

void main() {
  group('a deck on its way to the account', () {
    test('carries the identity the account is keyed on', () {
      final row = AccountDeck.row(localDeck(syncId: 'deck-uuid'), CardGame.mtg);

      expect(row['sync_id'], 'deck-uuid');
      expect(row['game'], 'mtg');
      expect(row['name'], 'Krenko');
      expect(row['format_id'], 'commander');
    });

    test('never names the owner', () {
      // The column defaults to auth.uid(). A client that sent a user id could
      // send somebody else's, and the policy would have to catch what the
      // default makes impossible.
      expect(
        AccountDeck.row(localDeck(), CardGame.mtg).containsKey('user_id'),
        isFalse,
      );
    });

    test('a field and its clock travel together, null included', () {
      // The account writes an upsert as an update of the columns the payload
      // names, so a key left out means "leave what is there" - and what is there
      // for a deck being added back is the tombstone that would keep it deleted.
      // A clock left out is worse: the value would arrive with somebody else's
      // claim about when it was edited.
      final row = AccountDeck.row(localDeck(), CardGame.mtg);

      for (final String key in <String>[
        'name_at',
        'format_at',
        'notes_at',
        'deleted_at',
        'notes',
      ]) {
        expect(row.containsKey(key), isTrue, reason: key);
      }
      expect(row['name_at'], isNull);
      expect(row['deleted_at'], isNull);
    });

    test('a stamp travels as an instant', () {
      final row = AccountDeck.row(
        localDeck(
          nameAt: DateTime.utc(2026, 9, 10, 12).millisecondsSinceEpoch,
          deletedAt: DateTime.utc(2026, 9, 12, 9).millisecondsSinceEpoch,
        ),
        CardGame.mtg,
      );

      expect(row['name_at'], '2026-09-10T12:00:00.000Z');
      expect(row['deleted_at'], '2026-09-12T09:00:00.000Z');
    });

    test('a line names its deck by the identity that crosses the wire', () {
      final row = AccountDeck.line(
        <String, Object?>{
          'deck_id': 7,
          'card_id': 'goblin-chieftain',
          'board': 'main',
          'quantity': 4,
          'sort': 2,
          'category': '',
          'updated_at': 1755000000000,
          'deleted_at': null,
        },
        'deck-uuid',
        CardGame.mtg,
      );

      expect(row['deck_sync_id'], 'deck-uuid');
      expect(row['card_id'], 'goblin-chieftain');
      expect(row['quantity'], 4);
      expect(row['sort'], 2);
      expect(row['game'], 'mtg');
      // The local integer id means nothing to the account and must not travel.
      expect(row.containsKey('deck_id'), isFalse);
      expect(row.containsKey('user_id'), isFalse);
      expect(row['deleted_at'], isNull);
    });
  });

  group('two copies of one field', () {
    final DateTime now = DateTime.utc(2026, 9, 10, 12);

    test('the later edit wins', () {
      expect(
        AccountDeck.fieldWins(now, now.add(const Duration(hours: 1))),
        isTrue,
      );
      expect(
        AccountDeck.fieldWins(now, now.subtract(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('a tie goes to the account', () {
      // The account is the copy every device can see. Letting the local one win
      // a tie would leave two devices holding two answers to the same moment.
      expect(AccountDeck.fieldWins(now, now), isTrue);
    });

    test('a field nobody has edited loses to one that has', () {
      // Null is "never edited since v16", not "edited at the epoch". A deck that
      // predates the clocks therefore arrives at the account with whatever it has
      // and loses to any edit made since - which is the honest reading of a name
      // nobody has touched.
      expect(AccountDeck.fieldWins(null, now), isTrue);
      expect(AccountDeck.fieldWins(now, null), isFalse);
      expect(AccountDeck.fieldWins(null, null), isFalse);
    });
  });

  group('the mark on a deck', () {
    test('is resolved by the row clock, and a tie goes to the account', () {
      final DateTime now = DateTime.utc(2026, 9, 10, 12);

      expect(
        AccountDeck.rowWins(now, now.add(const Duration(minutes: 1))),
        isTrue,
        reason: 'a content edit after a deletion revives the deck',
      );
      expect(AccountDeck.rowWins(now, now), isTrue);
      expect(
        AccountDeck.rowWins(now, now.subtract(const Duration(minutes: 1))),
        isFalse,
        reason: 'the deletion is newer than this device has heard',
      );
    });

    test('and so is the mark on a line', () {
      final DateTime now = DateTime.utc(2026, 9, 10, 12);

      expect(AccountDeck.lineWins(now, now.add(const Duration(minutes: 1))), isTrue);
      expect(AccountDeck.lineWins(now, now), isTrue);
      expect(
        AccountDeck.lineWins(now, now.subtract(const Duration(minutes: 1))),
        isFalse,
      );
    });
  });

  group('a deck coming back from the account', () {
    test('round trips without losing anything', () {
      final DateTime edited = DateTime.utc(2026, 9, 10, 12);
      final RemoteDeck? deck = RemoteDeck.from(
        AccountDeck.row(
          localDeck(
            name: 'Krenko (v2)',
            notes: 'goblins',
            nameAt: edited.millisecondsSinceEpoch,
            notesAt: edited.millisecondsSinceEpoch,
          ),
          CardGame.mtg,
        ),
      );

      expect(deck, isNotNull);
      expect(deck!.syncId, 'a-b-c');
      expect(deck.name, 'Krenko (v2)');
      expect(deck.formatId, 'commander');
      expect(deck.notes, 'goblins');
      expect(deck.nameAt, edited);
      expect(deck.formatAt, isNull);
      expect(deck.deletedAt, isNull);
      expect(deck.updatedAt.toUtc(), DateTime.utc(2025, 8, 12, 12));
    });

    test('a row with no identity is not a deck', () {
      // The identity is the one field nothing can default: a row without one is
      // a row that cannot be matched, and inventing a deck out of it would put
      // somebody else's afternoon under a fresh name.
      expect(RemoteDeck.from(<String, Object?>{'name': 'Krenko'}), isNull);
      expect(RemoteDeck.from(<String, Object?>{'sync_id': ''}), isNull);
    });

    test('a line with no card id is not a line', () {
      expect(RemoteLine.from(<String, Object?>{'deck_sync_id': 'x'}), isNull);
      expect(
        RemoteLine.from(<String, Object?>{'card_id': 'x', 'deck_sync_id': ''}),
        isNull,
      );
    });

    test('a line arrives with its board and its mark', () {
      final RemoteLine? line = RemoteLine.from(<String, Object?>{
        'deck_sync_id': 'x',
        'card_id': 'goblin',
        'board': 'side',
        'quantity': 2,
        'sort': 1,
        'category': 'Ramp',
        'updated_at': '2026-09-10T12:00:00.000Z',
        'deleted_at': '2026-09-12T09:00:00.000Z',
      });

      expect(line!.board, 'side');
      expect(line.quantity, 2);
      expect(line.sort, 1);
      expect(line.category, 'Ramp');
      expect(line.deletedAt, DateTime.utc(2026, 9, 12, 9));
    });
  });
}
