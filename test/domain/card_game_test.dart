// Tests for the vocabulary each game brings with it.
//
//   flutter test test/domain/card_game_test.dart
//
// A game is not just a name and a colour: it decides which finishes a card can
// be owned in, which grades its collectors use, and which axis its allocation
// chart is drawn along. Those three things are what every other layer reads, so
// they are pinned here for every game at once - a new game added later fails
// these tests until it declares them.

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the roster', () {
    test('covers the nine games, and their ids never change', () {
      // The id is written into SQLite rows and SharedPreferences, so renaming
      // one would orphan a collection rather than migrate it.
      expect(CardGame.values.map((g) => g.id), <String>[
        'mtg',
        'pokemon',
        'lorcana',
        'yugioh',
        'onepiece',
        'swu',
        'digimon',
        'dragonball',
        'gundam',
      ]);
    });

    test('every game declares a usable identity', () {
      for (final game in CardGame.values) {
        expect(game.label, isNotEmpty, reason: game.id);
        expect(game.shortLabel, isNotEmpty, reason: game.id);
        expect(game.abbreviation, hasLength(3), reason: game.id);
        expect(game.publisher, isNotEmpty, reason: game.id);
        expect(game.dataSource, isNotEmpty, reason: game.id);
        expect(game.collectionNoun, isNotEmpty, reason: game.id);
        expect(game.catalogueSince, greaterThan(1990), reason: game.id);
      }
    });

    test('no two games share an accent colour', () {
      // The accent tints an entire side of the app, which only works if no two
      // games look alike.
      final accents = CardGame.values.map((g) => g.accent.toARGB32()).toSet();
      expect(accents, hasLength(CardGame.values.length));
    });

    test('resolves ids back to games, and defaults unknown ones to Magic', () {
      expect(CardGame.fromId('lorcana'), CardGame.lorcana);
      expect(CardGame.fromId('yugioh'), CardGame.yugioh);
      expect(CardGame.fromId('nonsense'), CardGame.mtg);
      expect(CardGame.fromId(null), CardGame.mtg);
    });
  });

  group('finishes and grades', () {
    test('Lorcana prints an ordinary card and a cold foil', () {
      expect(CardGame.lorcana.finishes, <CardFinish>[
        CardFinish.nonfoil,
        CardFinish.foil,
      ]);
    });

    test('Lorcana grades with the scale TCGplayer publishes', () {
      expect(CardGame.lorcana.conditions, <CardCondition>[
        CardCondition.nearMint,
        CardCondition.lightPlayed,
        CardCondition.moderatelyPlayed,
        CardCondition.heavilyPlayed,
        CardCondition.damaged,
      ]);
    });

    test('a game never offers another game\'s finishes', () {
      // The failure this prevents is a Magic-only "Etched" appearing on a
      // Lorcana card because the two share the finish enum.
      expect(
        CardGame.lorcana.finishes.map((f) => f.code),
        isNot(contains(CardFinish.etched.code)),
      );
      expect(
        CardGame.pokemon.finishes.map((f) => f.code),
        isNot(contains(CardFinish.etched.code)),
      );
      expect(
        CardGame.mtg.conditions.map((c) => c.code),
        isNot(contains(CardCondition.damaged.code)),
      );
    });

    test('every game offers at least one finish and one grade', () {
      for (final game in CardGame.values) {
        expect(game.finishes, isNotEmpty, reason: game.id);
        expect(game.conditions, isNotEmpty, reason: game.id);
      }
    });

    test('the default finish is the first one declared', () {
      // Every other layer - a new collection entry, a price alert, a history
      // series - falls back to this when the user has not chosen.
      expect(CardGame.lorcana.finishes.first, CardFinish.nonfoil);
      expect(CardGame.yugioh.finishes.first, CardFinish.nonfoil);
    });
  });

  group('rarity tiers across games', () {
    test('every Lorcana rarity lands on a real tier, never Unknown', () {
      // Lorcast's whole vocabulary. "Super_rare" arrives with the underscore
      // and "Legendary", "Epic", "Enchanted" and "Iconic" match none of the
      // keywords the other games use, so before this they all rendered as a
      // grey Unknown badge.
      expect(CardRarity.fromCode('Common'), CardRarity.common);
      expect(CardRarity.fromCode('Uncommon'), CardRarity.uncommon);
      expect(CardRarity.fromCode('Rare'), CardRarity.rare);
      expect(CardRarity.fromCode('Super Rare'), CardRarity.rare);
      expect(CardRarity.fromCode('Legendary'), CardRarity.mythic);
      expect(CardRarity.fromCode('Epic'), CardRarity.mythic);
      expect(CardRarity.fromCode('Iconic'), CardRarity.mythic);
      expect(CardRarity.fromCode('Enchanted'), CardRarity.special);
      expect(CardRarity.fromCode('Promo'), CardRarity.bonus);
    });

    test('the other games keep their own tiers', () {
      expect(CardRarity.fromCode('Mythic Rare'), CardRarity.mythic);
      expect(
        CardRarity.fromCode('Special Illustration Rare'),
        CardRarity.mythic,
      );
      expect(CardRarity.fromCode('Trainer Gallery'), CardRarity.special);
      expect(CardRarity.fromCode('Secret Rare'), CardRarity.mythic);
      // Yu-Gi-Oh!'s long tail still falls through to the rare tier.
      expect(
        CardRarity.fromCode('Duel Terminal Parallel Rare'),
        CardRarity.rare,
      );
      expect(CardRarity.fromCode(''), CardRarity.unknown);
      expect(CardRarity.fromCode(null), CardRarity.unknown);
    });

    test('read the short codes the two Bandai games print', () {
      // One Piece ships a letter or two where the other games ship a word, so
      // none of these reached a tier and every One Piece card in the app wore a
      // grey Unknown badge. Super Rare is the same rung as Yu-Gi-Oh!'s, which
      // the keyword chain already reads as the rare tier, so the two agree.
      expect(CardRarity.fromCode('C'), CardRarity.common);
      expect(CardRarity.fromCode('UC'), CardRarity.uncommon);
      expect(CardRarity.fromCode('R'), CardRarity.rare);
      expect(CardRarity.fromCode('SR'), CardRarity.rare);
      expect(CardRarity.fromCode('L'), CardRarity.mythic);
      expect(CardRarity.fromCode('SEC'), CardRarity.mythic);
      expect(CardRarity.fromCode('P'), CardRarity.bonus);
      expect(CardRarity.fromCode('DON!!'), CardRarity.bonus);
      // Digimon's one rarity word outside the ladder: a promo or a box topper.
      expect(CardRarity.fromCode('None'), CardRarity.special);
      // The codes are matched exactly, so a word that merely starts with one of
      // their letters still goes through the keyword chain.
      expect(CardRarity.fromCode('Special'), CardRarity.special);
      expect(CardRarity.fromCode('Ultra Rare'), CardRarity.rare);
      expect(CardRarity.fromCode('Rare Holo'), CardRarity.rare);
    });
  });

  group('Lorcana inks', () {
    test('names the six inks plus a bucket for cards that have none', () {
      expect(LorcanaInk.values.map((i) => i.label), <String>[
        'Amber',
        'Amethyst',
        'Emerald',
        'Ruby',
        'Sapphire',
        'Steel',
        'Uninked',
      ]);
    });

    test('reads an ink from the wire name or the stored symbol', () {
      expect(LorcanaInk.fromName('Ruby'), LorcanaInk.ruby);
      expect(LorcanaInk.fromName('amethyst'), LorcanaInk.amethyst);
      expect(LorcanaInk.fromSymbol('S'), LorcanaInk.sapphire);
      expect(LorcanaInk.fromSymbol('steel'), LorcanaInk.steel);
    });

    test('anything unreadable is the catch-all, never a real ink', () {
      // Painting an unrecognised card into Amber would put its value in the
      // wrong slice of the chart, which is worse than a labelled bucket.
      expect(LorcanaInk.fromName(null), LorcanaInk.inconsolable);
      expect(LorcanaInk.fromName('rainbow'), LorcanaInk.inconsolable);
      expect(LorcanaInk.fromSymbol('???'), LorcanaInk.inconsolable);
    });

    test('gives every ink its own symbol', () {
      final symbols = LorcanaInk.values.map((i) => i.symbol).toSet();
      expect(symbols, hasLength(LorcanaInk.values.length));
    });
  });

  group('allocation buckets', () {
    test('each game buckets along its own axis', () {
      expect(CardGame.lorcana.colourCategories, LorcanaInk.values);
      expect(CardGame.lorcana.bucketFor('R'), LorcanaInk.ruby);
      expect(CardGame.mtg.bucketFor('R'), ManaColor.red);
      expect(CardGame.pokemon.bucketFor('R'), PokemonType.fire);
      expect(CardGame.yugioh.bucketFor('R'), YgoAttribute.spellTrap);
    });

    test('a two-ink card collapses onto its first ink', () {
      // Lorcast lists inks in printed order, so the bucket is stable rather
      // than dependent on how the list happened to be sorted.
      expect(
        CardGame.lorcana.dominantBucket(<String>['Ruby', 'Sapphire']),
        LorcanaInk.ruby,
      );
      expect(
        CardGame.lorcana.dominantBucket(<String>['Sapphire', 'Ruby']),
        LorcanaInk.sapphire,
      );
    });

    test('a card with no stated ink lands in the catch-all', () {
      expect(
        CardGame.lorcana.dominantBucket(<String>[]),
        LorcanaInk.inconsolable,
      );
    });

    test('the two newest games bucket by the colour the card prints', () {
      // Both are built along their colours - a Fusion World deck may only hold
      // cards that share a colour with its Leader, and a Gundam deck may use two
      // of the five - so the chart has to be a chart of the colour pie rather
      // than one of Unknown.
      expect(CardGame.dragonBall.colourCategories, hasLength(6));
      expect(CardGame.gundam.colourCategories, hasLength(6));
      expect(CardGame.dragonBall.bucketFor('Black'), DragonBallColor.black);
      expect(CardGame.gundam.bucketFor('Purple'), GundamColor.purple);
      // The stored form is the letter, the provider's form is the word, and
      // both resolve to the same bucket.
      expect(CardGame.gundam.bucketFor('W'), GundamColor.white);
      expect(CardGame.dragonBall.bucketFor('R'), DragonBallColor.red);
      // A printing the provider leaves blank is counted in the catch-all rather
      // than guessed into a colour the card has not got.
      expect(CardGame.dragonBall.bucketFor(''), DragonBallColor.noColour);
      expect(CardGame.gundam.bucketFor('nonsense'), GundamColor.noColour);
    });

    test('a stored symbol round-trips back to the same bucket', () {
      // Charts read the symbol off each card and resolve it back, so every
      // category must survive that trip.
      for (final game in CardGame.values) {
        for (final bucket in game.colourCategories) {
          expect(
            game.bucketFor(bucket.symbol).symbol,
            bucket.symbol,
            reason: '${game.id} ${bucket.symbol}',
          );
        }
      }
    });
  });

  group('the games TCGplayer catalogs', () {
    test('print an ordinary card and a foil', () {
      // One Piece, Star Wars: Unlimited and Digimon are all priced under the
      // same two subtypes TCGplayer publishes, which is the same pair Lorcana
      // prints - so the finish vocabulary is the pair rather than a guess.
      for (final game in <CardGame>[
        CardGame.onePiece,
        CardGame.starWarsUnlimited,
        CardGame.digimon,
        CardGame.dragonBall,
        CardGame.gundam,
      ]) {
        expect(game.finishes, <CardFinish>[
          CardFinish.nonfoil,
          CardFinish.foil,
        ], reason: game.id);
        // The first entry is the one a collection entry, an alert and a
        // history series fall back to.
        expect(game.finishes.first, CardFinish.nonfoil, reason: game.id);
      }
    });

    test('grade on the scale TCGplayer publishes', () {
      for (final game in <CardGame>[
        CardGame.onePiece,
        CardGame.starWarsUnlimited,
        CardGame.digimon,
        CardGame.dragonBall,
        CardGame.gundam,
      ]) {
        expect(game.conditions, <CardCondition>[
          CardCondition.nearMint,
          CardCondition.lightPlayed,
          CardCondition.moderatelyPlayed,
          CardCondition.heavilyPlayed,
          CardCondition.damaged,
        ], reason: game.id);
      }
    });

    test('bucket along the axis the game itself uses', () {
      expect(CardGame.onePiece.colourCategories, OnePieceColor.values);
      expect(CardGame.digimon.colourCategories, DigimonColor.values);
      expect(CardGame.starWarsUnlimited.colourCategories, SwuAspect.values);
    });

    test('read a colour from the wire name or the stored symbol', () {
      expect(OnePieceColor.fromName('Green'), OnePieceColor.green);
      expect(OnePieceColor.fromName('Yellow'), OnePieceColor.yellow);
      expect(OnePieceColor.fromSymbol('U'), OnePieceColor.blue);
      expect(DigimonColor.fromName('Purple'), DigimonColor.purple);
      expect(DigimonColor.fromSymbol('W'), DigimonColor.white);
      expect(SwuAspect.fromName('Cunning'), SwuAspect.cunning);
      expect(SwuAspect.fromSymbol('V'), SwuAspect.vigilance);
    });

    test('anything unreadable is the catch-all, never a real colour', () {
      // Painting an unknown card into Red would put its value in the wrong
      // slice of the chart, which is worse than a labelled bucket.
      expect(OnePieceColor.fromName(null), OnePieceColor.noColour);
      expect(OnePieceColor.fromName('rainbow'), OnePieceColor.noColour);
      expect(OnePieceColor.fromSymbol('???'), OnePieceColor.noColour);
      expect(DigimonColor.fromName(null), DigimonColor.white);
      expect(SwuAspect.fromName(null), SwuAspect.unaligned);
    });

    test('a dual-colour card collapses onto the colour it names first', () {
      // The provider lists a card's colours in printed order, so the bucket is
      // stable rather than dependent on how the list happened to be sorted.
      expect(
        CardGame.onePiece.dominantBucket(<String>['Green', 'Red']),
        OnePieceColor.green,
      );
      expect(
        CardGame.digimon.dominantBucket(<String>['Blue', 'Green']),
        DigimonColor.blue,
      );
    });

    test('an Unlimited card is bucketed by its aspect, not its alignment', () {
      // The provider mixes both into one field and lists them in either order,
      // so the aspect - the game's colour pie - has to win whichever comes
      // first, or half the chart would silently become a chart of alignments.
      expect(
        CardGame.starWarsUnlimited.dominantBucket(<String>[
          'Villainy',
          'Command',
        ]),
        SwuAspect.command,
      );
      expect(
        CardGame.starWarsUnlimited.dominantBucket(<String>[
          'Command',
          'Villainy',
        ]),
        SwuAspect.command,
      );
      // A card with no aspect at all is still counted somewhere real.
      expect(
        CardGame.starWarsUnlimited.dominantBucket(<String>['Heroism']),
        SwuAspect.heroism,
      );
      expect(
        CardGame.starWarsUnlimited.dominantBucket(<String>[]),
        SwuAspect.unaligned,
      );
    });

    test('a card names every category it is in, not just the first', () {
      // What a card detail screen draws: a two-colour Leader is two pips.
      expect(
        CardGame.onePiece
            .bucketsOf(<String>['Green', 'Red'])
            .map((ColourBucket b) => b.label),
        <String>['Green', 'Red'],
      );
      // A card with no colour at all shows the bucket it was counted in.
      expect(
        CardGame.onePiece.bucketsOf(<String>[], includeCatchAll: true).single,
        OnePieceColor.noColour,
      );
      expect(
        CardGame.pokemon.bucketsOf(<String>[], includeCatchAll: true).single,
        PokemonType.colorless,
      );
    });
  });
}
