import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/mana.dart';

/// The trading card games Arcanum supports.
///
/// Every game owns its own catalogue, its own collection and its own analytics.
/// Nothing is merged across games: a Pokémon collection, a Magic collection and
/// a Yu-Gi-Oh! collection are separate vaults that happen to live in the same
/// app.
///
/// [id] is the value persisted in SQLite and in SharedPreferences, so it must
/// never change.
enum CardGame {
  mtg(
    id: 'mtg',
    label: 'Magic: The Gathering',
    shortLabel: 'Magic',
    abbreviation: 'MTG',
    publisher: 'Wizards of the Coast',
    accent: Color(0xFF8B6CF6),
    deep: Color(0xFF4A3A9E),
    dataSource: 'Scryfall',
    catalogueSince: 1993,
    collectionNoun: 'binder',
  ),
  pokemon(
    id: 'pokemon',
    label: 'Pokémon Trading Card Game',
    shortLabel: 'Pokémon',
    abbreviation: 'PKM',
    publisher: 'The Pokémon Company',
    accent: Color(0xFFF2B705),
    deep: Color(0xFFB3541E),
    dataSource: 'TCGdex',
    catalogueSince: 1999,
    collectionNoun: 'binder',
  ),
  lorcana(
    id: 'lorcana',
    label: 'Disney Lorcana TCG',
    shortLabel: 'Lorcana',
    abbreviation: 'LRC',
    publisher: 'Ravensburger',
    // Lorcana's own identity is the ink a card is played from, and its brand
    // runs purple-to-teal. Purple would sit too close to Magic's violet in the
    // game switcher and the allocation charts, so the accent is the cyan end of
    // that iridescent range - distinct at a glance from all three other games.
    accent: Color(0xFF2BC4D4),
    deep: Color(0xFF0E5A66),
    dataSource: 'Lorcast',
    catalogueSince: 2023,
    collectionNoun: 'binder',
  ),
  yugioh(
    id: 'yugioh',
    label: 'Yu-Gi-Oh! Trading Card Game',
    shortLabel: 'Yu-Gi-Oh!',
    abbreviation: 'YGO',
    publisher: 'Konami',
    // Yu-Gi-Oh!'s identity colour is the brown-gold of the Millennium Items
    // rather than a flat gold: it has to sit next to Pokémon's bright
    // 0xFFF2B705 in the game switcher and stay distinguishable, so it is
    // deliberately darker and browner. Both shades clear 4.5:1 against the dark
    // theme's surfaces, which is what the accent is used for as text.
    accent: Color(0xFFC9A227),
    deep: Color(0xFF6B4A12),
    dataSource: 'YGOPRODeck',
    catalogueSince: 1999,
    collectionNoun: 'binder',
  );

  const CardGame({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.abbreviation,
    required this.publisher,
    required this.accent,
    required this.deep,
    required this.dataSource,
    required this.catalogueSince,
    required this.collectionNoun,
  });

  /// Stable identifier stored in the database and in preferences.
  final String id;

  /// Full display name.
  final String label;

  /// Compact name for tabs and switches.
  final String shortLabel;

  /// Three-letter code used on badges.
  final String abbreviation;

  /// Rights holder, shown in the About section.
  final String publisher;

  /// The game's signature colour, which tints its side of the app.
  final Color accent;

  /// Darker companion used for gradients.
  final Color deep;

  /// Where the card catalogue comes from, credited in the UI.
  final String dataSource;

  /// Year the game's first set was printed.
  final int catalogueSince;

  /// Word used for a storage location in this game's UI.
  final String collectionNoun;

  /// The matching tag used by the shared enum tables.
  ///
  /// Named [tag] rather than reusing the game itself because the condition and
  /// finish tables live in the theme layer, which must not import the domain.
  CardGameTag get tag => switch (this) {
    CardGame.mtg => CardGameTag.mtg,
    CardGame.pokemon => CardGameTag.pokemon,
    CardGame.yugioh => CardGameTag.yugioh,
    CardGame.lorcana => CardGameTag.lorcana,
  };

