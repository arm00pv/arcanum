import 'package:flutter_test/flutter_test.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/features/card/owned_finishes.dart';

CollectionEntry entry({
  CardFinish finish = CardFinish.nonfoil,
  CardCondition condition = CardCondition.nearMint,
  String binder = '',
  int quantity = 1,
}) =>
    CollectionEntry(
      cardId: 'printing-1',
      finish: finish,
      condition: condition,
      binder: binder,
      quantity: quantity,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('missingFinishes', () {
    test('offers every finish a game prints when nothing is owned', () {
      expect(
        missingFinishes(const <CollectionEntry>[], CardGame.mtg),
        <CardFinish>[CardFinish.nonfoil, CardFinish.foil, CardFinish.etched],
      );
    });

    test('drops the finishes already held and keeps the game order', () {
      // The case that prompted this: a non-foil copy and a foil copy of one
      // card side by side. Etched is the only thing left to offer.
      final entries = <CollectionEntry>[
        entry(finish: CardFinish.nonfoil),
        entry(finish: CardFinish.foil),
      ];
      expect(
        missingFinishes(entries, CardGame.mtg),
        <CardFinish>[CardFinish.etched],
      );
    });

    test('puts non-foil first even when only foil is owned', () {
      // Non-foil is the default finish everywhere else in the app, so it leads
      // the suggestions rather than the order the entries happen to arrive in.
      final entries = <CollectionEntry>[entry(finish: CardFinish.foil)];
      expect(
        missingFinishes(entries, CardGame.mtg),
        <CardFinish>[CardFinish.nonfoil, CardFinish.etched],
      );
    });

    test('never repeats a finish owned across several stacks', () {
      // Two non-foil stacks - different binders, say - still leave exactly one
      // non-foil slot in the list, and that slot is absent, not duplicated.
      final entries = <CollectionEntry>[
        entry(finish: CardFinish.nonfoil, binder: 'Binder A'),
        entry(finish: CardFinish.nonfoil, binder: 'Binder B'),
        entry(finish: CardFinish.nonfoil, condition: CardCondition.played),
      ];
      expect(
        missingFinishes(entries, CardGame.mtg),
        <CardFinish>[CardFinish.foil, CardFinish.etched],
      );
    });

    test('is empty once the game has nothing left to offer', () {
      final entries = <CollectionEntry>[
        for (final f in CardGame.mtg.finishes) entry(finish: f),
      ];
      expect(missingFinishes(entries, CardGame.mtg), isEmpty);
    });

    test('follows the game, not Magic', () {
      // Yu-Gi-Oh! prints ordinary cards and foil treatments and nothing else,
      // so a Yu-Gi-Oh! card must never be offered Magic's etched finish.
      expect(
        missingFinishes(const <CollectionEntry>[], CardGame.yugioh),
        <CardFinish>[CardFinish.nonfoil, CardFinish.foil],
      );
      expect(
        missingFinishes(
          <CollectionEntry>[entry(finish: CardFinish.nonfoil)],
          CardGame.yugioh,
        ),
        <CardFinish>[CardFinish.foil],
      );
    });

    test('offers the Pokemon treatments a card can actually have', () {
      expect(
        missingFinishes(const <CollectionEntry>[], CardGame.pokemon),
        CardGame.pokemon.finishes,
      );
      expect(
        missingFinishes(
          <CollectionEntry>[
            entry(finish: CardFinish.holofoil),
            entry(finish: CardFinish.firstEdition),
          ],
          CardGame.pokemon,
        ),
        <CardFinish>[
          CardFinish.nonfoil,
          CardFinish.reverseHolofoil,
          CardFinish.firstEditionHolofoil,
        ],
      );
    });

    test('ignores a finish the game does not print', () {
      // A Magic entry imported from a file written for another game can carry a
      // finish Magic has no concept of. It must not consume a real suggestion.
      final entries = <CollectionEntry>[entry(finish: CardFinish.holofoil)];
      expect(
        missingFinishes(entries, CardGame.mtg),
        <CardFinish>[CardFinish.nonfoil, CardFinish.foil, CardFinish.etched],
      );
    });

    test('accepts any iterable, not just a list', () {
      expect(
        missingFinishes(
          <CollectionEntry>[entry(finish: CardFinish.nonfoil)].where((_) => true),
          CardGame.mtg,
        ),
        <CardFinish>[CardFinish.foil, CardFinish.etched],
      );
    });
  });
}
