// What the set browser does when the game changes under it.
//
//   flutter test test/features/sets_screen_test.dart
//
// The type filter is a row drawn from one catalogue's set types, and the chip
// row only draws the populous ones. That makes it the one filter in the app
// that can be on with nothing on screen to say so, which is what these tests
// are about: the screen is data-in, pixels-out, so a test hands it two
// catalogues and looks at what it draws.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/set_completion.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/sets/sets_screen.dart';
import 'package:arcanum/providers.dart';

TcgSet aSet(CardGame game, String code, String name, String type) => TcgSet(
  game: game,
  id: code,
  code: code,
  name: name,
  setType: type,
  releasedAt: DateTime(2026, 4, 24),
  cardCount: 100,
);

final List<TcgSet> mtgSets = <TcgSet>[
  aSet(CardGame.mtg, 'PF26', 'MagicFest 2026', 'promo'),
  aSet(CardGame.mtg, 'PECL', 'Lorwyn Eclipsed Promos', 'promo'),
  aSet(CardGame.mtg, 'BLB', 'Bloomburrow', 'expansion'),
  aSet(CardGame.mtg, 'TBLB', 'Bloomburrow Tokens', 'token'),
];

final List<TcgSet> onePieceSets = <TcgSet>[
  aSet(CardGame.onePiece, 'SD01', 'Set Sail Deck Set', 'starter'),
  aSet(CardGame.onePiece, 'OP18', 'The Dominance of God', 'expansion'),
];

/// Digimon keeps its codes without the hyphen the boxes are printed with.
final List<TcgSet> digimonSets = <TcgSet>[
  aSet(CardGame.digimon, 'BT26', 'Timeless Bonds', 'expansion'),
  aSet(CardGame.digimon, 'BT27', 'Ignition of X', 'expansion'),
  aSet(CardGame.digimon, 'ST23', 'Starter Deck 23: Beatbreak', 'starter'),
];

/// Gundam's catalogue publishes no release date for any set - the provider
/// states none - and Star Wars: Unlimited's states only a CMS publish date,
/// which is months before the street date and so is not one either. Two games
/// in that position is what turned the chip row's lie from a curiosity into
/// something worth fixing.
final List<TcgSet> undatedSets = <TcgSet>[
  TcgSet(
    game: CardGame.gundam,
    id: 'GD01',
    code: 'gd01',
    name: 'Newtype Rising',
    setType: 'expansion',
    cardCount: 254,
  ),
  TcgSet(
    game: CardGame.gundam,
    id: 'ST01',
    code: 'st01',
    name: 'Starter Deck 01',
    setType: 'starter',
    cardCount: 17,
  ),
];

List<TcgSet> catalogFor(CardGame game) => switch (game) {
  CardGame.gundam => undatedSets,
  CardGame.mtg => mtgSets,
  CardGame.onePiece => onePieceSets,
  CardGame.digimon => digimonSets,
  _ => const <TcgSet>[],
};

/// Magic's own set types: promos, tokens, expansions.
final Map<String, int> mtgCounts = <String, int>{
  'promo': 296,
  'expansion': 400,
  'token': 213,
};

/// One Piece has no token sets at all - tokens are not a thing that is sold as
/// a set there - which is exactly the case that used to empty the screen.
final Map<String, int> onePieceCounts = <String, int>{
  'starter': 37,
  'expansion': 31,
  'promo': 20,
};

final Map<String, int> digimonCounts = <String, int>{
  'expansion': 63,
  'starter': 27,
};

