import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/alert_dao.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/repositories/alert_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A Magic printing priced at $10 non-foil, with a foil at $25.
TcgCard pricedCard({double nonfoil = 10.0, double foil = 25.0}) => TcgCard(
  game: CardGame.mtg,
  id: 'card-1',
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Test Card',
  collectorNumber: '1',
  rarity: 'rare',
  prices: TcgPrices(
    byFinish: {CardFinish.nonfoil.code: nonfoil, CardFinish.foil.code: foil},
  ),
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late AlertRepository repo;
  late CatalogDao catalog;
  late AlertDao alerts;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    catalog = CatalogDao(db.db);
    alerts = AlertDao(db.db);
    repo = AlertRepository(dao: alerts, catalogDao: catalog);
    await catalog.upsertCards(CardGame.mtg, [pricedCard()]);
  });

  tearDown(() async => db.close());

  test(
    'an absolute "above" alert fires only once the price passes it',
    () async {
      // Armed above $20 while the card sits at $10: armed, not firing.
      await repo.create(
        card: pricedCard(),
        kind: AlertKind.above,
        threshold: 20,
      );
      expect(await repo.triggeredCount(CardGame.mtg), 0);
      expect(await repo.evaluate(), isEmpty);

      // Price moves to $30; the same alert should now fire.
      await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 30)]);
      final fired = await repo.evaluate();
      expect(fired, hasLength(1));
      expect(fired.first.triggered, isTrue);
      expect(fired.first.current, 30.0);
      expect(fired.first.message, contains('above your'));
      expect(await repo.triggeredCount(CardGame.mtg), 1);

      // It must not fire twice.
      expect(await repo.evaluate(), isEmpty);
    },
  );

  test('a "below" alert fires on a drop', () async {
    await repo.create(card: pricedCard(), kind: AlertKind.below, threshold: 8);
    expect(await repo.evaluate(), isEmpty);

    await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 5)]);
    final fired = await repo.evaluate();
    expect(fired, hasLength(1));
    expect(fired.first.message, contains('below your'));
  });

  test(
    'a percentage alert measures against the price when it was armed',
    () async {
      // Armed at $10 with a +20% rule.
      await repo.create(
        card: pricedCard(),
        kind: AlertKind.percentUp,
        threshold: 20,
      );

      // +15% is not enough.
      await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 11.5)]);
      expect(await repo.evaluate(), isEmpty);

      // +25% is.
      await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 12.5)]);
      final fired = await repo.evaluate();
      expect(fired, hasLength(1));
      expect(fired.first.message, contains('Up 25%'));
    },
  );

  test('re-arming rebases the alert on the current price', () async {
    await repo.create(
      card: pricedCard(),
      kind: AlertKind.percentUp,
      threshold: 20,
    );
    await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 12.5)]);
    expect(await repo.evaluate(), hasLength(1));

    final alert = (await repo.all(CardGame.mtg)).single;
    expect(alert.isArmed, isFalse);
    expect(alert.baseline, 10.0);

    // Re-arm; the alert now watches from $20.
    await repo.rearm(alert, pricedCard(nonfoil: 12.5));
    final rearmed = (await repo.all(CardGame.mtg)).single;
    expect(rearmed.isArmed, isTrue);
    expect(rearmed.baseline, 12.5);
    expect(
      await repo.evaluate(),
      isEmpty,
      reason: 'a freshly re-armed alert must not fire immediately',
    );
  });

  test('alerts are scoped per game and never cross over', () async {
    await repo.create(card: pricedCard(), kind: AlertKind.above, threshold: 20);

    final pokemonCard = TcgCard(
      game: CardGame.pokemon,
      id: 'base1-4',
      setCode: 'base1',
      setName: 'Base Set',
      name: 'Charizard',
      collectorNumber: '4',
      rarity: 'Rare',
      prices: TcgPrices(byFinish: {CardFinish.holofoil.code: 869.02}),
    );
    await catalog.upsertCards(CardGame.pokemon, [pokemonCard]);
    await repo.create(
      card: pokemonCard,
      kind: AlertKind.above,
      threshold: 900,
      finish: CardFinish.holofoil,
    );

    expect(await repo.count(CardGame.mtg), 1);
    expect(await repo.count(CardGame.pokemon), 1);

    // Only the Magic side should fire, because only its price moved.
    await catalog.upsertCards(CardGame.mtg, [pricedCard(nonfoil: 40)]);
    final fired = await repo.evaluate();
    expect(fired, hasLength(1));
    expect(fired.first.alert.game, CardGame.mtg);

    // Evaluating a single game ignores the other entirely.
    expect(await repo.evaluate(games: [CardGame.pokemon]), isEmpty);
  });

  test('a card with no market price can never fire', () async {
    const unpriced = TcgCard(
      game: CardGame.mtg,
      id: 'card-2',
      setCode: 'tst',
      setName: 'Test Set',
      name: 'No Price',
      collectorNumber: '2',
      rarity: 'common',
    );
    await catalog.upsertCards(CardGame.mtg, [unpriced]);
    await repo.create(card: unpriced, kind: AlertKind.below, threshold: 100);

    expect(await repo.evaluate(), isEmpty);
    expect(await repo.triggeredCount(CardGame.mtg), 0);
  });

  test('progress climbs toward the target and describing reads naturally', () {
    final alert = PriceAlert(
      game: CardGame.mtg,
      cardId: 'c',
      kind: AlertKind.above,
      threshold: 20,
      createdAt: DateTime(2026, 1, 1),
      baseline: 10,
    );
    expect(alert.describe(), 'Price rises above 20.00');
    expect(alert.progress(10), 0.0);
    expect(alert.progress(15), closeTo(0.5, 0.001));
    expect(alert.progress(20), 1.0);
    expect(alert.progress(30), 1.0, reason: 'progress is clamped');

    final percent = PriceAlert(
      game: CardGame.mtg,
      cardId: 'c',
      kind: AlertKind.percentUp,
      threshold: 50,
      createdAt: DateTime(2026, 1, 1),
      baseline: 10,
    );
    expect(percent.progress(12.5), closeTo(0.5, 0.001));
    expect(percent.describe(), 'Price rises by 50%');
  });
}
