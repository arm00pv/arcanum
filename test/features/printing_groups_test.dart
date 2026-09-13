import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/sets/printing_groups.dart';

TcgCard printing({
  required String id,
  String name = 'Blue-Eyes White Dragon',
  String number = '001',
  String rarity = 'Ultra Rare',
  double? price,
}) => TcgCard(
  game: CardGame.yugioh,
  id: id,
  setCode: 'lob',
  setName: 'Legend of Blue Eyes White Dragon',
  name: name,
  collectorNumber: number,
  rarity: rarity,
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{CardFinish.nonfoil.code: price}),
);

void main() {
  group('TcgCard.printingCode', () {
    test('reads the region code out of a Yu-Gi-Oh! id', () {
      // Three versions of one card, told apart only by this.
      expect(
        printing(id: '83764718:lob:lob-000:secret-rare').printingCode,
        'lob-000',
      );
      expect(
        printing(id: '83764718:lob:lob-e000:secret-rare').printingCode,
        'lob-e000',
      );
      expect(
        printing(id: '83764718:lob:lob-en000:secret-rare').printingCode,
        'lob-en000',
      );
    });

    test('is null for ids that are not shaped like one', () {
      // A Scryfall UUID, and a Pokemon id: neither carries a printing field.
      const scryfall = TcgCard(
        game: CardGame.mtg,
        id: 'f2b6a1c4-1f4e-4a3b-9c1d-2e3f4a5b6c7d',
        setCode: 'lea',
        setName: 'Limited Edition Alpha',
        name: 'Lightning Bolt',
        collectorNumber: '161',
        rarity: 'common',
      );
      expect(scryfall.printingCode, isNull);

      const pokemon = TcgCard(
        game: CardGame.pokemon,
        id: 'base1-4',
        setCode: 'base1',
        setName: 'Base',
        name: 'Charizard',
        collectorNumber: '4',
        rarity: 'Rare Holo',
      );
      expect(pokemon.printingCode, isNull);
    });

    test('is null when the field is empty or the passcode is not a number', () {
      expect(printing(id: '83764718:lob::secret-rare').printingCode, isNull);
      expect(
        printing(id: 'notapasscode:lob:lob-000:secret').printingCode,
        isNull,
      );
      expect(printing(id: '83764718:lob').printingCode, isNull);
    });
  });

  group('groupIntoSlots', () {
    test('collapses region variants of one card into a single slot', () {
      // The real LOB shape: same name, same number, three region codes.
      final slots = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: 54.11),
        printing(id: 'b', price: 93.53),
        printing(id: 'c', price: 4.68),
      ]);

      expect(slots, hasLength(1));
      expect(slots.single.versionCount, 3);
      expect(slots.single.hasVersions, isTrue);
      expect(slots.single.collectorNumber, '001');
    });

    test('keeps different numbers apart', () {
      final slots = groupIntoSlots(<TcgCard>[
        printing(id: 'a', number: '001', price: 1),
        printing(id: 'b', number: '002', price: 2),
      ]);

      expect(slots, hasLength(2));
      expect(slots.map((s) => s.collectorNumber), <String>['001', '002']);
      expect(slots.every((s) => s.versionCount == 1), isTrue);
      expect(slots.every((s) => s.hasVersions), isFalse);
    });

    test('keeps different cards at the same number apart', () {
      final slots = groupIntoSlots(<TcgCard>[
        printing(id: 'a', name: 'Blue-Eyes White Dragon', number: '001'),
        printing(id: 'b', name: 'Dark Magician', number: '001'),
      ]);

      expect(slots, hasLength(2));
    });

    test('matches a name that differs only in case and spacing', () {
      // Versions of one card share the card object's name, so this is not a
      // case the provider produces - it is here because normalisation is what
      // makes the grouping safe if it ever starts to.
      final slots = groupIntoSlots(<TcgCard>[
        printing(id: 'a', name: 'Blue-Eyes White Dragon'),
        printing(id: 'b', name: 'blue-eyes  white  dragon'),
      ]);

      expect(slots, hasLength(1));
    });

    test('preserves the order the set arrived in', () {
      final slots = groupIntoSlots(<TcgCard>[
        printing(id: 'a', number: '003'),
        printing(id: 'b', number: '001'),
        printing(id: 'c', number: '002'),
      ]);

      expect(slots.map((s) => s.collectorNumber), <String>[
        '003',
        '001',
        '002',
      ]);
    });

    test('handles an empty set', () {
      expect(groupIntoSlots(const <TcgCard>[]), isEmpty);
    });
  });

  group('slot prices', () {
    test('reports the range the versions span', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: 62.15),
        printing(id: 'b', price: 681.50),
        printing(id: 'c', price: 0.14),
      ]).single;

      expect(slot.lowestPrice, 0.14);
      expect(slot.highestPrice, 681.50);
      expect(slot.hasPriceSpread, isTrue);
    });

    test('orders the versions cheapest first', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: 62.15),
        printing(id: 'b', price: 0.14),
        printing(id: 'c', price: 681.50),
      ]).single;

      expect(slot.printings.map((c) => c.id), <String>['b', 'a', 'c']);
    });

    test('puts an unpriced version last, not first', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'free', price: null),
        printing(id: 'priced', price: 5),
      ]).single;

      // A version with no market data must never look like the cheapest one.
      expect(slot.printings.map((c) => c.id), <String>['priced', 'free']);
      expect(slot.lowestPrice, 5);
      expect(slot.highestPrice, 5);
      expect(slot.hasPriceSpread, isFalse);
    });

    test('opens the cheapest priced version by default', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'unpriced', price: null),
        printing(id: 'dear', price: 681.50),
        printing(id: 'cheap', price: 0.14),
      ]).single;

      expect(slot.primary.id, 'cheap');
    });

    test('falls back to the first printing when nothing is priced', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: null),
        printing(id: 'b', price: null),
      ]).single;

      expect(slot.primary.id, 'a');
      expect(slot.lowestPrice, isNull);
      expect(slot.highestPrice, isNull);
      expect(slot.hasPriceSpread, isFalse);
    });

    test('a single-version slot needs no range', () {
      final slot = groupIntoSlots(<TcgCard>[printing(id: 'a', price: 3)])
          .single;

      expect(slot.hasVersions, isFalse);
      expect(slot.hasPriceSpread, isFalse);
      expect(slot.lowestPrice, 3);
    });
  });

  group('ownedWith', () {
    test('sums every version of the slot', () {
      final slot = groupIntoSlots(<TcgCard>[
        printing(id: 'a'),
        printing(id: 'b'),
        printing(id: 'c'),
      ]).single;

      expect(slot.ownedWith(<String, int>{'a': 2, 'c': 1}), 3);
    });

    test('is zero when none of the versions are owned', () {
      final slot = groupIntoSlots(<TcgCard>[printing(id: 'a')]).single;
      expect(slot.ownedWith(<String, int>{}), 0);
    });
  });
}
