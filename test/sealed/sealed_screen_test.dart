// What the sealed shelf looks like, without a database or a network.
//
//   flutter test test/sealed/sealed_screen_test.dart
//
// The screen is data-in, pixels-out; everything it reads comes from providers,
// so a test can hand it a shelf and look at what it draws. Nothing here opens
// SQLite or a socket, which is what makes it run at all: a widget test holds the
// clock still, and anything that waits on a real event loop would hang rather
// than fail.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:arcanum/features/sealed/sealed_screen.dart';
import 'package:arcanum/providers.dart';

TcgCard card(String id, String rarity, [double? price]) => TcgCard(
  game: CardGame.mtg,
  id: id,
  setCode: 'BLB',
  setName: 'Bloomburrow',
  name: 'Card $id',
  collectorNumber: id,
  rarity: rarity,
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{'nonfoil': price}),
);

SealedHolding box({
  required String name,
  required int quantity,
  double? unitValue,
  double? unitCost,
  String setCode = 'BLB',
  SealedCategory category = SealedCategory.boosterBox,
  String location = '',
  int id = 1,
}) => SealedHolding(
  id: id,
  game: CardGame.mtg,
  setCode: setCode,
  setName: 'Bloomburrow',
  name: name,
  category: category,
  quantity: quantity,
  unitValue: unitValue,
  unitCost: unitCost,
  location: location,
);

