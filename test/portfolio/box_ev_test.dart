import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard card(String id, String rarity, [double? price]) => TcgCard(
  game: CardGame.mtg,
  id: id,
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Card $id',
  collectorNumber: id,
  rarity: rarity,
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{'nonfoil': price}),
);

SealedHolding box({
  String setCode = 'tst',
  String name = 'Test Set Booster Box',
  int quantity = 1,
  double? unitValue = 100,
  double? unitCost,
  SealedCategory category = SealedCategory.boosterBox,
}) => SealedHolding(
  game: CardGame.mtg,
  setCode: setCode,
  setName: 'Test Set',
  name: name,
  category: category,
  quantity: quantity,
  unitValue: unitValue,
  unitCost: unitCost,
);

void main() {
  group('the composition says what a box holds', () {
    test('the shops own words give the size of a box', () {
      const blurb =
          '1 Box contains 24 Booster. Each Chromatic Ascension Booster Pack '
          'contains 12 cards.';
      final composition = BoxComposition.fromDescription(blurb);
      expect(composition, isNotNull);
      expect(composition!.packs, 24);
      expect(composition.cardsPerPack, 12);
      expect(composition.promised, 288);
    });

    test('markup and a stray sentence do not hide the numbers', () {
      final composition = BoxComposition.fromDescription(
        '<p>A box of Magic: The Gathering.</p><p>1 Box contains 36 packs.'
        '</p><p>Each pack contains 15 cards.</p>',
      );
      expect(composition!.packs, 36);
      expect(composition.cardsPerPack, 15);
    });

    test('a case of boxes is not read as a box', () {
      expect(
        BoxComposition.fromDescription(
          '1 Box contains 12 Ultimate Advent Booster Boxes.',
        ),
        isNull,
      );
    });

    test('a real listing is read as the list it is', () {
      // The Bloomburrow Play Booster Display, as the price list publishes it:
      // a heading, a bullet list, and a rarity spread that reads like a count
      // if the parser is careless. This exact text is what the app once turned
      // into 'the shop says 4 cards a pack'.
      const String listing =
          "Plus, they're a thrilling pack-opening experience, providing "
          'players the opportunity to snag multiple Rare cards or even a '
          'possible Booster Fun treatment.<br><br>Bloomburrow - Play Booster '
          'Box contains:<br>• 36 Magic: The Gathering—Bloomburrow Play Booster '
          'Packs; each Play Booster Pack contains:<br>• 14 Magic: The '
          'Gathering cards<br>• 1-4 cards of rarity Rare of higher<br>'
          '• 3-5 Uncommon cards<br>• 6-9 Common cards<br>• 1 Land';

      final composition = BoxComposition.fromDescription(listing);
      expect(composition, isNotNull);
      expect(composition!.packs, 36);
      expect(composition.cardsPerPack, 14);
    });

    test('a rarity spread is not a count', () {
      // '1-4 cards of rarity Rare or higher' is a range, and the only number
      // in it that looks like a count is the wrong one.
      final composition = BoxComposition.fromDescription(
        'Each Play Booster Pack contains: 14 Magic: The Gathering cards, '
        '1-4 cards of rarity Rare or higher, 3-5 Uncommon cards.',
      );
      expect(composition!.cardsPerPack, 14);
    });

    test('a pack with no box still says what a pack holds', () {
      final composition = BoxComposition.fromDescription(
        'Each Booster Pack contains 12 cards.',
      );
      expect(composition!.packs, 0);
      expect(composition.cardsPerPack, 12);
      expect(composition.promised, 0);
    });

    test('a description with neither number is not a composition', () {
      expect(BoxComposition.fromDescription('Sealed booster box.'), isNull);
      expect(BoxComposition.fromDescription(''), isNull);
      expect(BoxComposition.fromDescription(null), isNull);
    });
  });

  group('a composition adds up or says it does not', () {
    const whole = BoxComposition(
      packs: 24,
      cardsPerPack: 12,
      slots: <BoxSlot>[BoxSlot(CardRarity.common, 240)],
    );

    test('cards, promised and whole', () {
      expect(whole.cards, 240);
      expect(whole.promised, 288);
      expect(whole.isWhole, isFalse);
      expect(BoxComposition.none.isEmpty, isTrue);
    });

    test('setting a tier drops it at zero and keeps tier order', () {
      final built = BoxComposition.none
          .withSize(packs: 24, cardsPerPack: 12)
          .withSlot(CardRarity.rare, 6)
          .withSlot(CardRarity.common, 200)
          .withSlot(CardRarity.rare, 0);
      expect(built.slots, const <BoxSlot>[BoxSlot(CardRarity.common, 200)]);
      expect(built.countOf(CardRarity.rare), 0);
      expect(built.isWhole, isFalse);
    });

    test('a composition survives being stored', () {
      const BoxComposition composition = BoxComposition(
        packs: 30,
        cardsPerPack: 14,
        slots: <BoxSlot>[
          BoxSlot(CardRarity.common, 200),
          BoxSlot(CardRarity.uncommon, 108),
          BoxSlot(CardRarity.rare, 30),
          BoxSlot(CardRarity.mythic, 4),
        ],
      );
      final round = BoxComposition.fromJson(composition.toJson());
      expect(round.packs, 30);
      expect(round.cardsPerPack, 14);
      expect(round.slots, composition.slots);
      expect(round.countOf(CardRarity.mythic), 4);
      expect(round.isWhole, isFalse, reason: '342 slots, 420 promised');
    });

    test('a stored composition with junk in it keeps what it can read', () {
      final round = BoxComposition.fromJson(<String, Object?>{
        'packs': 36,
        'cardsPerPack': 14,
        'slots': <Object?>[
          <String, Object?>{'rarity': 'rare', 'count': 30},
          <String, Object?>{'rarity': 'nonsense', 'count': 5},
          <String, Object?>{'rarity': 'common', 'count': -2},
        ],
      });
      expect(round.packs, 36);
      expect(round.slots, const <BoxSlot>[BoxSlot(CardRarity.rare, 30)]);
    });
  });

  group('what a box is worth opened', () {
    final cards = <TcgCard>[
      card('c1', 'common', 0.10),
      card('c2', 'common', 0.20),
      card('c3', 'common', 0.30),
      card('r1', 'rare', 1.00),
      card('m1', 'mythic'),
    ];
    const composition = BoxComposition(
      packs: 4,
      cardsPerPack: 5,
      slots: <BoxSlot>[
        BoxSlot(CardRarity.common, 10),
        BoxSlot(CardRarity.rare, 2),
        BoxSlot(CardRarity.mythic, 1),
      ],
    );

    test('each tier is worth its mean, and an unpriced tier is not zero', () {
      final ev = BoxEv.of(
        cards: cards,
        composition: composition,
        boxPrice: 100,
      );
      final commons = ev.tiers.firstWhere(
        (BoxTierLine line) => line.rarity == CardRarity.common,
      );
      expect(commons.count, 10);
      expect(commons.priced, 3);
      expect(commons.inSet, 3);
      expect(commons.mean, closeTo(0.20, 0.0001));
      expect(commons.cheapest, 0.10);
      expect(commons.dearest, 0.30);
      expect(commons.subtotal, closeTo(2.0, 0.0001));

      final mythics = ev.tiers.firstWhere(
        (BoxTierLine line) => line.rarity == CardRarity.mythic,
      );
      expect(mythics.count, 1);
      expect(mythics.mean, isNull);
      expect(mythics.subtotal, isNull);
      expect(mythics.isUnpriced, isTrue);

      expect(ev.expected, closeTo(4.0, 0.0001));
      expect(ev.complete, isFalse);
      expect(ev.pricedCards, 4);
      expect(ev.unpricedCards, 1);
    });

    test('the ceiling is every card at the sets own mean', () {
      final ev = BoxEv.of(cards: cards, composition: composition);
      expect(ev.ceiling, closeTo(0.40 * 13, 0.0001));
      expect(ev.boxPrice, isNull);
      expect(ev.ratio, isNull);
      expect(ev.surplus, isNull);
    });

    test('the answer is put against what the box costs', () {
      final ev = BoxEv.of(
        cards: cards,
        composition: composition,
        boxPrice: 100,
      );
      expect(ev.perPack, closeTo(1.0, 0.0001));
      expect(ev.ratio, closeTo(0.04, 0.0001));
      expect(ev.surplus, closeTo(-96.0, 0.0001));
      expect(ev.isComputable, isTrue);
    });

    test('the dearest cards are ranked, with the box as the yardstick', () {
      final ev = BoxEv.of(cards: cards, composition: composition, boxPrice: 1);
      expect(ev.chase.first.card.id, 'r1');
      expect(ev.chase.first.price, 1.00);
      expect(ev.chase.first.versusBox, closeTo(1.0, 0.0001));
      expect(ev.chase.length, 4);
    });

    test('a set nobody quotes is not a box worth nothing', () {
      final ev = BoxEv.of(
        cards: <TcgCard>[card('u1', 'rare')],
        composition: composition,
        boxPrice: 100,
      );
      expect(ev.expected, 0);
      expect(ev.ceiling, isNull);
      expect(ev.isComputable, isFalse);
      expect(ev.complete, isFalse);
      expect(ev.chase, isEmpty);
    });

    test('a composition of nothing is not computable either', () {
      final ev = BoxEv.of(cards: cards, composition: BoxComposition.none);
      expect(ev.isComputable, isFalse);
      expect(ev.perPack, isNull);
    });
  });
  group('a shelf of boxes, valued both ways', () {
    const BoxComposition composition = BoxComposition(
      packs: 4,
      cardsPerPack: 5,
      slots: <BoxSlot>[
        BoxSlot(CardRarity.common, 10),
        BoxSlot(CardRarity.rare, 2),
      ],
    );
    final Map<String, BoxComposition> stated = <String, BoxComposition>{
      'tst': composition,
    };
    final Map<String, List<TcgCard>> downloaded = <String, List<TcgCard>>{
      'tst': <TcgCard>[
        card('c1', 'common', 0.10),
        card('c2', 'common', 0.30),
        card('r1', 'rare', 1.00),
      ],
    };

    // 10 commons at a mean of 0.20 plus 2 rares at 1.00.
    const double openedEach = 4.0;

    test('both sides are added up over the boxes they are known for', () {
      final shelf = BoxShelf.of(
        holdings: <SealedHolding>[
          box(quantity: 2, unitValue: 100),
          box(setCode: 'other', name: 'Undownloaded Box', unitValue: 50),
        ],
        compositions: stated,
        cards: downloaded,
      );

      expect(shelf.boxes, 3);
      expect(shelf.openedCount, 1);
      expect(shelf.opened, closeTo(openedEach * 2, 0.0001));
      expect(shelf.sealedCount, 2);
      expect(shelf.sealed, closeTo(250, 0.0001));
      // Only one box has both sides, so only that one is comparable.
      expect(shelf.bothCount, 1);
      expect(shelf.sealedBoth, closeTo(200, 0.0001));
      expect(shelf.openedBoth, closeTo(8.0, 0.0001));
      expect(shelf.difference, closeTo(-192.0, 0.0001));
      expect(shelf.openingPays, isFalse);
      expect(shelf.hasAnswer, isTrue);
    });

    test('a box with no composition says so, and is not counted as zero', () {
      final shelf = BoxShelf.of(
        holdings: <SealedHolding>[box(setCode: 'unstated')],
        compositions: stated,
        cards: downloaded,
      );

      expect(shelf.opened, 0);
      expect(shelf.openedCount, 0);
      expect(shelf.hasAnswer, isFalse);
      expect(shelf.unvalued.single.blocker, BoxBlocker.noComposition);
      expect(shelf.unstated.single.setCode, 'unstated');
      expect(shelf.openings.single.opened, isNull);
    });

    test(
      'a set that is not downloaded reads differently from an unpriced one',
      () {
        final shelf = BoxShelf.of(
          holdings: <SealedHolding>[
            box(setCode: 'absent'),
            box(setCode: 'quiet'),
          ],
          compositions: <String, BoxComposition>{
            'absent': composition,
            'quiet': composition,
          },
          cards: <String, List<TcgCard>>{
            'quiet': <TcgCard>[card('u1', 'rare')],
          },
        );

        expect(shelf.unvalued.length, 2);
        expect(shelf.unvalued.first.blocker, BoxBlocker.setNotDownloaded);
        expect(shelf.unvalued.last.blocker, BoxBlocker.nothingPriced);
        expect(shelf.unstated, isEmpty);
      },
    );

    test('a box with no price list figure still has a contents value', () {
      final shelf = BoxShelf.of(
        holdings: <SealedHolding>[box(unitValue: null, unitCost: 3)],
        compositions: stated,
        cards: downloaded,
      );

      expect(shelf.opened, closeTo(4.0, 0.0001));
      expect(shelf.sealedCount, 0);
      expect(shelf.hasAnswer, isFalse, reason: 'nothing to compare it with');
      // What it cost is only used against the contents, so it survives.
      expect(shelf.cost, 3);
      expect(shelf.againstCost, closeTo(1.0, 0.0001));
    });

    test('an empty shelf is empty rather than a zero', () {
      final shelf = BoxShelf.of(
        holdings: const <SealedHolding>[],
        compositions: stated,
        cards: downloaded,
      );

      expect(shelf.isEmpty, isTrue);
      expect(shelf.hasAnswer, isFalse);
      expect(shelf.cost, isNull);
      expect(shelf.againstCost, isNull);
      expect(shelf.difference, 0);
    });
  });
}