  /// The finishes and print variants that physically exist for this game.
  ///
  /// The first entry is the one every other layer treats as the default: a
  /// collection entry, a price alert and a history series all fall back to it
  /// when the user has not chosen a finish.
  List<CardFinish> get finishes => switch (this) {
    CardGame.mtg => const [
      CardFinish.nonfoil,
      CardFinish.foil,
      CardFinish.etched,
    ],
    CardGame.pokemon => const [
      CardFinish.nonfoil,
      CardFinish.holofoil,
      CardFinish.reverseHolofoil,
      CardFinish.firstEdition,
      CardFinish.firstEditionHolofoil,
    ],
    // Yu-Gi-Oh! prints exactly two things: ordinary cards and foil
    // treatments. The provider folds every foil treatment - Ultra, Secret,
    // Ultimate, Ghost, Starlight - into one price, so the app offers the
    // pair a collector actually sorts by rather than a dozen rarities it
    // could not price apart.
    CardGame.yugioh => const [CardFinish.nonfoil, CardFinish.foil],
    // Lorcana prints exactly two things: the ordinary card and the cold
    // foil, which every card in a set has. There is no etched or reverse
    // treatment to tell apart, so the pair is the whole vocabulary.
    CardGame.lorcana => const [CardFinish.nonfoil, CardFinish.foil],
  };

  /// The condition grades recognised by this game's collectors.
  List<CardCondition> get conditions =>
      CardCondition.values.where((c) => c.games.contains(tag)).toList();

  /// The categories used by this game's allocation charts.
  ///
  /// Magic buckets by mana colour, Pokémon by energy type, Yu-Gi-Oh! by monster
  /// attribute and Lorcana by the ink a card is played from.
  List<ColourBucket> get colourCategories => switch (this) {
    CardGame.mtg => ManaColor.values,
    CardGame.pokemon => PokemonType.values,
    CardGame.yugioh => YgoAttribute.values,
    CardGame.lorcana => LorcanaInk.values,
  };

  /// Resolves a stored symbol to this game's category.
  ColourBucket bucketFor(String symbol) => switch (this) {
    CardGame.mtg => ManaColor.fromSymbol(symbol),
    CardGame.pokemon => PokemonType.fromSymbol(symbol),
    CardGame.yugioh => YgoAttribute.fromSymbol(symbol),
    CardGame.lorcana => LorcanaInk.fromSymbol(symbol),
  };

  /// Picks the single category a card belongs to.
  ///
  /// [values] is a Magic `colorIdentity`, a Pokémon `types` list or a Yu-Gi-Oh!
  /// attribute list. Multi-value cards collapse onto their first entry so every
  /// card lands in exactly one bucket, and a card with no category at all lands
  /// in that game's documented catch-all rather than throwing.
  ColourBucket dominantBucket(List<String> values) {
    if (values.isEmpty) return bucketFor('');
    return switch (this) {
      CardGame.mtg => ManaColor.dominant(values),
      // Pokémon types have no canonical order, so sort for determinism.
      CardGame.pokemon => PokemonType.fromName(([...values]..sort()).first),
      // A Yu-Gi-Oh! card carries at most one attribute, so there is nothing to
      // collapse; the first entry is the only entry.
      CardGame.yugioh => YgoAttribute.fromName(values.first),
      // Lorcana cards are one or two inks. Two-ink cards collapse onto their
      // first ink, which Lorcast lists in the order the card prints it, so the
      // bucket is stable rather than dependent on sort order.
      CardGame.lorcana => LorcanaInk.fromName(values.first),
    };
  }

  LinearGradient get gradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, deep],
  );

  /// Resolves a persisted id, defaulting to Magic.
  static CardGame fromId(String? id) {
    for (final g in CardGame.values) {
      if (g.id == id) return g;
    }
    return CardGame.mtg;
  }
}

