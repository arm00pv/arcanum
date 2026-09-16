// Tests for the cached catalogue: what a stored printing keeps, and what a
// search over it can find.
//
//   flutter test test/catalog/catalog_dao_test.dart
//
// The case these exist for is the same printing arriving twice in different
// states of completeness - once from a set download that knows its release date
// and its art, and again from a search hit that knows neither. Replacing
// blindly let the thinner record win and blank what was already known, which
// Pokémon hits hardest because TCGdex's card response carries no date at all.

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A printing as a set download delivers it: everything known.
TcgCard full({String name = 'Charizard'}) => TcgCard(
  game: CardGame.pokemon,
  id: 'base1-4',
  setCode: 'base1',
  setName: 'Base Set',
  name: name,
  collectorNumber: '4',
  rarity: 'Rare',
  typeLine: 'Pokémon - Stage 2',
  oracleText: 'Fire Spin: Discard 2 Energy cards attached to Charizard.',
  artist: 'Mitsuhiro Arita',
  colors: const <String>['Fire'],
  cmc: 120,
  imageUris: const <String, String>{
    'small': 'https://assets.tcgdex.net/en/base/base1/4/low.webp',
    'normal': 'https://assets.tcgdex.net/en/base/base1/4/high.webp',
  },
  prices: const TcgPrices(byFinish: <String, double?>{'holofoil': 869.02}),
  releasedAt: DateTime(1999, 1, 9),
  extras: const <String, Object?>{
    'variants': <String>['holofoil'],
  },
);

