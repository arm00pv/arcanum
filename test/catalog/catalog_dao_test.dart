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
      extras: const <String, Object?>{'variants': <String>['holofoil']},
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
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full(name: 'Charizard ')]);
      await dao.upsertCards(CardGame.pokemon, <TcgCard>[full(name: 'Charizard')]);

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

      expect(
        (await dao.cardById(CardGame.pokemon, 'base1-4'))!.rarity,
        'Rare',
      );
      expect(
        (await dao.cardById(CardGame.pokemon, 'base1-58'))!.name,
        'Pikachu',
      );
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

      expect(hits.map((c) => c.name),
          containsAll(<String>['Dragonair', 'Energy Removal']));
    });

    test('puts name matches above text matches', () async {
      final hits = await dao.searchCached(CardGame.pokemon, 'energy');

      // "Energy Removal" is a name match; the others only mention energy.
      expect(hits.first.name, 'Energy Removal');
    });

    test('is case-insensitive in both halves', () async {
      expect(await dao.searchCached(CardGame.pokemon, 'DRAGONAIR'),
          hasLength(1));
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
}