/// The eleven Pokémon energy types.
///
/// These are not colours — they are types — but they play exactly the same role
/// in allocation charts, so they implement [ColourBucket] alongside
/// [ManaColor] and the analytics stay game-agnostic.
enum PokemonType implements ColourBucket {
  grass('G', 'Grass', Color(0xFF5FBF6A), Color(0xFF2C7A3A)),
  fire('R', 'Fire', Color(0xFFF0664A), Color(0xFFB5341A)),
  water('W', 'Water', Color(0xFF5AA9E6), Color(0xFF1D6FB8)),
  lightning('L', 'Lightning', Color(0xFFF5C542), Color(0xFFB38A00)),
  psychic('P', 'Psychic', Color(0xFFC77DD6), Color(0xFF7B3F8C)),
  fighting('F', 'Fighting', Color(0xFFD98B5F), Color(0xFF9C4F26)),
  darkness('D', 'Darkness', Color(0xFF7A7F94), Color(0xFF3A3F52)),
  metal('M', 'Metal', Color(0xFF9FB0BF), Color(0xFF5A6673)),
  dragon('N', 'Dragon', Color(0xFFD8B44A), Color(0xFF8A6A12)),
  fairy('Y', 'Fairy', Color(0xFFF2A0C0), Color(0xFFB3557F)),
  colorless('C', 'Colorless', Color(0xFFB9C2CF), Color(0xFF6B7480));

  const PokemonType(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps a Pokémon TCG `types` entry to its palette entry.
  ///
  /// Trainer and Energy cards carry no type at all, and land in [colorless].
  static PokemonType fromName(String? type) {
    switch ((type ?? '').toLowerCase().trim()) {
      case 'grass':
        return PokemonType.grass;
      case 'fire':
        return PokemonType.fire;
      case 'water':
        return PokemonType.water;
      case 'lightning':
        return PokemonType.lightning;
      case 'psychic':
        return PokemonType.psychic;
      case 'fighting':
        return PokemonType.fighting;
      case 'darkness':
        return PokemonType.darkness;
      case 'metal':
        return PokemonType.metal;
      case 'dragon':
        return PokemonType.dragon;
      case 'fairy':
        return PokemonType.fairy;
      default:
        return PokemonType.colorless;
    }
  }

  /// Resolves a stored symbol back to a type.
  static PokemonType fromSymbol(String symbol) {
    for (final t in PokemonType.values) {
      if (t.symbol == symbol.toUpperCase()) return t;
    }
    return PokemonType.colorless;
  }
}

/// The six Lorcana inks, plus the bucket for cards that have none.
///
/// Ink is the only thing a Lorcana collection can meaningfully be split by: it
/// is the game's colour pie, printed on the card's frame, and decks are built
/// along it. Most cards are a single ink; a few are two, and those collapse onto
/// their first.
///
/// [inconsolable] is the catch-all, in the same spirit as Yu-Gi-Oh!'s
/// [YgoAttribute.spellTrap]: a card whose ink the provider does not state must
/// not be painted into an ink it is not, so it gets a bucket of its own that
/// says so rather than inflating Amber's slice of the chart.
enum LorcanaInk implements ColourBucket {
  amber('A', 'Amber', Color(0xFFE8A33D), Color(0xFF9A6212)),
  amethyst('M', 'Amethyst', Color(0xFF9B6BD6), Color(0xFF5A2E8C)),
  emerald('E', 'Emerald', Color(0xFF3FA76B), Color(0xFF1B6B3F)),
  ruby('R', 'Ruby', Color(0xFFD9455F), Color(0xFF8C1F35)),
  sapphire('S', 'Sapphire', Color(0xFF4A8FE0), Color(0xFF1F4E8C)),
  steel('T', 'Steel', Color(0xFF8A9BAE), Color(0xFF4A5568)),
  inconsolable('X', 'Uninked', Color(0xFF6B7480), Color(0xFF39414D));

