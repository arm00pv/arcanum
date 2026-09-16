// What the search screen says above its results.
//
//   flutter test test/features/search_screen_test.dart
//
// A collector number is only unique inside its set: "001" is the #001 of every
// set in the game. The screen has to say so, or a list of twelve cards that all
// read "#001" looks like a bug rather than the answer.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/search/search_screen.dart';
import 'package:arcanum/providers.dart';

TcgCard printing(String id, String setCode, String number, String name) =>
    TcgCard(
      game: CardGame.digimon,
      id: id,
      setCode: setCode,
      setName: setCode,
      name: name,
      collectorNumber: number,
      rarity: 'common',
    );

/// Two #001s from two different sets, which is what a bare number answers with.
final List<TcgCard> bothSets = <TcgCard>[
  printing('bt26-001', 'BT26', '001', 'Yokomon'),
  printing('st23-01', 'ST23', '01', 'Kekkomon'),
];

Future<void> pumpSearch(
  WidgetTester tester, {
  required List<TcgCard> results,
  required String query,
  // Tall enough that the whole discovery state is laid out - a ListView builds
  // what is on screen and no further, and the tips sit under the quick filters.
  Size size = const Size(1000, 7000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(<String, Object>{
    'active_game': CardGame.digimon.id,
  });
  final AppSettings settings = await AppSettings.load(
    secrets: MemorySecretStore(),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWithValue(settings),
        searchProvider.overrideWith((ref, ref0) async => results),
        setSearchProvider.overrideWith((ref, ref0) async => const <TcgSet>[]),
        ownedQuantityProvider.overrideWith(
          (ref, CardGame game) async => const <String, int>{},
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.build(dark: true),
        home: const SearchScreen(),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField), query);
  // Past the debounce, then past the fade the results arrive with.
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a result spread over two sets says so', (tester) async {
    await pumpSearch(tester, results: bothSets, query: '001');

    expect(find.text('2 cards · across 2 sets'), findsOneWidget);
    expect(find.text('Yokomon'), findsOneWidget);
    expect(find.text('Kekkomon'), findsOneWidget);
  });

  testWidgets('the screen says a number can be searched', (tester) async {
    // The number is the query nobody thinks to try and the one that identifies
    // a printing exactly, so the field and the tips both name it rather than
    // leaving a collector to guess that it works. The tip also has to say where
    // the answer comes from: no provider is asked for a number, so it can only
    // be answered out of the catalogue already on the phone.
    await pumpSearch(tester, results: const <TcgCard>[], query: '');

    // A tip is one RichText with the label bolded into it, so the finder has to
    // be told to look inside one.
    expect(find.text('Name, set, number or card text'), findsOneWidget);
    expect(find.textContaining('Numbers', findRichText: true), findsOneWidget);
    expect(
      find.textContaining(
        'the number on its own is answered from every set',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('card numbers and', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a result inside one set does not', (tester) async {
    await pumpSearch(
      tester,
      results: bothSets.take(1).toList(),
      query: 'BT26-001',
    );

    expect(find.text('1 card'), findsOneWidget);
    expect(find.textContaining('across'), findsNothing);
  });
}
