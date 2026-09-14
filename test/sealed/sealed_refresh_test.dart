// Refreshing the sealed shelf's prices.
//
//   flutter test test/sealed/sealed_refresh_test.dart
//
// The rule this file pins is that a refresh may only ever write a price the
// price list actually gave: no interpolation, no carrying a figure across from a
// similarly-named product, and no silence about the ones it could not price.

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/sealed_dao.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/data/sealed/sealed_refresh.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A price list that answers from a table of sets to products.
class FakeSource implements SealedPriceSource {
  FakeSource(this.bySet);

  final Map<String, List<SealedOffer>> bySet;

  /// Every set that was asked for, in order.
  final List<String> asked = <String>[];

  @override
  Future<List<SealedOffer>> forSet(CardGame game, String setCode) async {
    asked.add(setCode);
    return bySet[setCode] ?? const <SealedOffer>[];
  }
}

SealedOffer offer(String name, double? market, {String id = ''}) => SealedOffer(
  name: name,
  category: SealedCategory.guess(name),
  productId: id,
  market: market,
);

SealedHolding holding({
  int? id,
  String name = 'Bloomburrow Play Booster Display',
  String setCode = 'BLB',
  String productId = '541235',
  double? unitValue,
  int quantity = 1,
}) => SealedHolding(
  id: id,
  game: CardGame.mtg,
  setCode: setCode,
  setName: 'Bloomburrow',
  name: name,
  category: SealedCategory.guess(name),
  quantity: quantity,
  unitValue: unitValue,
  productId: productId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late SealedDao dao;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = SealedDao(db.db);
  });

  tearDown(() async => db.close());

  test(
    'writes the figure the price list gave, and the day it was seen',
    () async {
      final id = await dao.insert(holding(unitValue: 150));
      final source = FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[
          offer('Play Booster Display', 199.35, id: '541235'),
        ],
      });

      final SealedRefresh report = await refreshSealedPrices(
        game: CardGame.mtg,
        holdings: await dao.all(CardGame.mtg),
        source: source,
        dao: dao,
        now: DateTime(2026, 9, 14),
      );

      expect(report.setsAsked, 1);
      expect(report.priced, 1);
      expect(report.moved, 1);
      final SealedHolding saved = (await dao.byId(id))!;
      expect(saved.unitValue, 199.35);
      expect(saved.valueAsOf, DateTime(2026, 9, 14));
      expect(report.summary, contains('1 prices moved'));
    },
  );

  test('a figure that has not moved is not rewritten', () async {
    await dao.insert(holding(unitValue: 199.35));
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[
          offer('Play Booster Display', 199.35, id: '541235'),
        ],
      }),
      dao: dao,
    );

    expect(report.priced, 0);
    expect(report.unchanged, 1);
    expect(report.changedAnything, isFalse);
    expect(report.summary, contains('already current'));
  });

  test('a product the list does not carry keeps the figure it had', () async {
    final id = await dao.insert(holding(unitValue: 150, productId: '999'));
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[
          offer('Play Booster Display', 199.35, id: '541235'),
        ],
      }),
      dao: dao,
    );

    expect(report.unpriced, 1);
    expect(report.priced, 0);
    final SealedHolding saved = (await dao.byId(id))!;
    expect(saved.unitValue, 150, reason: 'nothing else could be written');
    expect(saved.valueAsOf, isNull);
    expect(report.summary, contains('not in the price list'));
  });

  test('a product with no price in the list is not priced at zero', () async {
    final id = await dao.insert(holding(unitValue: 150, productId: '541235'));
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[offer('Play Booster Display', null, id: '541235')],
      }),
      dao: dao,
    );

    expect(report.unpriced, 1);
    expect((await dao.byId(id))!.unitValue, 150);
  });

  test('something typed in by hand is matched by its exact name', () async {
    final id = await dao.insert(
      holding(name: 'My Own Box', setCode: 'BLB', productId: ''),
    );
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[offer('My Own Box', 42.5)],
      }),
      dao: dao,
      now: DateTime(2026, 9, 14),
    );

    expect(report.priced, 1);
    expect((await dao.byId(id))!.unitValue, 42.5);
  });

  test('a near miss on a name is not a match', () async {
    final id = await dao.insert(
      holding(name: 'My Own Box', setCode: 'BLB', productId: ''),
    );
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(<String, List<SealedOffer>>{
        'BLB': <SealedOffer>[offer('My Own Booster Box', 42.5)],
      }),
      dao: dao,
    );

    expect(report.unpriced, 1);
    expect((await dao.byId(id))!.unitValue, isNull);
  });

  test('every set on the shelf is asked for, once each', () async {
    await dao.insert(holding(setCode: 'BLB', productId: 'a'));
    await dao.insert(holding(setCode: 'BLB', productId: 'b', name: 'Second'));
    await dao.insert(holding(setCode: 'OTJ', productId: 'c', name: 'Third'));
    final source = FakeSource(<String, List<SealedOffer>>{
      'BLB': <SealedOffer>[
        offer('Play Booster Display', 199.35, id: 'a'),
        offer('Second', 10.0, id: 'b'),
      ],
      'OTJ': <SealedOffer>[offer('Third', 5.0, id: 'c')],
    });

    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: source,
      dao: dao,
    );

    expect(report.setsAsked, 2);
    expect(source.asked.toSet(), <String>{'BLB', 'OTJ'});
    expect(report.priced, 3);
  });

  test('a holding with no set is left alone rather than guessed at', () async {
    final id = await dao.insert(holding(setCode: '', productId: 'a'));
    final source = FakeSource(<String, List<SealedOffer>>{
      'BLB': <SealedOffer>[offer('Play Booster Display', 199.35, id: 'a')],
    });

    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: source,
      dao: dao,
    );

    expect(report.setsAsked, 0);
    expect(source.asked, isEmpty);
    expect((await dao.byId(id))!.unitValue, isNull);
    expect(report.summary, contains('nothing to look up'));
  });

  test('an unreachable companion prices nothing and says so', () async {
    // The real source answers an empty list rather than throwing, which is what
    // a sleeping server, a missing set and a bad set code all look like.
    final id = await dao.insert(holding(unitValue: 150));
    final SealedRefresh report = await refreshSealedPrices(
      game: CardGame.mtg,
      holdings: await dao.all(CardGame.mtg),
      source: FakeSource(const <String, List<SealedOffer>>{}),
      dao: dao,
    );

    expect(report.priced, 0);
    expect(report.unpriced, 1);
    expect((await dao.byId(id))!.unitValue, 150);
  });
}
