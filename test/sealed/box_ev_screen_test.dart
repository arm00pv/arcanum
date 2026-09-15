// What the box value screen draws, without a database or a network.
//
//   flutter test test/sealed/box_ev_screen_test.dart
//
// Everything the screen reads comes from providers, so a test hands it a set, a
// composition and a box price, and looks at the answer. The composition is the
// part the app refuses to invent, which is why most of these are about what the
// screen says when it has not been told.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:arcanum/features/sealed/box_ev_screen.dart';
import 'package:arcanum/providers.dart';

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

/// A printing that states whether a booster holds it.
TcgCard flagged(
  String id,
  String rarity,
  double? price, {
  required bool booster,
}) => TcgCard(
  game: CardGame.mtg,
  id: id,
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Card $id',
  collectorNumber: id,
  rarity: rarity,
  booster: booster,
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{'nonfoil': price}),
);

/// Three commons at a mean of $0.20, two rares at $1.00, one unpriced mythic.
final List<TcgCard> set = <TcgCard>[
  card('c1', 'common', 0.10),
  card('c2', 'common', 0.20),
  card('c3', 'common', 0.30),
  card('r1', 'rare', 1.00),
  card('r2', 'rare', 1.00),
  card('m1', 'mythic'),
];

const BoxComposition tenTwoOne = BoxComposition(
  packs: 4,
  cardsPerPack: 5,
  slots: <BoxSlot>[
    BoxSlot(CardRarity.common, 10),
    BoxSlot(CardRarity.rare, 2),
    BoxSlot(CardRarity.mythic, 1),
  ],
);

SealedOffer offer({
  String name = 'Test Set Play Booster Box',
  double? market = 100,
  String description = '',
  String productId = '1',
}) => SealedOffer(
  name: name,
  category: SealedCategory.guess(name),
  productId: productId,
  market: market,
  description: description,
);

