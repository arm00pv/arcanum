import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
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
      final composition = BoxComposition.evenAcross(
        cards: <TcgCard>[
          card('1', 'common'),
          card('2', 'common'),
          card('3', 'uncommon'),
          card('4', 'uncommon'),
          card('5', 'rare'),
          card('6', 'rare'),
          card('7', 'mythic'),
          card('8', 'special'),
        ],
        packs: 1,
        cardsPerPack: 8,
      );
      final round = BoxComposition.fromJson(composition.toJson());
      expect(round.packs, 1);
      expect(round.cardsPerPack, 8);
      expect(round.slots, composition.slots);
      expect(round.slots, const <BoxSlot>[
        BoxSlot(CardRarity.common, 2),
        BoxSlot(CardRarity.uncommon, 2),
        BoxSlot(CardRarity.rare, 2),
        BoxSlot(CardRarity.mythic, 1),
        BoxSlot(CardRarity.special, 1),
      ]);
    });

    test('an even deal fills the box exactly', () {
      final cards = <TcgCard>[
        for (int i = 0; i < 6; i++) card('c$i', 'common'),
        for (int i = 0; i < 3; i++) card('r$i', 'rare'),
        card('m0', 'mythic'),
      ];
      final composition = BoxComposition.evenAcross(
        cards: cards,
        packs: 24,
        cardsPerPack: 12,
      );
      expect(composition.cards, 288);
      expect(composition.isWhole, isTrue);
      expect(composition.countOf(CardRarity.common), greaterThan(0));
      expect(composition.countOf(CardRarity.rare), greaterThan(0));
      expect(composition.countOf(CardRarity.mythic), greaterThan(0));
      expect(composition.countOf(CardRarity.uncommon), 0);
    });

    test('nothing to deal out leaves the size alone', () {
      final composition = BoxComposition.evenAcross(
        cards: const <TcgCard>[],
        packs: 24,
        cardsPerPack: 12,
      );
      expect(composition.slots, isEmpty);
      expect(composition.packs, 24);
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
}
