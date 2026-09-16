import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard printing({
  required CardGame game,
  required bool promo,
  String rarity = 'common',
}) => TcgCard(
  game: game,
  id: 'x',
  setCode: 'tst',
  setName: 'Test Set',
  name: 'Card',
  collectorNumber: '1',
  rarity: rarity,
  promo: promo,
);

void main() {
  group('art that may carry the publisher\'s mark', () {
    test('a printing may be marked whether or not it is promotional', () {
      // Bandai serves Gundam, One Piece and Digimon as a press render with
      // SAMPLE across it, whatever the printing is. Fetched and looked at:
      // Gundam boosters GD01, GD02, GD03, GD04, GD05 and the deck build box,
      // starters ST01, ST02, ST06, ST10 and ST11, a promotional run; One Piece
      // from OP01 to the newest set; Digimon from the first starter deck to the
      // newest booster. Every one carries the mark, promotional runs and
      // ordinary sets alike, so the flag cannot come from the printing.
      for (final game in <CardGame>[
        CardGame.gundam,
        CardGame.onePiece,
        CardGame.digimon,
      ]) {
        expect(printing(game: game, promo: true).artMayBeMarked, isTrue);
        expect(
          printing(game: game, promo: false).artMayBeMarked,
          isTrue,
          reason: game.name,
        );
      }
    });

    test('every other game is an ordinary scan', () {
      // Scryfall marks Magic's promotional printings too, and those are
      // photographed cards with no watermark; Bandai's own Dragon Ball is
      // photographed as well. Calling any of these a sample would invent a
      // fault.
      for (final game in CardGame.values) {
        if (game == CardGame.gundam ||
            game == CardGame.onePiece ||
            game == CardGame.digimon) {
          continue;
        }
        expect(printing(game: game, promo: true).artMayBeMarked, isFalse);
        expect(
          printing(game: game, promo: false).artMayBeMarked,
          isFalse,
          reason: game.name,
        );
      }
    });

    test('the rule is about the game, so a set screen can ask it', () {
      // It is not a claim about the card in hand, and 1.24.0 said it was: "no
      // clean picture of a Gundam, One Piece or Digimon card is published
      // anywhere". Digimon is where that broke. Every Digimon set looked at
      // then carried the mark - ST-1, ST-23, BT-26 - and then EX3-001 turned up
      // clean: the original EX-03 "Draconic Roar" run is an ordinary scan with
      // no mark on it at all, and the RPC revision packs carry NOT FOR SALE down
      // one edge with no SAMPLE across the art. Both are Digimon and both are in
      // the catalogue, and nothing in a card's row tells a marked printing from
      // a clean one - so the rule says marked art turns up in this game, which
      // is what a note on screen needs, and never that this card is marked.
      expect(TcgCard.gameMarksSomeArt(CardGame.gundam), isTrue);
      expect(TcgCard.gameMarksSomeArt(CardGame.onePiece), isTrue);
      expect(TcgCard.gameMarksSomeArt(CardGame.digimon), isTrue);
      // Bandai publishes Dragon Ball too, and those are ordinary scans: the
      // rule is per title, not per publisher.
      expect(TcgCard.gameMarksSomeArt(CardGame.dragonBall), isFalse);
      for (final game in CardGame.values) {
        expect(
          TcgCard.gameMarksSomeArt(game),
          game.publisher == 'Bandai' && game != CardGame.dragonBall,
          reason: game.name,
        );
      }
    });
  });
}
