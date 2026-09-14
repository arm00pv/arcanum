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
  ),
  onePiece(
    id: 'onepiece',
    label: 'One Piece Card Game',
    shortLabel: 'One Piece',
    // Three letters, like every other game's badge: the card game abbreviates
    // itself OPCG, and 'OP' alone would sit beside the OP01 a card prints.
    abbreviation: 'OPC',
    publisher: 'Bandai',
    // One Piece's brand is the red of the Jolly Roger against black. Magic
    // already holds the violet end of the switcher and Yu-Gi-Oh! the gold, so
    // the red is free - and it is the colour the game itself uses on every
    // pack, so it reads as the game rather than as a fifth arbitrary hue.
    accent: Color(0xFFE14B3C),
    deep: Color(0xFF7E1F14),
    dataSource: 'TCGplayer',
    catalogueSince: 2022,
    collectionNoun: 'binder',
  ),
  starWarsUnlimited(
    id: 'swu',
    label: 'Star Wars: Unlimited',
    shortLabel: 'Star Wars',
    abbreviation: 'SWU',
    publisher: 'Fantasy Flight Games',
    // Unlimited's own palette is a cold starlight blue on black - the card
    // backs and the set symbols are all that blue - which also keeps it clear
    // of Lorcana's cyan, the nearest neighbour in the switcher.
    accent: Color(0xFF5B8DEF),
    deep: Color(0xFF1E3A73),
    dataSource: 'TCGplayer',
    catalogueSince: 2024,
    collectionNoun: 'binder',
  ),
  digimon(
    id: 'digimon',
    label: 'Digimon Card Game',
    shortLabel: 'Digimon',
    abbreviation: 'DGM',
    publisher: 'Bandai',
    // Digimon's identity is the orange of the original Digivice, which sits
    // between Pokémon's yellow and One Piece's red without being either: the
    // three are only ever seen side by side in the switcher, never in one
    // chart, so they only have to be told apart at a glance.
    accent: Color(0xFFF0812F),
    deep: Color(0xFF8C3D0E),
    dataSource: 'TCGplayer',
    catalogueSince: 2020,
    collectionNoun: 'binder',
  ),
  dragonBall(
    id: 'dragonball',
    label: 'Dragon Ball Super: Fusion World',
    shortLabel: 'Dragon Ball',
    // Fusion World shortens itself to FW on the cards and DBSFW in the shop's
    // own set codes; three letters on a badge want the name of the game rather
    // than the name of the line, and DBS is what the deck boxes say.
    abbreviation: 'DBS',
    publisher: 'Bandai',
    // Dragon Ball's own colour is the orange of a gi, and Digimon's accent is
    // already that orange: the two sit next to each other in the switcher and
    // would read as one game. The dragon the whole series is named for is
    // green, green is unused by every other game here, and it is still the
    // game's own artwork rather than an arbitrary hue chosen to be different.
    accent: Color(0xFF3FBF6A),
    deep: Color(0xFF14572A),
    dataSource: 'TCGplayer',
    catalogueSince: 2024,
    collectionNoun: 'binder',
  ),
  gundam(
    id: 'gundam',
    label: 'Gundam Card Game',
    shortLabel: 'Gundam',
    // The game abbreviates itself GCG - Gundam Card Game - and its sets print
    // GD01, ST11 and SC01, so the initials are what its players already read.
    abbreviation: 'GCG',
    publisher: 'Bandai',
    // The mobile suit is white and steel with a tricolour flash, and the flash
    // is not available: its red is One Piece's accent and its blue is Unlimited's.
    // The steel is: it is lighter than every other game's accent, which is what
    // makes it readable as the Gundam in a switcher of seven saturated hues.
    accent: Color(0xFF9AA7B8),
    deep: Color(0xFF3A4657),
    dataSource: 'TCGplayer',
    catalogueSince: 2025,
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
    CardGame.onePiece => CardGameTag.onePiece,
    CardGame.starWarsUnlimited => CardGameTag.starWarsUnlimited,
    CardGame.digimon => CardGameTag.digimon,
    CardGame.dragonBall => CardGameTag.dragonBall,
    CardGame.gundam => CardGameTag.gundam,
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
    // The three games TCGplayer catalogs directly are priced under exactly two
    // subtypes - "Normal" and "Foil" - which is the same pair Lorcana prints.
    // One Piece's parallel arts are foil-only and so carry the second key
    // alone; a card whose only quote is a foil quote shows as a foil card.
    CardGame.onePiece ||
    CardGame.starWarsUnlimited ||
    CardGame.digimon ||
    CardGame.dragonBall ||
    CardGame.gundam => const [CardFinish.nonfoil, CardFinish.foil],
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
    CardGame.onePiece => OnePieceColor.values,
    CardGame.starWarsUnlimited => SwuAspect.values,
    CardGame.digimon => DigimonColor.values,
    CardGame.dragonBall => DragonBallColor.values,
    CardGame.gundam => GundamColor.values,
  };

  /// Resolves a stored symbol to this game's category.
  ColourBucket bucketFor(String symbol) => switch (this) {
    CardGame.mtg => ManaColor.fromSymbol(symbol),
    CardGame.pokemon => PokemonType.fromSymbol(symbol),
    CardGame.yugioh => YgoAttribute.fromSymbol(symbol),
    CardGame.lorcana => LorcanaInk.fromSymbol(symbol),
    CardGame.onePiece => OnePieceColor.fromSymbol(symbol),
    CardGame.starWarsUnlimited => SwuAspect.fromSymbol(symbol),
    CardGame.digimon => DigimonColor.fromSymbol(symbol),
    CardGame.dragonBall => DragonBallColor.fromSymbol(symbol),
    CardGame.gundam => GundamColor.fromSymbol(symbol),
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
      // One Piece and Digimon print a card in one colour, or in two when it is
      // a dual-colour Leader or a card with a splash. The provider lists them
      // in the order the card prints them, so the first entry is the card's
      // primary colour and the bucket is stable between downloads.
      CardGame.onePiece => OnePieceColor.fromName(values.first),
      CardGame.digimon => DigimonColor.fromName(values.first),
      // Fusion World stamps a card with one of five colours and a Leader with
      // one or two; Gundam allows a deck two colours and prints the pair in
      // the order the card shows them, so the first entry is the primary one in
      // both games and the bucket is stable between downloads.
      CardGame.dragonBall => DragonBallColor.fromName(values.first),
      CardGame.gundam => GundamColor.fromName(values.first),
      // Star Wars: Unlimited is the one game here whose category field mixes
      // two different things: a card has one of four aspects (Vigilance,
      // Command, Aggression, Cunning) and, separately, an alignment (Heroism
      // or Villainy). Bucketing on the first entry alone would split the chart
      // by alignment for every card the provider happens to list that way, so
      // the aspect wins whenever there is one - it is the colour pie of the
      // game - and the alignment is the bucket only for cards that have no
      // aspect at all.
      CardGame.starWarsUnlimited => SwuAspect.dominant(values),
    };
  }

  /// This game's categories for a card's raw provider values.
  ///
  /// The whole list, in the order the provider names them and without
  /// duplicates, which is what a card detail screen draws: a two-colour One
  /// Piece Leader is two pips, not one.
  ///
  /// [includeCatchAll] adds the game's own catch-all bucket for a card that
  /// names no category at all - a Pokémon Trainer, a Yu-Gi-Oh! Spell, a Magic
  /// land - so a card with no colour shows the bucket it was counted in rather
  /// than no pips at all.
  List<ColourBucket> bucketsOf(
    List<String> values, {
    bool includeCatchAll = false,
  }) {
    final out = <ColourBucket>[];
    for (final value in values) {
      final bucket = bucketFor(value);
      if (!out.contains(bucket)) out.add(bucket);
    }
    if (out.isEmpty && includeCatchAll) out.add(bucketFor(''));
    return out;
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

/// The six colours of the One Piece Card Game, plus the bucket for cards with
/// none.
///
/// One Piece prints exactly six colours and they are the game's whole colour
/// pie: a Leader is one or two of them, and every deck is built along them.
/// Dual-colour cards collapse onto the colour the provider names first, which
/// is the order the card prints.
///
/// [noColour] is the catch-all. The provider sends a colour for every card it
/// catalogs, so nothing in a set lands there; promo printings that carry no
/// colour metadata at all do, and they are counted rather than painted into a
/// colour they are not.
enum OnePieceColor implements ColourBucket {
  red('R', 'Red', Color(0xFFE4573D), Color(0xFF8E2A18)),
  green('G', 'Green', Color(0xFF3FAF6A), Color(0xFF186B3C)),
  blue('U', 'Blue', Color(0xFF4C8DE8), Color(0xFF1D4E96)),
  purple('P', 'Purple', Color(0xFF9B6BE0), Color(0xFF4E2E85)),
  black('B', 'Black', Color(0xFF7E7A99), Color(0xFF3A3750)),
  yellow('Y', 'Yellow', Color(0xFFEFC03C), Color(0xFF9A7412)),
  noColour('N', 'No colour', Color(0xFF8C9AAE), Color(0xFF4A5566));

  const OnePieceColor(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps the provider's \`Color\` field - "Red", "Green;Red" split into its
  /// parts - to a palette entry.
  static OnePieceColor fromName(String? name) {
    switch ((name ?? '').toLowerCase().trim()) {
      case 'red':
        return OnePieceColor.red;
      case 'green':
        return OnePieceColor.green;
      case 'blue':
        return OnePieceColor.blue;
      case 'purple':
        return OnePieceColor.purple;
      case 'black':
        return OnePieceColor.black;
      case 'yellow':
        return OnePieceColor.yellow;
      default:
        return OnePieceColor.noColour;
    }
  }

  /// Resolves a stored symbol, or the full colour name, back to a colour.
  ///
  /// Both spellings are accepted because both are written: the card carries the
  /// provider's word, while anything Arcanum itself stores is the letter.
  static OnePieceColor fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final colour in OnePieceColor.values) {
      if (colour.symbol == s) return colour;
    }
    return fromName(s);
  }
}

