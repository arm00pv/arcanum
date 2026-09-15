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
    'activeGame': game.id,
  });
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        setsProvider.overrideWith(
          (ref, CardGame g) async => g == CardGame.mtg ? mtgSets : onePieceSets,
        ),
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
}
