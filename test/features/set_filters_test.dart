import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/sets/printing_groups.dart';
import 'package:arcanum/features/sets/set_filters.dart';

TcgCard printing({
  required String id,
  String name = 'Blue-Eyes White Dragon',
  String number = '001',
  String rarity = 'Ultra Rare',
  double? price,
  CardGame game = CardGame.yugioh,
}) => TcgCard(
  game: game,
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

/// The three versions of Blue-Eyes in Legend of Blue Eyes, and one cheap card.
List<PrintingSlot> slots() => groupIntoSlots(<TcgCard>[
  printing(id: 'a', price: 0.14),
  printing(id: 'b', price: 62.15),
  printing(id: 'c', price: 681.5),
  printing(
    id: 'd',
    name: 'Skull Servant',
    number: '002',
    rarity: 'Common',
    price: 0.2,
  ),
  printing(id: 'e', name: 'Dark Magician', number: '003', rarity: 'Super Rare'),
]);

PrintingSlot slotNamed(List<PrintingSlot> all, String name) =>
    all.firstWhere((slot) => slot.name == name);

void main() {
  group('PriceWindow', () {
    test('is half open, so a band boundary belongs to one band only', () {
      const under = PriceWindow(max: 1);
      expect(under.contains(0.99), isTrue);
      // Exactly one dollar is in "$1 - $5", not in "Under $1" as well.
      expect(under.contains(1), isFalse);

      const low = PriceWindow(min: 1, max: 5);
      expect(low.contains(1), isTrue);
      expect(low.contains(4.99), isTrue);
      expect(low.contains(5), isFalse);
    });

    test('leaves unpriced cards out unless it is asked for them', () {
      final dark = slotNamed(slots(), 'Dark Magician');
      expect(const PriceWindow(min: 0).matches(dark), isFalse);
      expect(const PriceWindow(unpriced: true).matches(dark), isTrue);
      expect(const PriceWindow(min: 0, unpriced: true).matches(dark), isTrue);
    });

    test('matches a slot when any of its versions falls inside', () {
      final blueEyes = slotNamed(slots(), 'Blue-Eyes White Dragon');
      expect(const PriceWindow(max: 1).matches(blueEyes), isTrue);
      expect(const PriceWindow(min: 100).matches(blueEyes), isTrue);
      expect(const PriceWindow(min: 1, max: 5).matches(blueEyes), isFalse);
    });

    test('knows when it constrains nothing', () {
      expect(const PriceWindow().isEmpty, isTrue);
      expect(const PriceWindow(unpriced: true).isEmpty, isFalse);
      expect(const PriceWindow(max: 1).hasNumberBound, isTrue);
    });
  });

  group('PriceBand', () {
    test('round trips through matching', () {
      for (final band in PriceBand.values) {
        expect(PriceBand.matching(band.window), band);
      }
      expect(PriceBand.matching(const PriceWindow(min: 2, max: 7)), isNull);
    });

    test('covers every price exactly once', () {
      const prices = <double>[
        0.01,
        0.99,
        1,
        4.99,
        5,
        19.99,
        20,
        99.99,
        100,
        681.5,
      ];
      for (final price in prices) {
        final hits = PriceBand.values
            .where((band) => band.window.contains(price))
            .toList();
        expect(hits.length, 1, reason: 'price $price landed in $hits');
      }
    });

    test('keeps the unpriced band separate from the numeric ones', () {
      final all = slots();
      final unpriced = all.where(PriceBand.unpriced.window.matches).toList();
      expect(unpriced.map((slot) => slot.name), <String>['Dark Magician']);
      for (final band in PriceBand.values.where((b) => b.hasNumericWindow)) {
        expect(
          all
              .where(band.window.matches)
              .any((slot) => slot.name == 'Dark Magician'),
          isFalse,
          reason: '${band.label} claimed an unpriced card',
        );
      }
    });
  });

  group('SetFilter', () {
    test('does nothing until it is asked to', () {
      const filter = SetFilter();
      expect(filter.isActive, isFalse);
      expect(filter.activeCount, 0);
      expect(filter.apply(slots()).map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
        'Skull Servant',
        'Dark Magician',
      ]);
    });

    test('counts each live control', () {
      const filter = SetFilter(
        price: PriceWindow(max: 1),
        rarities: <String>{'Common'},
        sort: SetSort.priceLow,
      );
      expect(filter.isActive, isTrue);
      expect(filter.activeCount, 3);
      expect(filter.filtersPrice, isTrue);
      expect(const SetFilter(price: PriceWindow()).filtersPrice, isFalse);
    });

    test('narrows to a price band', () {
      final cheaps = const SetFilter(price: PriceWindow(max: 1)).apply(slots());
      expect(cheaps.map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
        'Skull Servant',
      ]);

      final dears = const SetFilter(price: PriceWindow(min: 100))
          .apply(slots());
      expect(dears.map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
      ]);
    });

    test('narrows to rarities without collapsing them onto a tier', () {
      // Yu-Gi-Oh! prints Ultra and Super Rare in the same set, and both resolve
      // to one display tier: the filter has to keep them apart.
      final ultra = const SetFilter(rarities: <String>{'Ultra Rare'})
          .apply(slots());
      expect(ultra.map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
      ]);

      final both = const SetFilter(
        rarities: <String>{'Ultra Rare', 'Super Rare'},
      ).apply(slots());
      expect(both.map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
        'Dark Magician',
      ]);
    });

    test('combines price and rarity', () {
      const filter = SetFilter(
        price: PriceWindow(max: 1),
        rarities: <String>{'Common'},
      );
      expect(filter.apply(slots()).map((slot) => slot.name), <String>[
        'Skull Servant',
      ]);
    });

    test('orders by price with unpriced cards always last', () {
      final priced = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: 1),
        printing(id: 'b', name: 'Skull Servant', number: '002', price: 9),
        printing(id: 'c', name: 'Dark Magician', number: '003'),
      ]);

      expect(
        const SetFilter(sort: SetSort.priceLow)
            .apply(priced)
            .map((s) => s.name),
        <String>['Blue-Eyes White Dragon', 'Skull Servant', 'Dark Magician'],
      );
      expect(
        const SetFilter(sort: SetSort.priceHigh)
            .apply(priced)
            .map((s) => s.name),
        <String>['Skull Servant', 'Blue-Eyes White Dragon', 'Dark Magician'],
      );
    });

    test('orders by the price the filter leaves on show', () {
      // Blue-Eyes has a 14-cent version, so unfiltered it is the cheapest thing
      // in the set; under "\$100 and up" that version is hidden and the card is
      // the dearest on screen, which is where it has to sort.
      const dear = SetFilter(
        price: PriceWindow(min: 100),
        sort: SetSort.priceLow,
      );
      expect(dear.apply(slots()).map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
      ]);

      final two = groupIntoSlots(<TcgCard>[
        printing(id: 'a', price: 0.14),
        printing(id: 'b', price: 681.5),
        printing(
          id: 'c',
          name: 'Red-Eyes Black Dragon',
          number: '002',
          price: 200,
        ),
      ]);
      expect(dear.apply(two).map((slot) => slot.name), <String>[
        'Red-Eyes Black Dragon',
        'Blue-Eyes White Dragon',
      ]);
      expect(
        const SetFilter(
          price: PriceWindow(min: 100),
          sort: SetSort.priceHigh,
        ).apply(two).map((slot) => slot.name),
        <String>['Blue-Eyes White Dragon', 'Red-Eyes Black Dragon'],
      );
    });

    test('orders by name, using the number to break ties', () {
      final sorted = const SetFilter(sort: SetSort.name).apply(slots());
      expect(sorted.map((slot) => slot.name), <String>[
        'Blue-Eyes White Dragon',
        'Dark Magician',
        'Skull Servant',
      ]);
    });

    test('headlines the prices the filter leaves on show', () {
      final blueEyes = slotNamed(slots(), 'Blue-Eyes White Dragon');
      const unfiltered = SetFilter();
      expect(unfiltered.summarise(blueEyes).low, 0.14);
      expect(unfiltered.summarise(blueEyes).high, 681.5);
      expect(unfiltered.summarise(blueEyes).hasSpread, isTrue);

      // With the top band on, the tile must not still read "from $0.14".
      const dear = SetFilter(price: PriceWindow(min: 100));
      final windowed = dear.summarise(blueEyes);
      expect(windowed.low, 681.5);
      expect(windowed.high, 681.5);
      expect(windowed.hasSpread, isFalse);
    });

    test('falls back to the slot when a window hides every price', () {
      final dark = slotNamed(slots(), 'Dark Magician');
      expect(
        const SetFilter(price: PriceWindow(unpriced: true)).summarise(dark).low,
        isNull,
      );
    });

    test('copies itself without losing the other controls', () {
      const filter = SetFilter(
        rarities: <String>{'Common'},
        sort: SetSort.name,
      );
      final repriced = filter.withPrice(const PriceWindow(max: 1));
      expect(repriced.rarities, <String>{'Common'});
      expect(repriced.sort, SetSort.name);
      expect(repriced.price, const PriceWindow(max: 1));

      final toggled = filter.toggleRarity('Super Rare');
      expect(toggled.rarities, <String>{'Common', 'Super Rare'});
      expect(toggled.toggleRarity('Common').rarities, <String>{'Super Rare'});
      expect(filter.withSort(SetSort.priceLow).sort, SetSort.priceLow);
    });

    test('compares equal whatever order the rarities were picked in', () {
      const a = SetFilter(rarities: <String>{'Common', 'Ultra Rare'});
      const b = SetFilter(rarities: <String>{'Ultra Rare', 'Common'});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const SetFilter(rarities: <String>{'Common'}), isFalse);
    });
  });

  group('rarityFacets', () {
    test('counts the printings behind each rarity, commonest first', () {
      final facets = rarityFacets(slots());
      // Ties are broken alphabetically, so the same set always lists its
      // rarities in the same order.
      expect(facets.map((f) => f.rarity), <String>[
        'Ultra Rare',
        'Common',
        'Super Rare',
      ]);
      expect(facets.first.count, 3);
      expect(facets.map((f) => f.count), <int>[3, 1, 1]);
    });

    test('offers nothing for a set with no cards', () {
      expect(rarityFacets(const <PrintingSlot>[]), isEmpty);
    });
  });

  group('rarityLabel', () {
    test('tidies the provider spellings', () {
      expect(rarityLabel('mythic'), 'Mythic');
      expect(rarityLabel('Ultra Rare'), 'Ultra Rare');
      expect(rarityLabel('rare_holo'), 'Rare Holo');
      expect(rarityLabel('  '), 'Unknown');
    });
  });

  group('describePrice', () {
    test('names a band when the window is one', () {
      expect(describePrice(null), 'Any price');
      expect(describePrice(const PriceWindow()), 'Any price');
      expect(describePrice(PriceBand.top.window), r'$100+');
      expect(describePrice(PriceBand.unpriced.window), 'No price');
    });

    test('spells out a custom range as money', () {
      expect(
        describePrice(const PriceWindow(min: 2, max: 7)),
        r'$2.00 - $7.00',
      );
      expect(describePrice(const PriceWindow(min: 20)), r'$20.00 - Any');
    });
  });

  group('niceCeil', () {
    test('rounds a slider top up to a number worth aiming at', () {
      expect(niceCeil(0), 1);
      expect(niceCeil(0.5), 1);
      expect(niceCeil(3.2), 5);
      expect(niceCeil(14), 20);
      expect(niceCeil(92), 100);
      expect(niceCeil(100), 100);
      expect(niceCeil(681.5), 1000);
    });
  });
}
