// Tests for the cost-basis ledger: what each purchase cost, and what each sale
// realised against it.
//
//   flutter test test/portfolio/cost_basis_test.dart
//
// These run against a real SQLite database in memory, because the arithmetic
// that matters here is the arithmetic that crosses the lots table, the
// collection and the sales table in one transaction.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/lots_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/domain/portfolio/realised.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CollectionDao collection;
  late LotsDao lots;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    collection = CollectionDao(db.db);
    lots = LotsDao(db.db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> buy(int quantity, double? price, DateTime on) =>
      collection.addOrMerge(
        game: CardGame.mtg,
        cardId: 'lea-161',
        finish: CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: quantity,
        purchasePrice: price,
        purchaseDate: on,
      );

  Future<CollectionEntry> stack(int id) async {
    final all = await collection.all(CardGame.mtg);
    return all.firstWhere((CollectionEntry e) => e.id == id);
  }

  group('buying', () {
    test('keeps each purchase as a lot of its own', () async {
      final id = await buy(4, 2, DateTime(2024, 1, 5));
      final secondId = await buy(4, 5, DateTime(2025, 2, 9));
      expect(secondId, id);

      final held = await lots.forCard(CardGame.mtg, 'lea-161');
      expect(held.map((CardLot l) => l.quantity), <int>[4, 4]);
      expect(held.map((CardLot l) => l.unitCost), <double>[2, 5]);
      expect(held.map((CardLot l) => l.acquiredOn), <DateTime>[
        DateTime(2024, 1, 5),
        DateTime(2025, 2, 9),
      ]);
      // The stack itself still carries the blended average, which is what the
      // valuation and the purchases screen read.
      expect((await stack(id)).purchasePrice, 3.5);
      expect((await stack(id)).quantity, 8);
    });

    test('keeps a purchase whose price was never recorded', () async {
      await buy(2, null, DateTime(2024, 1, 5));
      final held = await lots.forCard(CardGame.mtg, 'lea-161');
      expect(held.single.quantity, 2);
      expect(held.single.unitCost, isNull);
    });
  });

  group('selling', () {
    test(
      'comes out of the oldest purchase and realises the difference',
      () async {
        final id = await buy(4, 2, DateTime(2024, 1, 5));
        await buy(4, 5, DateTime(2025, 2, 9));

        final sale = await lots.recordSale(
          game: CardGame.mtg,
          entry: await stack(id),
          quantity: 5,
          unitPrice: 9,
          fees: 1,
          soldOn: DateTime(2025, 6, 1),
          platform: 'Cardmarket',
        );

        // Four from the two-dollar purchase, one from the five-dollar one.
        expect(sale.matches.map((LotMatch m) => m.quantity), <int>[4, 1]);
        expect(sale.cost, 13);
        expect(sale.proceeds, 44);
        expect(sale.gain, 31);
        expect(sale.costKnown, isTrue);

        // The stack and the lots moved together: three copies left, all of them
        // from the five-dollar purchase.
        final left = await stack(id);
        expect(left.quantity, 3);
        final held = await lots.forCard(CardGame.mtg, 'lea-161');
        expect(held.single.quantity, 3);
        expect(held.single.unitCost, 5);

        final ledger = await lots.sales(CardGame.mtg);
        expect(ledger.single.id, isNotNull);
        expect(ledger.single.gain, 31);
      },
    );

    test(
      'selling the whole stack removes it, and undo brings it back',
      () async {
        final id = await buy(2, 3, DateTime(2024, 4, 1));
        final sale = await lots.recordSale(
          game: CardGame.mtg,
          entry: await stack(id),
          quantity: 2,
          unitPrice: 6,
          soldOn: DateTime(2025, 1, 2),
        );

        expect(await collection.all(CardGame.mtg), isEmpty);
        expect(await lots.forCard(CardGame.mtg, 'lea-161'), isEmpty);
        expect(await lots.sales(CardGame.mtg), hasLength(1));

        await lots.undoSale(sale);

        final restored = await collection.all(CardGame.mtg);
        expect(restored.single.quantity, 2);
        expect(restored.single.cardId, 'lea-161');
        // The purchase comes back as the purchase it was, not as a fresh one.
        final held = await lots.forCard(CardGame.mtg, 'lea-161');
        expect(held.single.quantity, 2);
        expect(held.single.unitCost, 3);
        expect(held.single.acquiredOn, DateTime(2024, 4, 1));
        expect(await lots.sales(CardGame.mtg), isEmpty);
      },
    );

    test('refuses to sell more copies than the stack holds', () async {
      final id = await buy(2, 3, DateTime(2024, 4, 1));
      await expectLater(
        lots.recordSale(
          game: CardGame.mtg,
          entry: await stack(id),
          quantity: 3,
          unitPrice: 6,
          soldOn: DateTime(2025, 1, 2),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect((await stack(id)).quantity, 2);
      expect(await lots.sales(CardGame.mtg), isEmpty);
    });

    test(
      'reports no gain when the purchase price was never recorded',
      () async {
        final id = await buy(1, null, DateTime(2024, 4, 1));
        final sale = await lots.recordSale(
          game: CardGame.mtg,
          entry: await stack(id),
          quantity: 1,
          unitPrice: 20,
          soldOn: DateTime(2025, 1, 2),
        );

        expect(sale.proceeds, 20);
        expect(sale.cost, isNull);
        expect(sale.gain, isNull);
        expect(sale.costKnown, isFalse);
        // It still counts as a sale for the year, which is what the sheet says.
        final year = Realised.of(<SaleRow>[
          SaleRow(
            sale: sale,
            name: 'Lightning Bolt',
            setCode: 'lea',
            setName: 'Alpha',
          ),
        ]).year(2025)!;
        expect(year.sales, 1);
        expect(year.proceeds, 20);
        expect(year.unknownCost, 1);
      },
    );
  });

  group('editing a stack', () {
    test(
      'taking copies off the shelf disposes of them without a sale',
      () async {
        final id = await buy(3, 2, DateTime(2024, 1, 5));
        await buy(2, 4, DateTime(2025, 1, 5));

        await collection.setQuantity(id, 4);

        final held = await lots.forCard(CardGame.mtg, 'lea-161');
        // One copy came off the three-copy purchase, oldest first, which
        // leaves two of it and the two bought later.
        expect(held.map((CardLot l) => l.quantity), <int>[2, 2]);
        // Nothing was realised: the app was never told the copies were sold.
        expect(await lots.sales(CardGame.mtg), isEmpty);
      },
    );

    test('adding copies by hand becomes a lot at the stack price', () async {
      final id = await buy(1, 2, DateTime(2024, 1, 5));
      await collection.setQuantity(id, 3);

      final held = await lots.forCard(CardGame.mtg, 'lea-161');
      expect(held.map((CardLot l) => l.quantity), <int>[1, 2]);
      expect(held.last.unitCost, 2);
    });

    test('deleting a stack takes its purchases with it', () async {
      final id = await buy(2, 2, DateTime(2024, 1, 5));
      await collection.delete(id);

      expect(await lots.forCard(CardGame.mtg, 'lea-161'), isEmpty);
    });
  });

  group('the v11 migration', () {
    test('gives every existing stack the lot it already is', () async {
      // A v10 database: stacks with a blended price and no lots at all.
      final old = await AppDatabase.openInMemory();
      await old.db.insert('collection_entries', <String, Object?>{
        'game': 'mtg',
        'card_id': 'lea-161',
        'finish': 'nonfoil',
        'condition': 'near_mint',
        'language': 'en',
        'quantity': 4,
        'purchase_price': 2.5,
        'purchase_date': DateTime(2024, 3, 4).millisecondsSinceEpoch,
        'binder': '',
        'notes': null,
        'for_trade': 0,
        'created_at': 0,
        'updated_at': 0,
      });
      // The tables are dropped to model an older schema, then the migration is
      // asked for the same way the upgrader asks for it.
      await old.db.execute('DROP TABLE card_lots');
      await old.db.execute('DROP TABLE card_sales');

      await AppDatabase.createLotsAndSales(old.db, backfill: true);

      final held = LotsDao(old.db);
      final migrated = await held.forCard(CardGame.mtg, 'lea-161');
      expect(migrated.single.quantity, 4);
      expect(migrated.single.unitCost, 2.5);
      expect(migrated.single.acquiredOn, DateTime(2024, 3, 4));
      await old.close();
    });
  });
}
