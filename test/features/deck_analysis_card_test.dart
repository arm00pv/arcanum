// The deck analysis panel, drawn.
//
//   flutter test test/features/deck_analysis_card_test.dart
//
// The panel is the part of the feature a person actually reads, so the thing
// worth pinning down is what it says when it knows little: a deck whose cards
// have no rules text must say so rather than draw an empty chart, and at 2x text
// scale nothing may overflow.

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_analysis.dart';
import 'package:arcanum/features/decks/deck_analysis_card.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard card(
  String name, {
  required double cmc,
  String type = 'Creature',
  String? text,
}) => TcgCard(
  game: CardGame.mtg,
  id: name.toLowerCase().replaceAll(' ', '-'),
  setCode: 'tst',
  setName: 'Test Set',
  name: name,
  collectorNumber: '1',
  rarity: 'common',
  typeLine: type,
  oracleText: text,
  cmc: cmc,
  colorIdentity: const <String>['G'],
);

DeckEntry line(TcgCard c, int quantity) => DeckEntry(
  cardId: c.id,
  quantity: quantity,
  board: DeckBoard.main,
  game: c.game,
  card: c,
);

DeckContents deckOf(List<DeckEntry> entries) => DeckContents(
  deck: Deck(
    id: 1,
    game: CardGame.mtg,
    name: 'Test',
    formatId: 'mtg-casual',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  entries: entries,
  value: 0,
  missingValue: 0,
);

Future<void> pump(
  WidgetTester tester,
  DeckAnalysis analysis, {
  double textScale = 1,
  VoidCallback? onSuggest,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: 340,
                child: DeckAnalysisCard(
                  analysis: analysis,
                  onSuggest: onSuggest,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 40));
}

void main() {
  testWidgets('a readable deck shows its curve, roles and shape', (
    WidgetTester tester,
  ) async {
    final analysis = analyseDeck(
      deckOf(<DeckEntry>[
        line(card('Forest', cmc: 0, type: 'Basic Land — Forest'), 14),
        line(card('Elf', cmc: 2, text: 'Tap: Add {G}.'), 4),
        line(
          card('Draw Spell', cmc: 3, type: 'Sorcery', text: 'Draw two cards.'),
          4,
        ),
        line(
          card(
            'Doom Blade',
            cmc: 2,
            type: 'Instant',
            text: 'Destroy target creature.',
          ),
          4,
        ),
      ]),
    );

    await pump(tester, analysis);

    expect(find.text('Deck analysis'), findsOneWidget);
    expect(find.text('Mana curve'), findsOneWidget);
    expect(find.textContaining('Ramp'), findsOneWidget);
    expect(find.textContaining('Removal'), findsOneWidget);
    expect(find.textContaining('Made of'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the panel says so when it could not read the deck', (
    WidgetTester tester,
  ) async {
    final analysis = analyseDeck(
      deckOf(<DeckEntry>[line(card('Vanilla', cmc: 2), 30)]),
    );

    await pump(tester, analysis);

    expect(analysis.rolesRead, isFalse);
    expect(
      find.textContaining('Not enough of this deck has rules text'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty deck invites a card rather than drawing a shape', (
    WidgetTester tester,
  ) async {
    await pump(tester, analyseDeck(deckOf(<DeckEntry>[])));

    expect(
      find.textContaining('Add cards and the shape of the deck fills in'),
      findsOneWidget,
    );
  });

  testWidgets('the suggest button reports taps', (WidgetTester tester) async {
    var tapped = 0;
    await pump(
      tester,
      analyseDeck(
        deckOf(<DeckEntry>[
          line(
            card(
              'Doom Blade',
              cmc: 2,
              type: 'Instant',
              text: 'Destroy target creature.',
            ),
            4,
          ),
        ]),
      ),
      onSuggest: () => tapped++,
    );

    await tester.tap(find.text('Suggest'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('the panel survives 2x text scale', (WidgetTester tester) async {
    final analysis = analyseDeck(
      deckOf(<DeckEntry>[
        line(card('Forest', cmc: 0, type: 'Basic Land — Forest'), 30),
        line(
          card(
            'A Very Long Card Name Indeed, Longer Than Most',
            cmc: 4,
            type: 'Legendary Creature — Goblin Warrior',
            text: 'Draw a card. Destroy target creature. Add {R}.',
          ),
          20,
        ),
      ]),
    );

    await pump(tester, analysis, textScale: 2, onSuggest: () {});
    expect(tester.takeException(), isNull);
  });

  testWidgets('no suggest button when there is nothing to suggest', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      analyseDeck(
        deckOf(<DeckEntry>[
          line(
            card(
              'Doom Blade',
              cmc: 2,
              type: 'Instant',
              text: 'Destroy target creature.',
            ),
            4,
          ),
        ]),
      ),
    );
    expect(find.text('Suggest'), findsNothing);
  });
}
