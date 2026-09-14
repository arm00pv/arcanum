// What the "add to collection" sheet says about what is already owned.
//
//   flutter test test/features/add_to_collection_note_test.dart
//
// The line is small and the claim is not: a sheet that says a card is in the
// collection before the button has been pressed is a sheet that has already lied
// once when the user reads it.

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/card/add_to_collection_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('what the add sheet says about the copies you have', () {
    test('a count that has not arrived is not a count of none', () {
      final String note = ownershipNote(game: CardGame.mtg, copies: null);
      expect(note, contains('Checking'));
      expect(note, isNot(contains('Not in')));
    });

    test('a card that is not owned says so, in the right game', () {
      expect(
        ownershipNote(game: CardGame.mtg, copies: 0),
        'Not in your ${CardGame.mtg.shortLabel} collection yet',
      );
      expect(
        ownershipNote(game: CardGame.yugioh, copies: 0),
        contains(CardGame.yugioh.shortLabel),
      );
    });

    test('one copy reads as one copy', () {
      expect(
        ownershipNote(game: CardGame.pokemon, copies: 1),
        'You already own 1 copy of this printing',
      );
    });

    test('a stack reads as a stack', () {
      expect(
        ownershipNote(game: CardGame.lorcana, copies: 4),
        'You already own 4 copies of this printing',
      );
    });
  });
}
