import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/widgets/sample_art_note.dart';

TcgCard card({required CardGame game, String? image}) => TcgCard(
  game: game,
  id: 'x',
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Card',
  collectorNumber: '1',
  rarity: 'common',
  imageUris: image == null
      ? const <String, String>{}
      : <String, String>{'normal': image},
);

Future<void> pumpNote(
  WidgetTester tester, {
  CardGame game = CardGame.gundam,
  bool short = false,
  Size size = const Size(824, 2400),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(dark: true),
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SampleArtNote(game: game, short: short),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the note answers the question a watermark raises', (
    tester,
  ) async {
    await pumpNote(tester);

    // Not "this card has a watermark" - the collector can see that. What they
    // cannot see is whether the download failed, so the note says it did not.
    expect(
      find.textContaining('This is the publisher\'s sample image'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing failed to load'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
  });

  testWidgets('it names the game it is talking about', (tester) async {
    // The same fact in three vaults reads as three different sentences, and a
    // One Piece screen must not be told about Gundam.
    await pumpNote(tester, game: CardGame.onePiece);
    expect(
      find.textContaining('Bandai serves every One Piece card'),
      findsOneWidget,
    );
    expect(find.textContaining('Gundam'), findsNothing);
  });

  testWidgets('the short form is one line for a screen about a whole set', (
    tester,
  ) async {
    await pumpNote(tester, game: CardGame.digimon, short: true);

    expect(
      find.textContaining('Bandai publishes Digimon cards'),
      findsOneWidget,
    );
    expect(find.textContaining('nothing failed to load'), findsNothing);
  });

  test('a set with no pictures yet has nothing to explain', () {
    // An unreleased set arrives as rows the shop has no image for. Nothing on
    // that screen wears a watermark, so the note waits.
    expect(
      SampleArtNote.applies(<TcgCard>[card(game: CardGame.gundam)]),
      isFalse,
    );
    expect(
      SampleArtNote.applies(<TcgCard>[
        card(game: CardGame.gundam),
        card(game: CardGame.gundam, image: 'https://example.test/1.jpg'),
      ]),
      isTrue,
    );
    expect(SampleArtNote.applies(<TcgCard>[]), isFalse);
  });

  test('an ordinary scan is never explained', () {
    expect(
      SampleArtNote.applies(<TcgCard>[
        card(game: CardGame.mtg, image: 'https://example.test/1.jpg'),
      ]),
      isFalse,
    );
  });

  testWidgets('it fits a phone at 2x text', (tester) async {
    await pumpNote(tester, size: const Size(824, 2400), textScale: 2);

    // An overflow fails the test by itself; this asserts the note is still the
    // thing on screen rather than having been squeezed out.
    expect(find.byType(SampleArtNote), findsOneWidget);
  });
}