Future<void> pumpShelf(
  WidgetTester tester,
  List<SealedHolding> holdings, {
  BoxShelf shelf = BoxShelf.empty,
}) async {
  // A tall window: the shelf, the totals and the footer note are one list, and
  // a lazily built list does not build what is below the fold.
  tester.view.physicalSize = const Size(900, 3600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{});
  // A memory store rather than the keystore: the real one is a plugin, and a
  // plugin call inside a widget test is a wait with nothing on the other end.
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        sealedPortfolioProvider.overrideWith(
          (ref, CardGame game) async => SealedPortfolio.of(holdings),
        ),
        // Handed rather than computed: the screen is data-in, pixels-out, and a
        // test should not have to open SQLite to say what a box is worth.
        boxShelfProvider.overrideWith((ref, CardGame game) async => shelf),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const SealedScreen(),
      ),
    ),
  );
  // Bounded pumps: the screen shows a progress bar while the shelf loads, and
  // that animation never ends, so pumpAndSettle would wait for a last frame
  // that never comes.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an empty shelf says so and offers the way to fill it', (
    tester,
  ) async {
    await pumpShelf(tester, const <SealedHolding>[]);

    expect(find.text('Sealed product'), findsOneWidget);
    expect(find.text('Nothing sealed yet'), findsOneWidget);
    expect(find.text('Add sealed product'), findsOneWidget);
    // Nothing to refresh, so no refresh button to press.
    expect(find.text('Refresh prices'), findsNothing);
  });

  testWidgets('the shelf adds up what is on it', (tester) async {
    await pumpShelf(tester, <SealedHolding>[
      box(
        name: 'Play Booster Display',
        quantity: 2,
        unitValue: 199.35,
        unitCost: 150,
      ),
      box(
        name: 'Bundle',
        quantity: 1,
        unitValue: 178.19,
        category: SealedCategory.bundle,
      ),
      box(name: 'Prerelease Pack', quantity: 3, category: SealedCategory.other),
    ]);

    // Two displays at 199.35 plus a bundle at 178.19.
    expect(find.text(r'$576.89'), findsOneWidget);
    expect(find.text('6'), findsOneWidget, reason: 'six products held');
    expect(find.text('3'), findsOneWidget, reason: 'three kinds of thing');
    expect(find.text(r'$300.00'), findsOneWidget, reason: 'what was paid');
    // And it says how many rows nothing has priced, rather than leaving them
    // out of the arithmetic silently.
    expect(find.textContaining('1 of 3'), findsOneWidget);
    expect(find.text('Refresh prices'), findsOneWidget);
  });

  testWidgets('each holding reads as a count, a kind, a set and a place', (
    tester,
  ) async {
    await pumpShelf(tester, <SealedHolding>[
      box(
        name: 'Play Booster Display',
        quantity: 2,
        unitValue: 199.35,
        location: 'Top shelf',
      ),
    ]);

    expect(find.text('Play Booster Display'), findsOneWidget);
    expect(find.textContaining('2 x Booster box'), findsOneWidget);
    expect(find.textContaining('Bloomburrow (BLB)'), findsOneWidget);
    expect(find.textContaining('Top shelf'), findsOneWidget);
    // Twice: once as the shelf's total, once as the row's own value.
    expect(find.text(r'$398.70'), findsNWidgets(2), reason: 'two of them');
  });

  testWidgets('a box offers to be compared with the cards inside it', (
    tester,
  ) async {
    await pumpShelf(tester, <SealedHolding>[
      box(name: 'Play Booster Display', quantity: 1, unitValue: 199.35),
      box(
        name: 'Play Booster Pack',
        quantity: 3,
        category: SealedCategory.boosterPack,
      ),
    ]);

    // One box, one calculator: a pack is not a box and has no composition to
    // state, so it does not offer one.
    expect(find.byTooltip('Box value'), findsOneWidget);
  });

  testWidgets('a box of a set nobody knows offers nothing to compare', (
    tester,
  ) async {
    await pumpShelf(tester, <SealedHolding>[
      box(name: 'Some Unlisted Display', quantity: 1, setCode: ''),
    ]);

    expect(find.byTooltip('Box value'), findsNothing);
  });

  testWidgets('a box is valued both ways, shut and opened', (tester) async {
    final SealedHolding display = box(
      name: 'Play Booster Display',
      quantity: 2,
      unitValue: 100,
      id: 7,
    );
    // Ten commons at a mean of 0.20 and two rares at 1.00: 4.00 a box, two
    // boxes held.
    final BoxShelf shelf = BoxShelf.of(
      holdings: <SealedHolding>[display],
      compositions: const <String, BoxComposition>{
        'BLB': BoxComposition(
          packs: 4,
          cardsPerPack: 5,
          slots: <BoxSlot>[
            BoxSlot(CardRarity.common, 10),
            BoxSlot(CardRarity.rare, 2),
          ],
        ),
      },
      cards: <String, List<TcgCard>>{
        'BLB': <TcgCard>[
          card('c1', 'common', 0.10),
          card('c2', 'common', 0.30),
          card('r1', 'rare', 1.00),
        ],
      },
    );
    await pumpShelf(tester, <SealedHolding>[display], shelf: shelf);

    expect(find.text('OPENED OR KEPT'), findsOneWidget);
    expect(find.text('Kept sealed'), findsOneWidget);
    expect(find.text('Opened'), findsOneWidget);
    // 200.00 shut, 8.00 opened, so opening is 192.00 behind.
    expect(find.text(r'$200.00'), findsWidgets);
    expect(find.text(r'$8.00'), findsWidgets);
    expect(find.text(r'-$192.00'), findsOneWidget);
    expect(
      find.text(
        'On these boxes, the boxes sell for more than the cards inside are '
        'worth.',
      ),
      findsOneWidget,
    );
    // And the row for the box carries its own opened figure.
    expect(find.text(r'opened $8.00'), findsOneWidget);
  });

  testWidgets('a box nobody has described is not counted as nothing', (
    tester,
  ) async {
    final SealedHolding undescribed = box(
      name: 'Undescribed Display',
      quantity: 2,
      unitValue: 100,
      setCode: 'XYZ',
      id: 9,
    );
    final BoxShelf shelf = BoxShelf.of(
      holdings: <SealedHolding>[undescribed],
      compositions: const <String, BoxComposition>{},
      cards: const <String, List<TcgCard>>{},
    );
    await pumpShelf(tester, <SealedHolding>[undescribed], shelf: shelf);

    expect(find.text('OPENED OR KEPT'), findsOneWidget);
    // No figure is invented for it, and no comparison is made from nothing.
    expect(find.text('Opening pays better by'), findsNothing);
    expect(find.text('Kept sealed'), findsNothing);
    expect(
      find.text(
        '2 boxes are not counted, because their value as cards is '
        'unknown:',
      ),
      findsOneWidget,
    );
    expect(find.text('2 × No composition stated'), findsOneWidget);
    // One row to state, however many boxes that row holds.
    expect(find.text('State what that box holds'), findsOneWidget);
  });

  testWidgets('the screen explains where its prices come from', (tester) async {
    await pumpShelf(tester, <SealedHolding>[
      box(name: 'Play Booster Display', quantity: 1, unitValue: 199.35),
    ]);

    expect(
      find.textContaining(
        'Prices come from the price list your companion keeps',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('left out of the total rather than guessed at'),
      findsOneWidget,
    );
  });
}
