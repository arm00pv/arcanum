import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/sync/account_collection.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:flutter_test/flutter_test.dart';

CollectionEntry holding({
  String cardId = 'lotus-1',
  CardFinish finish = CardFinish.nonfoil,
  CardCondition condition = CardCondition.nearMint,
  int quantity = 4,
  double? price,
  DateTime? bought,
  String binder = '',
  String? notes,
  bool forTrade = false,
  DateTime? updated,
}) => CollectionEntry(
  cardId: cardId,
  finish: finish,
  condition: condition,
  quantity: quantity,
  purchasePrice: price,
  purchaseDate: bought,
  binder: binder,
  notes: notes,
  forTrade: forTrade,
  createdAt: DateTime(2026, 9, 1),
  updatedAt: updated ?? DateTime(2026, 9, 10, 12),
);

void main() {
  group('a holding on its way to the account', () {
    test('carries the columns the unique index is built on', () {
      // The account decides whether two rows are the same holding from these
      // five values plus the owner, so they have to travel every time.
      final row = AccountCollection.row(holding(), CardGame.mtg);

      expect(row['game'], 'mtg');
      expect(row['card_id'], 'lotus-1');
      expect(row['finish'], 'nonfoil');
      expect(row['condition'], 'near_mint');
      expect(row['language'], 'en');
      expect(row['binder'], '');
    });

    test('never names the owner', () {
      // The column defaults to auth.uid(). A client that sent a user id could
      // send somebody else's, and the policy would have to catch what the
      // default makes impossible.
      expect(
        AccountCollection.row(holding(), CardGame.mtg).containsKey('user_id'),
        isFalse,
      );
    });

    test('a purchase date travels as a day, not a moment', () {
      // Buying a card on the 3rd is the 3rd wherever the collector is standing.
      final row = AccountCollection.row(
        holding(bought: DateTime(2026, 9, 3, 23, 30)),
        CardGame.mtg,
      );
      expect(row['purchase_date'], '2026-09-03');
    });

    test('an instant travels as UTC', () {
      final row = AccountCollection.row(
        holding(updated: DateTime.utc(2026, 9, 10, 12)),
        CardGame.mtg,
      );
      expect(row['updated_at'], '2026-09-10T12:00:00.000Z');
    });

    test('nothing absent is sent as an empty value', () {
      // A card bought for nothing and one bought for an unknown amount are
      // different facts, and the account keeps the difference.
      final row = AccountCollection.row(holding(), CardGame.mtg);
      expect(row.containsKey('purchase_price'), isFalse);
      expect(row.containsKey('purchase_date'), isFalse);
      expect(row.containsKey('notes'), isFalse);
    });
  });

  group('a holding coming back from the account', () {
    test('round trips without losing anything', () {
      final CollectionEntry before = holding(
        finish: CardFinish.foil,
        condition: CardCondition.played,
        quantity: 2,
        price: 12.5,
        bought: DateTime(2024, 3, 7),
        binder: 'Trade',
        notes: 'signed',
        forTrade: true,
      );

      final CollectionEntry? after = AccountCollection.entry(
        AccountCollection.row(before, CardGame.mtg),
      );

      expect(after, isNotNull);
      expect(after!.cardId, before.cardId);
      expect(after.finish, before.finish);
      expect(after.condition, before.condition);
      expect(after.quantity, before.quantity);
      expect(after.purchasePrice, before.purchasePrice);
      expect(after.purchaseDate, before.purchaseDate);
      expect(after.binder, before.binder);
      expect(after.notes, before.notes);
      expect(after.forTrade, isTrue);
    });

    test('a row with no card id is not a holding', () {
      // Better to bring nothing back than to invent a holding out of a row
      // that lost the one field nothing can default.
      expect(AccountCollection.entry(<String, Object?>{'quantity': 3}), isNull);
      expect(AccountCollection.entry(<String, Object?>{'card_id': ''}), isNull);
    });
  });

  group('two copies of one holding', () {
    test('the later edit wins', () {
      final CollectionEntry local = holding(
        updated: DateTime.utc(2026, 9, 10, 12),
      );

      expect(
        AccountCollection.accountWins(local, <String, Object?>{
          'updated_at': '2026-09-10T13:00:00.000Z',
        }),
        isTrue,
      );
      expect(
        AccountCollection.accountWins(local, <String, Object?>{
          'updated_at': '2026-09-10T11:00:00.000Z',
        }),
        isFalse,
      );
    });

    test('a tie goes to the account', () {
      // The account is the copy every device can see. Letting the local one win
      // a tie would leave two phones disagreeing about the same moment.
      final CollectionEntry local = holding(
        updated: DateTime.utc(2026, 9, 10, 12),
      );
      expect(
        AccountCollection.accountWins(local, <String, Object?>{
          'updated_at': '2026-09-10T12:00:00.000Z',
        }),
        isTrue,
      );
    });
  });
}