/// The same printing as a search hit or a stub arrives: name and number only.
TcgCard thin() => const TcgCard(
  game: CardGame.pokemon,
  id: 'base1-4',
  setCode: 'base1',
  setName: 'Base Set',
  name: 'Charizard',
  collectorNumber: '4',
  rarity: 'unknown',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late CatalogDao dao;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
  });

  tearDown(() async => db.close());

  group('a partial record never erases a fuller one', () {
    test('keeps the release date a search hit does not carry', () async {
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[thin()]);

      final stored = await dao.cardById(CardGame.pokemon, 'base1-4');

      expect(stored!.releasedAt, DateTime(1999, 1, 9));
    });

    test('keeps the rarity when the newcomer only says "unknown"', () async {
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[thin()]);

      final stored = await dao.cardById(CardGame.pokemon, 'base1-4');

      expect(stored!.rarity, 'Rare');
    });

    test('keeps the art, the rules and the variants', () async {
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[thin()]);

      final stored = await dao.cardById(CardGame.pokemon, 'base1-4');

      expect(
        stored!.imageUrl(size: 'normal'),
        'https://assets.tcgdex.net/en/base/base1/4/high.webp',
      );
      expect(stored.oracleText, contains('Discard 2 Energy cards'));
      expect(stored.typeLine, 'Pokémon - Stage 2');
      expect(stored.artist, 'Mitsuhiro Arita');
      expect(stored.colors, <String>['Fire']);
      expect(stored.cmc, 120);
      expect(stored.extras['variants'], <String>['holofoil']);
    });

    test('still writes everything the newcomer does know', () async {
      // The rule is about gaps, not about freezing a row: a fuller answer wins.
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[thin()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[
        full(name: 'Charizard '),
      ]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[
        full(name: 'Charizard'),
      ]);

      final stored = await dao.cardById(CardGame.pokemon, 'base1-4');

      expect(stored!.name, 'Charizard');
      expect(stored.releasedAt, DateTime(1999, 1, 9));
      expect(stored.prices.priceFor(CardFinish.holofoil), 869.02);
    });

    test('replaces prices even when the new answer quotes none', () async {
      // Prices are deliberately excluded from the merge: holding a stale quote
      // because today's answer was empty would show a price nobody stands
      // behind, and the price is the one field the user is looking at.
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[
        TcgCard(
          game: CardGame.pokemon,
          id: 'base1-4',
          setCode: 'base1',
          setName: 'Base Set',
          name: 'Charizard',
          collectorNumber: '4',
          rarity: 'Rare',
        ),
      ]);

      final stored = await dao.cardById(CardGame.pokemon, 'base1-4');

      expect(stored!.prices.priceFor(CardFinish.holofoil), isNull);
    });

    test('handles a batch mixing known and unknown printings', () async {
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full()]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[
        thin(),
        const TcgCard(
          game: CardGame.pokemon,
          id: 'base1-58',
          setCode: 'base1',
          setName: 'Base Set',
          name: 'Pikachu',
          collectorNumber: '58',
          rarity: 'unknown',
        ),
      ]);

      expect((await dao.cardById(CardGame.pokemon, 'base1-4'))!.rarity, 'Rare');
      expect(
        (await dao.cardById(CardGame.pokemon, 'base1-58'))!.name,
        'Pikachu',
      );
    });
  });

  group('sets whose provider publishes no card count', () {
    TcgSet set({int cardCount = 0}) => TcgSet(
      game: CardGame.lorcana,
      id: 'set_1',
      code: '1',
      name: 'The First Chapter',
      setType: 'expansion',
      cardCount: cardCount,
      releasedAt: DateTime(2023, 8, 18),
    );

    test(
      'counts a set as catalogued once anything from it is stored',
      () async {
        // Lorcast publishes no count anywhere in its set list, so a set would
        // otherwise be considered incomplete forever and re-downloaded on every
        // visit.
        await dao.upsertSets(CardGame.lorcana, <TcgSet>[set()]);
        expect(await dao.isCatalogued(CardGame.lorcana, '1'), isFalse);

        await dao.upsertCards(CardGame.lorcana, <TcgCard>[
          const TcgCard(
            game: CardGame.lorcana,
            id: 'crd_1',
            setCode: '1',
            setName: 'The First Chapter',
            name: 'Elsa – Snow Queen',
            collectorNumber: '41',
            rarity: 'Super Rare',
          ),
        ]);

        expect(await dao.isCatalogued(CardGame.lorcana, '1'), isTrue);
      },
    );

    test('records the size the card list turned out to have', () async {
      await dao.upsertSets(CardGame.lorcana, <TcgSet>[set()]);
      await dao.setCardCount(CardGame.lorcana, '1', 204);

      final stored = await dao.set(CardGame.lorcana, '1');

      expect(stored!.cardCount, 204);
    });

    test('never lowers a count a provider did publish', () async {
      // Magic and Pokémon do publish counts; a short card list must not shrink
      // the set's published size.
      await dao.upsertSets(CardGame.pokemon, <TcgSet>[
        TcgSet(
          game: CardGame.pokemon,
          id: 'base1',
          code: 'base1',
          name: 'Base Set',
          setType: 'expansion',
          cardCount: 102,
        ),
      ]);
      await dao.setCardCount(CardGame.pokemon, 'base1', 3);

      expect((await dao.set(CardGame.pokemon, 'base1'))!.cardCount, 102);
    });

    test('keeps the learned size when the set list refreshes', () async {
      // The set list is re-read every time the Sets tab opens, and for a
      // provider that publishes no count it arrives with a zero every time.
      await dao.upsertSets(CardGame.lorcana, <TcgSet>[set()]);
      await dao.setCardCount(CardGame.lorcana, '1', 226);
      await dao.upsertSets(CardGame.lorcana, <TcgSet>[set()]);

      expect((await dao.set(CardGame.lorcana, '1'))!.cardCount, 226);
    });

    test('takes a published count over a learned one', () async {
      // Pokémon does publish counts, and a corrected one must win.
      await dao.upsertSets(CardGame.pokemon, <TcgSet>[
        TcgSet(
          game: CardGame.pokemon,
          id: 'swsh1',
          code: 'swsh1',
          name: 'Sword & Shield',
          setType: 'expansion',
          cardCount: 202,
        ),
      ]);
      await dao.upsertSets(CardGame.pokemon, <TcgSet>[
        TcgSet(
          game: CardGame.pokemon,
          id: 'swsh1',
          code: 'swsh1',
          name: 'Sword & Shield',
          setType: 'expansion',
          cardCount: 216,
        ),
      ]);

      expect((await dao.set(CardGame.pokemon, 'swsh1'))!.cardCount, 216);
    });

    test('ignores a nonsense count', () async {
      await dao.upsertSets(CardGame.lorcana, <TcgSet>[set()]);
      await dao.setCardCount(CardGame.lorcana, '1', 0);

      expect((await dao.set(CardGame.lorcana, '1'))!.cardCount, 0);
    });
  });

  group('searching the cached catalogue', () {
    setUp(() async {
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[
        full(name: 'Charizard'),
        const TcgCard(
          game: CardGame.pokemon,
          id: 'base1-20',
          setCode: 'base1',
          setName: 'Base Set',
          name: 'Dragonair',
          collectorNumber: '20',
          rarity: 'Uncommon',
          oracleText: 'Discard a Fire Energy card to use this attack.',
        ),
        const TcgCard(
          game: CardGame.pokemon,
          id: 'base1-99',
          setCode: 'base1',
          setName: 'Base Set',
          name: 'Energy Removal',
          collectorNumber: '99',
          rarity: 'Common',
          oracleText: 'Discard 1 Energy card attached to your opponent.',
        ),
      ]);
    });

    test('finds cards by name', () async {
      final hits = await dao.searchCached(CardGame.pokemon, 'charizard');

      expect(hits.map((c) => c.name), contains('Charizard'));
    });

    test('finds cards by their rules text', () async {
      // The half of the promise the name index cannot keep: a query that is
      // not a card name still has to reach the cards that mention it.
      final hits = await dao.searchCached(CardGame.pokemon, 'discard');

      expect(
        hits.map((c) => c.name),
        containsAll(<String>['Dragonair', 'Energy Removal']),
      );
    });

    test('puts name matches above text matches', () async {
      final hits = await dao.searchCached(CardGame.pokemon, 'energy');

      // "Energy Removal" is a name match; the others only mention energy.
      expect(hits.first.name, 'Energy Removal');
    });

    test('is case-insensitive in both halves', () async {
      expect(
        await dao.searchCached(CardGame.pokemon, 'DRAGONAIR'),
        hasLength(1),
      );
      // All three mention discarding something, Charizard included.
      expect(await dao.searchCached(CardGame.pokemon, 'DISCARD'), hasLength(3));
    });

    test('answers nothing for a query that matches neither', () async {
      expect(await dao.searchCached(CardGame.pokemon, 'zzzz'), isEmpty);
      expect(await dao.searchCached(CardGame.pokemon, '   '), isEmpty);
    });

    test('never crosses games', () async {
      await dao.upsertCards(CardGame.mtg, <TcgCard>[
        const TcgCard(
          game: CardGame.mtg,
          id: 'mtg-1',
          setCode: 'blb',
          setName: 'Bloomburrow',
          name: 'Charizard',
          collectorNumber: '1',
          rarity: 'rare',
        ),
      ]);

      final pokemon = await dao.searchCached(CardGame.pokemon, 'charizard');

      expect(pokemon, hasLength(1));
      expect(pokemon.single.game, CardGame.pokemon);
    });
  });

  group('finding a set by the code on its box', () {
    setUp(() async {
      await dao.upsertSets(CardGame.digimon, <TcgSet>[
        TcgSet(
          game: CardGame.digimon,
          id: '24623',
          code: 'BT26',
          name: 'Timeless Bonds',
          setType: 'expansion',
          releasedAt: DateTime(2026, 9, 4),
        ),
        TcgSet(
          game: CardGame.digimon,
          id: '24865',
          code: 'BT27',
          name: 'Ignition of X',
          setType: 'expansion',
          releasedAt: DateTime(2026, 12, 11),
        ),
      ]);
    });

    test('the printed code finds the stored one', () async {
      // Digimon prints "BT-26"; the catalogue keeps "BT26".
      final hits = await dao.sets(CardGame.digimon, search: 'BT-26');

      expect(hits.map((s) => s.code), <String>['BT26']);
    });

    test('the stored form and the name still work', () async {
      expect(
        (await dao.sets(CardGame.digimon, search: 'bt26')).map((s) => s.code),
        <String>['BT26'],
      );
      expect(
        (await dao.sets(
          CardGame.digimon,
          search: 'Timeless',
        )).map((s) => s.code),
        <String>['BT26'],
      );
    });

    test('a code that is not there is still not there', () async {
      expect(await dao.sets(CardGame.digimon, search: 'BT-28'), isEmpty);
    });
  });

  group('a printing named by its number', () {
    TcgCard printing(String id, String set, String number, String name) =>
        TcgCard(
          game: CardGame.digimon,
          id: id,
          setCode: set,
          setName: set == 'BT26' ? 'Timeless Bonds' : 'Starter Deck 23',
          name: name,
          collectorNumber: number,
          rarity: 'common',
          releasedAt: DateTime(2026, 5, 15),
        );

    setUp(() async {
      await dao.upsertSets(CardGame.digimon, <TcgSet>[
        TcgSet(
          game: CardGame.digimon,
          id: '24623',
          code: 'BT26',
          name: 'Timeless Bonds',
          setType: 'expansion',
          releasedAt: DateTime(2026, 9, 4),
        ),
        TcgSet(
          game: CardGame.digimon,
          id: '24618',
          code: 'ST23',
          name: 'Starter Deck 23: Beatbreak',
          setType: 'starter',
          releasedAt: DateTime(2026, 5, 15),
        ),
      ]);
      await dao.upsertCards(CardGame.digimon, <TcgCard>[
        printing('bt26-001', 'BT26', '001', 'Yokomon'),
        printing('bt26-002', 'BT26', '002', 'Budmon'),
        printing('st23-01', 'ST23', '01', 'Kekkomon'),
      ]);
      // The same id in another game. Under the primary key this table had
      // before v14 that was one row, and the second write took the first row's
      // game column with it.
      await dao.upsertCards(CardGame.mtg, <TcgCard>[
        const TcgCard(
          game: CardGame.mtg,
          id: 'bt26-001',
          setCode: 'blb',
          setName: 'Bloomburrow',
          name: "Innkeeper's Talent",
          collectorNumber: '1',
          rarity: 'rare',
        ),
      ]);
    });

    test('the code as printed and the number find the printing', () async {
      final hits = await dao.searchByNumber(CardGame.digimon, 'BT-26-001');

      expect(hits!.map((c) => c.name), <String>['Yokomon']);
    });

    test('the code as stored finds it too', () async {
      expect(
        (await dao.searchByNumber(
          CardGame.digimon,
          'bt26-001',
        ))!.map((c) => c.name),
        <String>['Yokomon'],
      );
      // And with a space where the hyphen was.
      expect(
        (await dao.searchByNumber(
          CardGame.digimon,
          'BT26 001',
        ))!.map((c) => c.name),
        <String>['Yokomon'],
      );
    });

    test('a number on its own comes back from every set that has it', () async {
      // #001 and #01 are the same number written differently, and both are in
      // the game: the answer is both printings, each still labelled by its set.
      final hits = (await dao.searchByNumber(CardGame.digimon, '001'))!;

      expect(
        hits.map((c) => c.name),
        containsAll(<String>['Yokomon', 'Kekkomon']),
      );
      expect(hits.where((c) => c.name == 'Budmon'), isEmpty);
    });

    test('naming a set keeps the answer to that set', () async {
      final hits = (await dao.searchByNumber(CardGame.digimon, 'ST23-01'))!;

      expect(hits.map((c) => c.name), <String>['Kekkomon']);
    });

    test('the number is answered inside one game only', () async {
      final mtg = await dao.searchByNumber(CardGame.mtg, '001');

      expect(mtg!.map((c) => c.name), <String>["Innkeeper's Talent"]);
      expect(mtg.every((c) => c.game == CardGame.mtg), isTrue);

      final digimon = (await dao.searchByNumber(CardGame.digimon, '1'))!;
      expect(digimon.every((c) => c.game == CardGame.digimon), isTrue);
      expect(digimon.map((c) => c.name), contains('Yokomon'));
    });

    test('a number no set has answers nothing', () async {
      expect(await dao.searchByNumber(CardGame.digimon, 'BT26-999'), isEmpty);
    });

    test('a name is left to the name search', () async {
      // Null, not empty: the caller has to be able to tell "no such number"
      // from "that was never a number".
      expect(await dao.searchByNumber(CardGame.digimon, 'Kekkomon'), isNull);
      expect(await dao.searchByNumber(CardGame.digimon, 'Mewtwo 2'), isNull);
    });

    test('the same id in two games is two printings', () async {
      final digimon = await dao.cardById(CardGame.digimon, 'bt26-001');
      final mtg = await dao.cardById(CardGame.mtg, 'bt26-001');

      expect(digimon!.name, 'Yokomon');
      expect(digimon.game, CardGame.digimon);
      expect(mtg!.name, "Innkeeper's Talent");
      expect(mtg.game, CardGame.mtg);
    });
  });
}
