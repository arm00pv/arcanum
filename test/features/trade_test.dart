// The trade pile: a flag on the stack, and what it implies.
//
//   flutter test test/features/trade_test.dart

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the trade pile', () {
    test('a new stack is not up for trade', () async {
      final db = await AppDatabase.openInMemory();
      final dao = CollectionDao(db.db);
      await dao.addOrMerge(
        game: CardGame.mtg,
        cardId: 'bolt',
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 4,
      );

      final entry = (await dao.forCard(CardGame.mtg, 'bolt')).single;

      expect(entry.forTrade, isFalse);
      await db.close();
    });

    test('marking a stack marks only that stack', () async {
      final db = await AppDatabase.openInMemory();
      final dao = CollectionDao(db.db);
      await dao.addOrMerge(
        game: CardGame.mtg,
        cardId: 'bolt',
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 4,
      );
      await dao.addOrMerge(
        game: CardGame.mtg,
        cardId: 'bolt',
        finish: CardFinish.foil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 1,
      );

      final before = await dao.forCard(CardGame.mtg, 'bolt');
      final foil = before.firstWhere((CollectionEntry e) => e.isFoil);
      await dao.setForTrade(foil.id!, true);

      final after = await dao.forCard(CardGame.mtg, 'bolt');
      expect(
        after.firstWhere((CollectionEntry e) => e.isFoil).forTrade,
        isTrue,
      );
      expect(
        after.firstWhere((CollectionEntry e) => !e.isFoil).forTrade,
        isFalse,
        reason: 'the four non-foils were never up for trade',
      );
      await db.close();
    });

    test('it can be taken back off', () async {
      final db = await AppDatabase.openInMemory();
      final dao = CollectionDao(db.db);
      final id = await dao.addOrMerge(
        game: CardGame.mtg,
        cardId: 'bolt',
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: 1,
      );

      await dao.setForTrade(id, true);
      await dao.setForTrade(id, false);

      expect(
        (await dao.forCard(CardGame.mtg, 'bolt')).single.forTrade,
        isFalse,
      );
      await db.close();
    });

    test('the flag survives a trip through the row mapper', () {
      // toRow/fromRow are how a restore writes entries back, so a flag that
      // does not survive them would be lost by the one feature it exists to
      // support.
      final entry = CollectionEntry(
        id: 7,
        cardId: 'bolt',
        forTrade: true,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

      final back = CollectionEntry.fromRow(entry.toRow());

      expect(back.forTrade, isTrue);
    });
  });
}