/// Builds the screen over two catalogues with no database behind it.
///
/// [counts] is read on every build, so a test can change what the catalogue
/// says between pumps.
Future<ProviderContainer> pumpSets(
  WidgetTester tester, {
  required Map<String, int> Function(CardGame game) counts,
  CardGame game = CardGame.mtg,
}) async {
  // A wide, tall window: the chip row is one horizontal scroll, so a chip that
  // is real is not necessarily on screen and a tap at its centre would land on
  // nothing, and the list is built lazily, so a short window would not build
  // what the test looks for.
  tester.view.physicalSize = const Size(1400, 3600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{
    'active_game': game.id,
  });
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        setsProvider.overrideWith((ref, CardGame g) async => catalogFor(g)),
        setTypeCountsProvider.overrideWith(
          (ref, CardGame g) async => counts(g),
        ),
        // Nothing is owned and nothing is downloaded: this test is about the
        // filter row, not about progress.
        ownedBySetProvider.overrideWith(
          (ref, CardGame g) async => const <String, int>{},
        ),
        setCompletionProvider.overrideWith(
          (ref, CardGame g) async => const <String, SetCompletion>{},
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const SetsScreen(),
      ),
    ),
  );
  // Bounded pumps: the list fades and slides in, so pumpAndSettle would be
  // waiting on an animation rather than on data.
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return ProviderScope.containerOf(tester.element(find.byType(SetsScreen)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a type chip narrows the list to that type', (tester) async {
    await pumpSets(
      tester,
      counts: (CardGame g) => g == CardGame.mtg ? mtgCounts : onePieceCounts,
    );

    expect(find.text('Bloomburrow'), findsOneWidget);
    expect(find.text('Bloomburrow Tokens'), findsOneWidget);

    await tester.tap(find.text('Promo'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('MagicFest 2026'), findsOneWidget);
    expect(find.text('Lorwyn Eclipsed Promos'), findsOneWidget);
    expect(find.text('Bloomburrow'), findsNothing, reason: 'filtered out');
    expect(find.text('Bloomburrow Tokens'), findsNothing);
  });

  testWidgets('switching game drops a type the new catalogue does not have', (
    tester,
  ) async {
    final ProviderContainer container = await pumpSets(
      tester,
      counts: (CardGame g) => g == CardGame.mtg ? mtgCounts : onePieceCounts,
    );

    await tester.tap(find.text('Token'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Bloomburrow Tokens'), findsOneWidget);
    expect(find.text('Bloomburrow'), findsNothing, reason: 'token sets only');

    container.read(activeGameProvider.notifier).select(CardGame.onePiece);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // The whole One Piece catalogue, not a Magic filter applied to it: the
    // chip row has no Token to show and so nothing that could explain an
    // empty list.
    expect(find.text('Set Sail Deck Set'), findsOneWidget);
    expect(find.text('The Dominance of God'), findsOneWidget);
    expect(find.text('No sets match'), findsNothing);
    expect(find.text('Token'), findsNothing, reason: 'the chip went with it');
  });

  testWidgets('a selected type keeps its chip when the top row drops it', (
    tester,
  ) async {
    int promoSets = 296;
    final ProviderContainer container = await pumpSets(
      tester,
      counts: (CardGame g) => g == CardGame.mtg
          ? <String, int>{'promo': promoSets, 'expansion': 400, 'token': 213}
          : onePieceCounts,
    );

    await tester.tap(find.text('Promo'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    // The catalogue is reloaded and comes back with a handful of promo sets:
    // too few for the chip row to offer. The filter is still on, so it has to
    // stay on screen - a set the collector can see they are filtering by.
    promoSets = 3;
    container.invalidate(setTypeCountsProvider);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('Promo'), findsOneWidget, reason: 'the active chip stays');
    expect(find.text('MagicFest 2026'), findsOneWidget);
    expect(find.text('Bloomburrow'), findsNothing, reason: 'still filtering');
  });

  testWidgets('a set is found by the code printed on the box', (tester) async {
    await pumpSets(
      tester,
      game: CardGame.digimon,
      counts: (CardGame g) => digimonCounts,
    );

    // Digimon prints "BT-26" and the catalogue keeps "BT26": typing what is on
    // the box used to answer "No sets match".
    await tester.enterText(find.byType(TextField), 'BT-26');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('Timeless Bonds'), findsOneWidget);
    expect(find.text('No sets match'), findsNothing);

    // And the form the app itself shows still works.
    await tester.enterText(find.byType(TextField), 'ST23');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Starter Deck 23: Beatbreak'), findsOneWidget);
    expect(find.text('Timeless Bonds'), findsNothing);

    // A code that is not there is still not there.
    await tester.enterText(find.byType(TextField), 'BT-28');
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('No sets match'), findsOneWidget);
  });

  testWidgets('a catalogue with no release dates is not offered a date order', (
    tester,
  ) async {
    await pumpSets(
      tester,
      game: CardGame.gundam,
      counts: (CardGame g) => <String, int>{'expansion': 10, 'starter': 4},
    );

    // Every set sorts to the same missing date, so "Newest" ordered nothing and
    // the list underneath it was in name order - a chip making a claim about the
    // catalogue rather than about the sort. The two date orders are dropped and
    // the three that mean something to a game without dates are kept.
    expect(find.text('Newest'), findsNothing);
    expect(find.text('Oldest'), findsNothing);
    expect(find.text('A-Z'), findsOneWidget);
    expect(find.text('Largest'), findsOneWidget);
    expect(find.text('Closest'), findsOneWidget);

    // And the row opens on the order the list is actually in.
    expect(find.text('Newtype Rising'), findsOneWidget);
  });

  testWidgets('and a catalogue with dates keeps the whole row', (tester) async {
    // The other half of the same rule: a game whose provider publishes release
    // dates still gets both date orders, because there the chip is true.
    await pumpSets(tester, counts: (CardGame g) => mtgCounts);

    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Oldest'), findsOneWidget);
    expect(find.text('A-Z'), findsOneWidget);
  });
}