  const LorcanaInk(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps Lorcast's `ink` or `inks` entry to its palette entry.
  static LorcanaInk fromName(String? ink) {
    switch ((ink ?? '').toLowerCase().trim()) {
      case 'amber':
        return LorcanaInk.amber;
      case 'amethyst':
        return LorcanaInk.amethyst;
      case 'emerald':
        return LorcanaInk.emerald;
      case 'ruby':
        return LorcanaInk.ruby;
      case 'sapphire':
        return LorcanaInk.sapphire;
      case 'steel':
        return LorcanaInk.steel;
      default:
        return LorcanaInk.inconsolable;
    }
  }

  /// Resolves a stored symbol, or the full ink name, back to an ink.
  ///
  /// Both spellings are accepted because both are written: the catalogue keeps
  /// the single-letter symbol on the card, while the provider's wire value is
  /// the full word.
  static LorcanaInk fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final ink in LorcanaInk.values) {
      if (ink.symbol == s) return ink;
    }
    return fromName(s);
  }
}

/// The seven Yu-Gi-Oh! monster attributes, plus the bucket for cards that have
/// none.
///
/// An attribute is printed in the top-right corner of a monster's frame and is
/// the only thing a Yu-Gi-Oh! collection can meaningfully be split by, so it
/// plays the same role here that a mana colour plays in Magic and an energy type
/// plays in Pokémon.
///
/// [spellTrap] is the deliberate exception. Spell and Trap cards have no
/// attribute at all — the provider omits the field entirely — and they are not a
/// rounding error: they are roughly half of every set. [ColourBucket] has no
/// notion of "unknown", and folding them into one of the seven would paint that
/// attribute's slice of the allocation chart with cards that are not in it, so
/// the catch-all is a bucket of its own and says what it holds. Nothing else
/// uses it: [fromName] and [fromSymbol] return a real attribute for every value
/// the provider can send.
enum YgoAttribute implements ColourBucket {
  dark('D', 'Dark', Color(0xFF9A7BD6), Color(0xFF4A2E7A)),
  light('L', 'Light', Color(0xFFF0D97A), Color(0xFFB08A1E)),
  earth('E', 'Earth', Color(0xFFB98A5A), Color(0xFF7A5227)),
  water('W', 'Water', Color(0xFF5AA9E6), Color(0xFF1D6FB8)),
  fire('F', 'Fire', Color(0xFFF0664A), Color(0xFFB5341A)),
  wind('N', 'Wind', Color(0xFF5FBF6A), Color(0xFF2C7A3A)),
  divine('V', 'Divine', Color(0xFFFFE29A), Color(0xFFA87A16)),
  spellTrap('S', 'Spell / Trap', Color(0xFF8C9AAE), Color(0xFF4A5566));

  const YgoAttribute(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps a card's `attribute` field to its palette entry.
  ///
  /// The provider sends the attribute as an upper-case word ("DARK", "LIGHT")
  /// and omits the key entirely on Spell and Trap cards, so [spellTrap] is the
  /// answer for both a missing field and anything unrecognised. Guessing an
  /// attribute for a card that has none would put value in the wrong slice of
  /// the chart, which is worse than a slice labelled "Spell / Trap".
  static YgoAttribute fromName(String? attribute) {
    switch ((attribute ?? '').toLowerCase().trim()) {
      case 'dark':
        return YgoAttribute.dark;
      case 'light':
        return YgoAttribute.light;
      case 'earth':
        return YgoAttribute.earth;
      case 'water':
        return YgoAttribute.water;
      case 'fire':
        return YgoAttribute.fire;
      case 'wind':
        return YgoAttribute.wind;
      case 'divine':
        return YgoAttribute.divine;
      default:
        return YgoAttribute.spellTrap;
    }
  }

  /// Resolves a stored symbol back to an attribute.
  ///
  /// Accepts both the single-letter [symbol] and the full attribute name,
  /// because the two are used in different places: charts and pips key off the
  /// letter, while the wire value ("DARK") is what the catalogue stores on the
  /// card and what the card rows feed back in.
  static YgoAttribute fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final a in YgoAttribute.values) {
      if (a.symbol == s) return a;
    }
    return fromName(s);
  }
}