Future<void> pumpScreen(
  WidgetTester tester, {
  BoxComposition? composition = tenTwoOne,
  List<SealedOffer> offers = const <SealedOffer>[],
  List<TcgCard>? cards,
  String productId = '',
  String productName = '',
  double? heldPrice,
  Size size = const Size(900, 3600),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        setCardsProvider.overrideWith((ref, SetRef key) async => cards ?? set),
        boxCompositionProvider.overrideWith(
          (ref, SetRef key) async => composition,
        ),
        sealedOffersProvider.overrideWith((ref, SetRef key) async => offers),
        // A name rather than a database: the screen says which set it is about.
        setProvider.overrideWith(
          (ref, SetRef key) async => const TcgSet(
            game: CardGame.mtg,
            id: 'tst',
            code: 'tst',
            name: 'Test Set',
            setType: 'expansion',
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: BoxEvScreen(
              game: CardGame.mtg,
              setCode: 'tst',
              productId: productId,
              productName: productName,
              heldPrice: heldPrice,
            ),
          ),
        ),
      ),
    ),
  );
  // Bounded pumps: the screen shows a progress bar while the set loads, and
  // that animation never ends, so pumpAndSettle would wait for a frame that
  // never comes.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the answer is worked out from the stored composition', (
    tester,
  ) async {
    await pumpScreen(tester, offers: <SealedOffer>[offer()]);

    expect(find.text('Box value'), findsOneWidget);
    expect(find.text('What a box of Test Set is worth'), findsOneWidget);
    // 10 commons at a mean of $0.20 and 2 rares at $1.00.
    expect(find.text(r'$4.00'), findsOneWidget);
    expect(find.text(r'$1.00'), findsWidgets);
    // 4 packs, so $4.00 across them.
    expect(find.text('Across 4 packs'), findsOneWidget);
    expect(find.text('Every slot priced'), findsNothing);
    expect(
      find.text('One slot has no price, so this is a floor'),
      findsOneWidget,
    );
  });

  testWidgets('the box price is put against the answer', (tester) async {
    await pumpScreen(tester, offers: <SealedOffer>[offer()]);

    expect(find.text(r'-$96.00'), findsOneWidget);
    expect(
      find.text(r'The box is $100.00, so opening pays back 4% of it'),
      findsOneWidget,
    );
  });

  testWidgets('a case of boxes is never taken for the box', (tester) async {
    // A product list arrives dearest first, and a case is always dearest. The
    // answer has to be about one box: a case is six.
    await pumpScreen(
      tester,
      offers: <SealedOffer>[
        offer(name: 'Test Set Booster Box Case', market: 1200),
        offer(name: 'Test Set Booster Box', market: 200),
      ],
    );

    expect(find.text(r'$200.00'), findsWidgets);
    expect(
      find.text(r'The box is $200.00, so opening pays back 2% of it'),
      findsOneWidget,
    );
    // The case is offered, not shown: it is a product, not this set's box.
    expect(find.text('Test Set Booster Box Case'), findsNothing);
    expect(find.text('Show one more, a case or a deck'), findsOneWidget);

    await tester.tap(find.text('Show one more, a case or a deck'));
    await tester.pump();

    expect(find.text('Test Set Booster Box Case'), findsOneWidget);
  });

  testWidgets('a box nobody has priced is a question, not a zero', (
    tester,
  ) async {
    await pumpScreen(tester, offers: <SealedOffer>[offer(market: null)]);

    expect(find.text('No box price yet'), findsOneWidget);
    expect(find.text('No price yet'), findsOneWidget);
    expect(find.text(r'-$96.00'), findsNothing);
  });

  testWidgets('the editor changes the answer without a save', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Across 4 packs'), findsOneWidget);
    expect(find.text(r'$1.00'), findsWidgets);

    // The first stepper on the screen is the pack count; $4.00 across five
    // packs is $0.80 a pack.
    await tester.tap(find.widgetWithIcon(IconButton, Icons.add_rounded).first);
    await tester.pump();

    expect(find.text('Across 5 packs'), findsOneWidget);
    expect(find.text(r'$0.80'), findsOneWidget);
  });

  testWidgets('what the shop says about the box is offered, not applied', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      composition: const BoxComposition(),
      offers: <SealedOffer>[
        offer(
          description:
              '1 Box contains 24 Booster. Each Booster Pack contains 12 cards.',
        ),
      ],
    );

    // Nothing stated yet, so there is nothing to value: the shape of a pack is
    // the collector's to state and the app will not fill it in.
    expect(
      find.text('State what the box holds and the answer appears here.'),
      findsOneWidget,
    );
    expect(find.text('The slots account for 0 cards'), findsOneWidget);
    expect(find.text('Deal them out'), findsNothing);

    // The shop's own words are offered as a button and change nothing until
    // they are taken.
    await tester.tap(
      find.text('The shop says 24 packs, 12 cards a pack - use it'),
    );
    await tester.pump();

    // Taken, the size of the box is filled in - and only the size. The slots
    // are still the collector's, and the screen says so rather than inventing
    // a distribution.
    expect(find.text('The slots account for 0 of 288 cards'), findsOneWidget);
    expect(
      find.textContaining('A pack is not dealt like the set'),
      findsOneWidget,
    );
    expect(find.text('Deal them out'), findsNothing);
  });

  testWidgets('a slot count is typed, not tapped in one at a time', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      composition: const BoxComposition(packs: 36, cardsPerPack: 14),
      offers: <SealedOffer>[offer()],
    );

    // The first slot is the common one; tapping its count opens a box to type
    // in, because three hundred cards is not three hundred taps.
    await tester.tap(find.text('0').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '252');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();

    expect(find.text('252'), findsOneWidget);
    expect(find.text('The slots account for 252 of 504 cards'), findsOneWidget);
  });

  testWidgets('a set nobody has priced says why there is no answer', (
    tester,
  ) async {
    await pumpScreen(tester, cards: <TcgCard>[card('u1', 'rare')]);

    expect(
      find.textContaining('Nothing in this set carries a price yet'),
      findsOneWidget,
    );
  });

  testWidgets('it fits a phone, at 1x and at 2x text', (tester) async {
    // A Pixel 7 Pro is 412 logical pixels wide. This is the size the screen has
    // to survive; an overflow fails the test by itself.
    const Size phone = Size(824, 2400);
    await pumpScreen(tester, offers: <SealedOffer>[offer()], size: phone);
    await pumpScreen(
      tester,
      offers: <SealedOffer>[offer()],
      size: phone,
      textScale: 2,
    );

    // Asserted at the top of the list: at 2x text the answer is below the fold,
    // and a lazily built list does not build what is below the fold.
    expect(find.text('THE BOX'), findsOneWidget);
    expect(find.text('WHAT THE BOX HOLDS'), findsOneWidget);
  });

  testWidgets('the box the collector holds is the one being valued', (
    tester,
  ) async {
    // Opened from a shelf row for the Play Booster Display, in a set where the
    // dearest box is a Collector Booster Display six times the price.
    await pumpScreen(
      tester,
      productId: '555',
      productName: 'Test Set Play Booster Display',
      offers: <SealedOffer>[
        offer(name: 'Test Set Collector Booster Display', market: 1272),
        offer(
          name: 'Test Set Play Booster Display',
          market: 199,
          productId: '555',
        ),
      ],
    );

    expect(
      find.text(r'The box is $199.00, so opening pays back 2% of it'),
      findsOneWidget,
    );
  });

  testWidgets('a box no price list answers for keeps its own recorded value', (
    tester,
  ) async {
    await pumpScreen(tester, offers: const <SealedOffer>[], heldPrice: 175);

    expect(
      find.text(r'The box is $175.00, so opening pays back 2% of it'),
      findsOneWidget,
    );
  });

  testWidgets('the screen says what the mean was averaged over', (
    tester,
  ) async {
    // Three commons, two of them in boosters and one a treatment no booster
    // carries. The mean has to be of the two, and the screen has to say so:
    // the same figure over all three is a different claim about a different
    // pool, and it is the one that made a $199 box look like $861 of cards.
    await pumpScreen(
      tester,
      cards: <TcgCard>[
        flagged('b1', 'common', 0.10, booster: true),
        flagged('b2', 'common', 0.20, booster: true),
        flagged('x1', 'common', 9.00, booster: false),
      ],
      offers: <SealedOffer>[offer()],
    );

    expect(
      find.textContaining('Averaged over the printings a booster can hold'),
      findsOneWidget,
    );
    expect(find.textContaining('2 of the set\'s 3 printings'), findsOneWidget);
    expect(
      find.textContaining('holds cards left out here'),
      findsOneWidget,
      reason: 'a box that promises treatments is worth more than the figure',
    );
    // 10 commons at the mean of the two a booster can hold: $0.15 each. The
    // subtotal and the answer are the same number here, so both are on screen.
    expect(find.text(r'$1.50'), findsWidgets);
    expect(find.text(r'$90.00'), findsNothing, reason: 'the treatment is out');
  });

  testWidgets('a set with nothing left out says the pool is the set', (
    tester,
  ) async {
    await pumpScreen(tester, offers: <SealedOffer>[offer()]);

    expect(
      find.textContaining('Averaged over every one of the set\'s 6 printings'),
      findsOneWidget,
    );
    expect(find.textContaining('left out here'), findsNothing);
  });

  testWidgets('the set not being downloaded is said in words', (tester) async {
    await pumpScreen(tester, cards: const <TcgCard>[]);

    expect(find.text('The set is not downloaded'), findsOneWidget);
    expect(find.text('THE BOX'), findsNothing);
  });
}