/// The six colours of the Digimon Card Game, plus White.
///
/// Digimon prints Red, Blue, Yellow, Green, Black and Purple, and every deck is
/// built along them. White is not a seventh colour in the same sense: it is what
/// the game prints on cards that sit outside the colour pie - the option cards
/// and the special printings - so it is both a real value in the data and the
/// bucket an unknown colour lands in. Nothing else uses it, and a card the
/// provider leaves blank is counted as White rather than guessed at.
enum DigimonColor implements ColourBucket {
  red('R', 'Red', Color(0xFFE4573D), Color(0xFF8E2A18)),
  blue('U', 'Blue', Color(0xFF4C8DE8), Color(0xFF1D4E96)),
  yellow('Y', 'Yellow', Color(0xFFEFC03C), Color(0xFF9A7412)),
  green('G', 'Green', Color(0xFF3FAF6A), Color(0xFF186B3C)),
  black('B', 'Black', Color(0xFF7E7A99), Color(0xFF3A3750)),
  purple('P', 'Purple', Color(0xFF9B6BE0), Color(0xFF4E2E85)),
  white('W', 'White', Color(0xFFC3CCDA), Color(0xFF6B7480));

  const DigimonColor(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps the provider's \`Color\` field to a palette entry.
  static DigimonColor fromName(String? name) {
    switch ((name ?? '').toLowerCase().trim()) {
      case 'red':
        return DigimonColor.red;
      case 'blue':
        return DigimonColor.blue;
      case 'yellow':
        return DigimonColor.yellow;
      case 'green':
        return DigimonColor.green;
      case 'black':
        return DigimonColor.black;
      case 'purple':
        return DigimonColor.purple;
      default:
        return DigimonColor.white;
    }
  }

  /// Resolves a stored symbol, or the full colour name, back to a colour.
  static DigimonColor fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final colour in DigimonColor.values) {
      if (colour.symbol == s) return colour;
    }
    return fromName(s);
  }
}

