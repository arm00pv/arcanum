// Sealed product: the model, the table it lives in, and the price list it reads.
//
//   flutter test test/sealed/sealed_test.dart

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/sealed_dao.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SealedHolding holding({
  int? id,
  String name = 'Bloomburrow Play Booster Display',
  String setCode = 'BLB',
  SealedCategory category = SealedCategory.boosterBox,
  int quantity = 1,
  double? unitCost,
  double? unitValue,
  String productId = '',
  String location = '',
}) => SealedHolding(
  id: id,
  game: CardGame.mtg,
  setCode: setCode,
  setName: 'Bloomburrow',
  name: name,
  category: category,
  quantity: quantity,
  unitCost: unitCost,
  unitValue: unitValue,
  productId: productId,
  location: location,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the kind of a sealed product', () {
    test('is read off the name a price list gives', () {
      expect(
        SealedCategory.guess('Bloomburrow Play Booster Display'),
        SealedCategory.boosterBox,
      );
      expect(
        SealedCategory.guess('Bloomburrow Play Booster Box'),
        SealedCategory.boosterBox,
      );
      expect(SealedCategory.guess('Bloomburrow Bundle'), SealedCategory.bundle);
      expect(
        SealedCategory.guess('Bloomburrow Play Booster Pack'),
        SealedCategory.boosterPack,
      );
      expect(
        SealedCategory.guess('Bloomburrow Commander Deck'),
        SealedCategory.deck,
      );
    });

    test('falls back to other rather than to a wrong guess', () {
      expect(SealedCategory.guess("Illumineer's Trove"), SealedCategory.other);
      expect(SealedCategory.guess(''), SealedCategory.other);
    });

    test('a box is not mistaken for a pack', () {
      // The order of the checks matters: 'booster pack' contains 'booster', and
      // a display contains the word box.
      expect(
        SealedCategory.guess('Collector Booster Box'),
        SealedCategory.boosterBox,
      );
      expect(
        SealedCategory.guess('Collector Booster Pack'),
        SealedCategory.boosterPack,
      );
    });

    test('survives a round trip through its stored id', () {
      for (final SealedCategory category in SealedCategory.values) {
        expect(SealedCategory.fromId(category.id), category);
      }
      expect(SealedCategory.fromId(null), SealedCategory.other);
      expect(SealedCategory.fromId('nonsense'), SealedCategory.other);
    });
  });

  group('adding a shelf up', () {
    test('counts quantity, value, cost and what nothing has priced', () {
      final SealedPortfolio p = SealedPortfolio.of(<SealedHolding>[
        holding(quantity: 2, unitValue: 199.35, unitCost: 150),
        holding(name: 'Bundle', quantity: 1, unitValue: 178.19),
        holding(name: 'Prerelease Pack', quantity: 3),
      ]);

      expect(p.totalItems, 6);
      expect(p.holdings.length, 3);
      expect(p.totalValue, closeTo(2 * 199.35 + 178.19, 1e-9));
      expect(p.totalCost, 300);
      // Counted in holdings, not in items: the question the screen answers is
      // how many rows nothing has priced, not how many boxes that is.
      expect(p.unpriced, 1, reason: 'one holding nothing has priced');
      expect(p.profit, closeTo(2 * 199.35 + 178.19 - 300, 1e-9));
    });

    test('a shelf with no recorded cost reports no cost, not zero', () {
      final SealedPortfolio p = SealedPortfolio.of(<SealedHolding>[
        holding(quantity: 1, unitValue: 199.35),
      ]);
      expect(p.totalCost, isNull);
      expect(p.profit, isNull);
    });

    test('an empty shelf adds up to nothing and says it is empty', () {
      final SealedPortfolio p = SealedPortfolio.of(const <SealedHolding>[]);
      expect(p.isEmpty, isTrue);
      expect(p.totalValue, 0);
      expect(p.totalItems, 0);
      expect(p.totalCost, isNull);
    });

    test('a holding can have its price cleared without losing its cost', () {
      final SealedHolding h = holding(unitCost: 100, unitValue: 120);
      final SealedHolding cleared = h.copyWith(clearUnitValue: true);
      expect(cleared.unitValue, isNull);
      expect(cleared.unitCost, 100);
      expect(cleared.totalValue, isNull);
      expect(cleared.totalCost, 100);
    });
  });

  group('the sealed table', () {
    late AppDatabase db;
    late SealedDao dao;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      dao = SealedDao(db.db);
    });

    tearDown(() async => db.close());

    test('stores and reads a holding back whole', () async {
      final int id = await dao.insert(
        holding(
          quantity: 2,
          unitCost: 150,
          unitValue: 199.35,
          productId: '541235',
          location: 'Top shelf',
        ),
      );
      final List<SealedHolding> all = await dao.all(CardGame.mtg);

      expect(all.length, 1);
      final SealedHolding saved = all.first;
      expect(saved.id, id);
      expect(saved.name, 'Bloomburrow Play Booster Display');
      expect(saved.setCode, 'BLB');
      expect(saved.category, SealedCategory.boosterBox);
      expect(saved.quantity, 2);
      expect(saved.unitCost, 150);
      expect(saved.unitValue, 199.35);
      expect(saved.productId, '541235');
      expect(saved.location, 'Top shelf');
      expect(saved.valueAsOf, isNull);
    });

    test('keeps the games apart', () async {
      await dao.insert(holding());
      await dao.insert(
        SealedHolding(
          game: CardGame.pokemon,
          setCode: 'sv3',
          setName: 'Obsidian Flames',
          name: 'Obsidian Flames Booster Bundle',
          category: SealedCategory.bundle,
          quantity: 1,
        ),
      );
      expect((await dao.all(CardGame.mtg)).length, 1);
      expect((await dao.all(CardGame.pokemon)).length, 1);
      expect(await dao.count(CardGame.lorcana), 0);
    });

    test('updates a holding in place', () async {
      final int id = await dao.insert(holding(quantity: 1, unitCost: 100));
      final SealedHolding saved = (await dao.byId(id))!;
      await dao.update(
        saved.copyWith(quantity: 4, unitCost: 90, location: 'Cupboard'),
      );

      final SealedHolding after = (await dao.byId(id))!;
      expect(after.quantity, 4);
      expect(after.unitCost, 90);
      expect(after.location, 'Cupboard');
      expect((await dao.all(CardGame.mtg)).length, 1);
    });

    test('deletes a holding', () async {
      final int id = await dao.insert(holding());
      await dao.delete(id);
      expect(await dao.all(CardGame.mtg), isEmpty);
      expect(await dao.byId(id), isNull);
    });

    test('counts physical products, not rows', () async {
      await dao.insert(holding(quantity: 3));
      await dao.insert(holding(name: 'Bundle', quantity: 2));
      expect(await dao.count(CardGame.mtg), 5);
    });

    test('a price reaches every holding of the same product', () async {
      await dao.insert(holding(quantity: 1, productId: '541235'));
      await dao.insert(
        holding(name: 'Second box', quantity: 2, productId: '541235'),
      );
      await dao.insert(holding(name: 'Something else', productId: '999'));

      final int touched = await dao.priceByProductId(
        game: CardGame.mtg,
        productId: '541235',
        unitValue: 210.5,
        asOf: DateTime(2026, 9, 14),
      );

      expect(touched, 2);
      final List<SealedHolding> all = await dao.all(CardGame.mtg);
      final List<SealedHolding> priced = all
          .where((SealedHolding h) => h.productId == '541235')
          .toList();
      for (final SealedHolding h in priced) {
        expect(h.unitValue, 210.5);
        expect(h.valueAsOf, DateTime(2026, 9, 14));
        final SealedHolding other = all.firstWhere(
          (SealedHolding h) => h.productId == '999',
        );
        expect(other.unitValue, isNull);
      }
    });

    test('a holding with no product id is never priced by id', () async {
      await dao.insert(holding(quantity: 1));
      final int touched = await dao.priceByProductId(
        game: CardGame.mtg,
        productId: '',
        unitValue: 10,
        asOf: DateTime(2026, 9, 14),
      );
      expect(touched, 0);
    });
  });

  group('reading a price list', () {
    test('takes names, prices and a category from the companion', () {
      final List<SealedOffer> offers = parseSealedOffers(<String, Object?>{
        'set': 'BLB',
        'setName': 'Bloomburrow',
        'updated': 1789360720,
        'products': <Object?>[
          <String, Object?>{
            'productId': 541235,
            'name': 'Bloomburrow Play Booster Display',
            'market': 199.35,
            'low': 190.0,
            'mid': 217.44,
          },
          <String, Object?>{
            'productId': 541234,
            'name': 'Bloomburrow Play Booster Pack',
            'market': 8.93,
            'low': 5.93,
            'mid': 8.2,
          },
        ],
      });

      expect(offers.length, 2);
      // Dearest first: the sheet shows the boxes before the packs.
      expect(offers.first.name, 'Bloomburrow Play Booster Display');
      expect(offers.first.category, SealedCategory.boosterBox);
      expect(offers.first.market, 199.35);
      expect(offers.first.productId, '541235');
      expect(offers.first.asOf, isNotNull);
      expect(offers.last.category, SealedCategory.boosterPack);
      expect(offers.last.isPriced, isTrue);
    });

    test('a product with no price is offered, unpriced', () {
      final List<SealedOffer> offers = parseSealedOffers(<String, Object?>{
        'products': <Object?>[
          <String, Object?>{'name': 'Some Master Case', 'market': null},
        ],
      });
      expect(offers.length, 1);
      expect(offers.first.isPriced, isFalse);
    });

    test('reads a body that arrived as text', () {
      // The companion answers JSON, but a proxy in front of it may not say so,
      // and a body that arrives as a string must still be understood.
      const String body =
          '{"products":[{"name":"A Booster Bundle","market":42.5}]}';
      final List<SealedOffer> offers = parseSealedOffers(body);
      expect(offers.length, 1);
      expect(offers.first.name, 'A Booster Bundle');
      expect(offers.first.market, 42.5);
    });

    test('junk is an empty list, never an exception', () {
      expect(parseSealedOffers(null), isEmpty);
      expect(parseSealedOffers('not json'), isEmpty);
      expect(parseSealedOffers(<Object?>[]), isEmpty);
      expect(parseSealedOffers(<String, Object?>{'products': 'nope'}), isEmpty);
      expect(
        parseSealedOffers(<String, Object?>{
          'products': <Object?>[
            <String, Object?>{'name': ''},
            'not a map',
          ],
        }),
        isEmpty,
      );
    });

    test('a price that is zero or nonsense is no price at all', () {
      final List<SealedOffer> offers = parseSealedOffers(<String, Object?>{
        'products': <Object?>[
          <String, Object?>{'name': 'One Box', 'market': 0},
          <String, Object?>{'name': 'Two Box', 'market': 'abc'},
          <String, Object?>{'name': 'Three Box', 'market': '12.50'},
        ],
      });
      final Map<String, double?> byName = <String, double?>{
        for (final SealedOffer o in offers) o.name: o.market,
      };
      expect(byName['One Box'], isNull);
      expect(byName['Two Box'], isNull);
      expect(byName['Three Box'], 12.5);
    });
  });
}