/// The five colours of the Dragon Ball Super Card Game: Fusion World.
///
/// Fusion World prints Red, Blue, Green, Yellow and Black, and its Leader is
/// one or two of them: a deck may only contain cards that share a colour with
/// its Leader, which is the same rule One Piece plays under and the reason both
/// formats hold the Leader outside the deck.
///
/// [noColour] is the catch-all for a printing the provider leaves blank - the
/// tournament and event promos, mostly - which is counted rather than guessed
/// into a colour the card has not got.
enum DragonBallColor implements ColourBucket {
  red('R', 'Red', Color(0xFFE4573D), Color(0xFF8E2A18)),
  blue('U', 'Blue', Color(0xFF4C8DE8), Color(0xFF1D4E96)),
  green('G', 'Green', Color(0xFF3FAF6A), Color(0xFF186B3C)),
  yellow('Y', 'Yellow', Color(0xFFEFC03C), Color(0xFF9A7412)),
  black('B', 'Black', Color(0xFF7E7A99), Color(0xFF3A3750)),
  noColour('N', 'No colour', Color(0xFF8C9AAE), Color(0xFF4A5566));

  const DragonBallColor(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps the provider's Color field to a palette entry.
  static DragonBallColor fromName(String? name) {
    switch ((name ?? '').toLowerCase().trim()) {
      case 'red':
        return DragonBallColor.red;
      case 'blue':
        return DragonBallColor.blue;
      case 'green':
        return DragonBallColor.green;
      case 'yellow':
        return DragonBallColor.yellow;
      case 'black':
        return DragonBallColor.black;
      default:
        return DragonBallColor.noColour;
    }
  }

  /// Resolves a stored symbol, or the full colour name, back to a colour.
  static DragonBallColor fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final colour in DragonBallColor.values) {
      if (colour.symbol == s) return colour;
    }
    return fromName(s);
  }
}

/// The five colours of the Gundam Card Game.
///
/// The game prints Blue, Green, Red, White and Purple, and a deck may use two
/// of them: a card's colour decides whether a deck can play it at all, which
/// makes it the same kind of category as One Piece's colour or Unlimited's
/// aspect rather than a cosmetic detail.
///
/// [noColour] is the catch-all. The provider states a colour for every card in
/// a set, so nothing in a set lands there; a printing it leaves blank does.
enum GundamColor implements ColourBucket {
  blue('U', 'Blue', Color(0xFF4C8DE8), Color(0xFF1D4E96)),
  green('G', 'Green', Color(0xFF3FAF6A), Color(0xFF186B3C)),
  red('R', 'Red', Color(0xFFE4573D), Color(0xFF8E2A18)),
  white('W', 'White', Color(0xFFC3CCDA), Color(0xFF6B7480)),
  purple('P', 'Purple', Color(0xFF9B6BE0), Color(0xFF4E2E85)),
  noColour('N', 'No colour', Color(0xFF8C9AAE), Color(0xFF4A5566));

  const GundamColor(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Maps the provider's Color field to a palette entry.
  static GundamColor fromName(String? name) {
    switch ((name ?? '').toLowerCase().trim()) {
      case 'blue':
        return GundamColor.blue;
      case 'green':
        return GundamColor.green;
      case 'red':
        return GundamColor.red;
      case 'white':
        return GundamColor.white;
      case 'purple':
        return GundamColor.purple;
      default:
        return GundamColor.noColour;
    }
  }

  /// Resolves a stored symbol, or the full colour name, back to a colour.
  static GundamColor fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final colour in GundamColor.values) {
      if (colour.symbol == s) return colour;
    }
    return fromName(s);
  }
}

/// The six aspects of Star Wars: Unlimited.
///
/// An aspect is the game's colour pie - it decides which cards a deck may
/// play - but the provider's \`Aspect\` field mixes two different things in one
/// list: four of the values are aspects proper (Vigilance, Command, Aggression,
/// Cunning) and two are alignments (Heroism, Villainy). Most cards carry one of
/// each, so a chart that bucketed on the first entry the provider happened to
/// list would silently become a chart of alignments for half the set.
///
/// [dominant] therefore prefers an aspect and falls back to an alignment, which
/// makes the allocation chart a chart of the colour pie with the handful of
/// alignment-only cards in buckets of their own.
enum SwuAspect implements ColourBucket {
  vigilance('V', 'Vigilance', Color(0xFF4C8DE8), Color(0xFF1D4E96)),
  command('C', 'Command', Color(0xFF3FAF6A), Color(0xFF186B3C)),
  aggression('A', 'Aggression', Color(0xFFE4573D), Color(0xFF8E2A18)),
  cunning('N', 'Cunning', Color(0xFFEFC03C), Color(0xFF9A7412)),
  heroism('H', 'Heroism', Color(0xFFE8D9A8), Color(0xFF8A7128)),
  villainy('D', 'Villainy', Color(0xFF7E7A99), Color(0xFF3A3750)),
  unaligned('U', 'Unaligned', Color(0xFF8C9AAE), Color(0xFF4A5566));

  const SwuAspect(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// The four aspects proper, in the order the game prints them.
  static const List<SwuAspect> aspects = <SwuAspect>[
    SwuAspect.vigilance,
    SwuAspect.command,
    SwuAspect.aggression,
    SwuAspect.cunning,
  ];

  /// Maps the provider's \`Aspect\` entry to a palette entry.
  static SwuAspect fromName(String? name) {
    switch ((name ?? '').toLowerCase().trim()) {
      case 'vigilance':
        return SwuAspect.vigilance;
      case 'command':
        return SwuAspect.command;
      case 'aggression':
        return SwuAspect.aggression;
      case 'cunning':
        return SwuAspect.cunning;
      case 'heroism':
        return SwuAspect.heroism;
      case 'villainy':
        return SwuAspect.villainy;
      default:
        return SwuAspect.unaligned;
    }
  }

  /// Resolves a stored symbol, or the full aspect name, back to an aspect.
  static SwuAspect fromSymbol(String symbol) {
    final s = symbol.trim().toUpperCase();
    for (final aspect in SwuAspect.values) {
      if (aspect.symbol == s) return aspect;
    }
    return fromName(s);
  }

  /// Picks the bucket a card belongs to from every value it names.
  ///
  /// The first aspect wins over any alignment, and a card with no aspect at all
  /// is bucketed by its alignment. A card with neither is unaligned.
  static SwuAspect dominant(List<String> values) {
    SwuAspect? alignment;
    for (final value in values) {
      final aspect = fromName(value);
      if (aspects.contains(aspect)) return aspect;
      if (aspect != SwuAspect.unaligned) alignment ??= aspect;
    }
    return alignment ?? SwuAspect.unaligned;
  }
}
