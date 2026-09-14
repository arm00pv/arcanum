import 'package:flutter/material.dart';

/// Anything a collection can be bucketed by for an allocation chart.
///
/// Magic buckets by mana colour, Pokémon by energy type. They are different
/// concepts with the same shape — a symbol, a name and two shades — so the
/// analytics and the UI can treat them uniformly without pretending a Pokémon
/// type is a colour.
abstract interface class ColourBucket {
  /// Single-letter code used for compact display.
  String get symbol;

  /// Human readable name.
  String get label;

  /// Bright accent used for text, glows and chart strokes.
  Color get accent;

  /// Darker companion used for gradients and fills.
  Color get deep;
}

/// The five Magic: The Gathering mana colours, plus colourless.
///
/// [symbol] is the single-letter Scryfall colour code (W/U/B/R/G) and is the
/// canonical way colours are exchanged with the API layer.
enum ManaColor implements ColourBucket {
  white('W', 'White', Color(0xFFF4EAD2), Color(0xFFB99A4E)),
  blue('U', 'Blue', Color(0xFF5AA9E6), Color(0xFF1D6FB8)),
  black('B', 'Black', Color(0xFF9B8BC4), Color(0xFF4A3A6B)),
  red('R', 'Red', Color(0xFFF0664A), Color(0xFFB5341A)),
  green('G', 'Green', Color(0xFF4FC97D), Color(0xFF1F7A45)),
  colorless('C', 'Colorless', Color(0xFFB9C2CF), Color(0xFF6B7480));

  const ManaColor(this.symbol, this.label, this.accent, this.deep);

  @override
  final String symbol;

  @override
  final String label;

  @override
  final Color accent;

  @override
  final Color deep;

  /// Resolves a Scryfall colour code to a [ManaColor].
  static ManaColor fromSymbol(String s) {
    switch (s.toUpperCase()) {
      case 'W':
        return ManaColor.white;
      case 'U':
        return ManaColor.blue;
      case 'B':
        return ManaColor.black;
      case 'R':
        return ManaColor.red;
      case 'G':
        return ManaColor.green;
      default:
        return ManaColor.colorless;
    }
  }

  /// Maps a card's `colorIdentity` list to a deterministic colour bucket.
  ///
  /// Multi-coloured cards are reported as their first (WUBRG-ordered) colour so
  /// that every card lands in exactly one bucket for allocation charts.
  static ManaColor dominant(List<String> colorIdentity) {
    if (colorIdentity.isEmpty) return ManaColor.colorless;
    const order = ['W', 'U', 'B', 'R', 'G'];
    final sorted = [...colorIdentity]
      ..sort(
        (a, b) => order
            .indexOf(a.toUpperCase())
            .compareTo(order.indexOf(b.toUpperCase())),
      );
    return fromSymbol(sorted.first);
  }
}

/// Rarity tiers, with the metallic accents collectors actually associate with
/// each tier.
///
/// Pokémon has dozens of rarity strings where Magic has four, so [fromCode]
/// matches on keywords rather than exact values and collapses them onto the same
/// five tiers the charts understand.
enum CardRarity {
  common('common', 'Common', Color(0xFF98A4B5)),
  uncommon('uncommon', 'Uncommon', Color(0xFFBFC9D6)),
  rare('rare', 'Rare', Color(0xFFD8B44A)),
  mythic('mythic', 'Mythic', Color(0xFFEE6C2D)),
  special('special', 'Special', Color(0xFFB45CE8)),
  bonus('bonus', 'Bonus', Color(0xFF7C5CE8)),
  unknown('unknown', 'Unknown', Color(0xFF7A8290));

  const CardRarity(this.code, this.label, this.color);

  /// Provider rarity string.
  final String code;
  final String label;
  final Color color;

  /// Resolves a rarity string from any game onto a display tier.
  ///
  /// Magic ships `common`/`uncommon`/`rare`/`mythic`/`special`/`bonus`.
  /// Pokémon ships values such as `Rare Holo`, `Double Rare`,
  /// `Illustration Rare`, `Special Illustration Rare`, `Hyper Rare`,
  /// `ACE SPEC Rare` and `Trainer Gallery`. Yu-Gi-Oh! ships its own long tail
  /// — `Super Rare`, `Ultra Rare`, `Secret Rare`, `Ultimate Rare`,
  /// `Starlight Rare`, `Ghost Rare`, `Gold Rare`, `Duel Terminal Parallel
  /// Rare` — which is why the tail of this method falls back to "contains
  /// rare" rather than matching whole strings.
  static CardRarity fromCode(String? c) {
    // Bandai hangs plus signs off a rarity code to mark the parallel or foil
    // treatment of an otherwise ordinary card - Gundam ships C+, U+, R+, LR+
    // and LR++ - and the treatment is a separate price rather than a separate
    // rung, so the signs come off before the code is read.
    final s = (c ?? '').toLowerCase().trim().replaceAll(RegExp(r'\++$'), '');
    if (s.isEmpty) return CardRarity.unknown;

    // Bandai publishes its rarity as a short code and One Piece ships every one
    // of them - C, UC, R, SR, L, SEC and the DON!! deck's own tier - so the
    // codes are read exactly, before the keyword chain below, which shares no
    // word with any of them and would call each one Unknown.
    switch (s) {
      case 'c':
        return CardRarity.common;
      case 'u':
      case 'uc':
        return CardRarity.uncommon;
      case 'r':
        return CardRarity.rare;
      // "Super Rare" is the same rung in One Piece as in Yu-Gi-Oh!, which the
      // chain already reads as the rare tier, so the two chart alike.
      case 'sr':
        return CardRarity.rare;
      // A Leader is the card a deck is built around and a Secret Rare is the
      // set's chase printing: both are the top of the ladder.
      case 'l':
      case 'sec':
      // Gundam's own top rung, above Rare, is the Legend Rare - and its
      // Leader, like Fusion World's, is the card the deck is built around.
      case 'lr':
        return CardRarity.mythic;
      case 'p':
      case 'don!!':
        return CardRarity.bonus;
      // Digimon's word for a printing outside the rarity ladder - a promo, a
      // box topper - which is the tier the app already gives those.
      case 'none':
        return CardRarity.special;
    }

    // Highest tiers first: "special illustration rare" must not match "rare".
    if (s.contains('special illustration') ||
        s.contains('hyper rare') ||
        s.contains('secret') ||
        s.contains('starlight') ||
        s.contains('legend') ||
        s.contains('mythic')) {
      return CardRarity.mythic;
    }
    if (s.contains('illustration') ||
        s.contains('ultra') ||
        s.contains('double rare') ||
        s.contains('ace spec') ||
        s.contains('shiny rare') ||
        s.contains('radiant') ||
        s.contains('amazing') ||
        s.contains('holo') ||
        s == 'rare') {
      return CardRarity.rare;
    }
    // Lorcana's two chase treatments: an Enchanted card is an alternate-art
    // reprint of a card already in the set, which is the same idea as a
    // Pokémon trainer-gallery card and sits in the same tier.
    if (s.contains('trainer gallery') ||
        s.contains('gallery') ||
        s.contains('enchanted')) {
      return CardRarity.special;
    }
    // Lorcana's top of the ordinary ladder. "Legendary" is the highest tier a
    // normal set prints and "Iconic" and "Epic" sit above the usual run, so all
    // three read as the mythic-equivalent rather than as an unknown badge.
    if (s.contains('legendary') || s.contains('iconic') || s.contains('epic')) {
      return CardRarity.mythic;
    }
    // Fusion World's Leader is not a rarer printing of a card in the set - it
    // is a card of its own kind, and it is the one a deck is named after, which
    // is why it grades where One Piece's Leader grades.
    if (s == 'leader') return CardRarity.mythic;
    if (s.contains('promo')) return CardRarity.bonus;
    if (s.contains('uncommon')) return CardRarity.uncommon;
    if (s.contains('common')) return CardRarity.common;
    // Deliberately after `common`: Yu-Gi-Oh!'s "Duel Terminal ... Rare" and
    // "Parallel Rare" variants, and Pokémon's longer rarity names, all reach
    // the rare tier here rather than falling through to `unknown`.
    if (s.contains('rare')) return CardRarity.rare;
    if (s.contains('special')) return CardRarity.special;
    if (s.contains('bonus')) return CardRarity.bonus;
    return CardRarity.unknown;
  }
}

/// Physical finish or variant of a card, which materially changes its price.
///
/// Magic has three; Pokémon has a wider set of print variants, including the
/// 1st Edition and unlimited printings that dominate the value of older sets;
/// Yu-Gi-Oh! has only the ordinary/foil pair.
enum CardFinish {
  nonfoil('nonfoil', 'Non-foil', 'Normal'),
  foil('foil', 'Foil', 'Foil'),
  etched('etched', 'Etched', 'Etched'),
  holofoil('holofoil', 'Holofoil', 'Holo'),
  reverseHolofoil('reverse_holofoil', 'Reverse Holo', 'Rev. Holo'),
  firstEdition('first_edition', '1st Edition', '1st Ed.'),
  firstEditionHolofoil(
    'first_edition_holofoil',
    '1st Ed. Holo',
    '1st Ed. Holo',
  );

  const CardFinish(this.code, this.label, this.shortLabel);

  /// Stable code stored in SQLite.
  final String code;

  /// Full display name.
  final String label;

  /// Compact name for chips and list rows.
  final String shortLabel;

  /// Whether this finish represents a premium/foil treatment.
  bool get isPremium =>
      this != CardFinish.nonfoil && this != CardFinish.firstEdition;

  static CardFinish fromCode(String? c) {
    final s = (c ?? '').toLowerCase();
    for (final f in CardFinish.values) {
      if (f.code == s) return f;
    }
    return CardFinish.nonfoil;
  }
}

/// Condition grades, ordered from best to worst.
///
/// The games use different vocabularies. Magic players grade with the
/// M/NM/EX/GD/LP/PL/PO scale; every other game Arcanum tracks - Pokémon,
/// Yu-Gi-Oh!, Lorcana, One Piece, Digimon and Star Wars: Unlimited - is
/// collected on the NM/LP/MP/HP/DMG scale TCGplayer publishes, because
/// TCGplayer is where those games are bought and sold. That is why those five
/// grades are shared and the Magic-only ones are not. Each game shows only
/// the grades its collectors actually use.
enum CardCondition {
  mint('mint', 'Mint', 'M', {CardGameTag.mtg}),
  nearMint('near_mint', 'Near Mint', 'NM', {
    CardGameTag.mtg,
    CardGameTag.pokemon,
    CardGameTag.yugioh,
    CardGameTag.lorcana,
    CardGameTag.onePiece,
    CardGameTag.digimon,
    CardGameTag.starWarsUnlimited,
    CardGameTag.dragonBall,
    CardGameTag.gundam,
  }),
  excellent('excellent', 'Excellent', 'EX', {CardGameTag.mtg}),
  good('good', 'Good', 'GD', {CardGameTag.mtg}),
  lightPlayed('light_played', 'Lightly Played', 'LP', {
    CardGameTag.mtg,
    CardGameTag.pokemon,
    CardGameTag.yugioh,
    CardGameTag.lorcana,
    CardGameTag.onePiece,
    CardGameTag.digimon,
    CardGameTag.starWarsUnlimited,
    CardGameTag.dragonBall,
    CardGameTag.gundam,
  }),
  moderatelyPlayed('moderately_played', 'Moderately Played', 'MP', {
    CardGameTag.pokemon,
    CardGameTag.yugioh,
    CardGameTag.lorcana,
    CardGameTag.onePiece,
    CardGameTag.digimon,
    CardGameTag.starWarsUnlimited,
    CardGameTag.dragonBall,
    CardGameTag.gundam,
  }),
  heavilyPlayed('heavily_played', 'Heavily Played', 'HP', {
    CardGameTag.pokemon,
    CardGameTag.yugioh,
    CardGameTag.lorcana,
    CardGameTag.onePiece,
    CardGameTag.digimon,
    CardGameTag.starWarsUnlimited,
    CardGameTag.dragonBall,
    CardGameTag.gundam,
  }),
  played('played', 'Played', 'PL', {CardGameTag.mtg}),
  poor('poor', 'Poor', 'PO', {CardGameTag.mtg}),
  damaged('damaged', 'Damaged', 'DMG', {
    CardGameTag.pokemon,
    CardGameTag.yugioh,
    CardGameTag.lorcana,
    CardGameTag.onePiece,
    CardGameTag.digimon,
    CardGameTag.starWarsUnlimited,
    CardGameTag.dragonBall,
    CardGameTag.gundam,
  });

  const CardCondition(this.code, this.label, this.short, this.games);

  /// Stable code stored in SQLite.
  final String code;
  final String label;
  final String short;

  /// Which games recognise this grade.
  final Set<CardGameTag> games;

  /// Rough market multiplier applied to the Near Mint reference price.
  ///
  /// These are conventional grading discounts used by major vendors; they are
  /// deliberately conservative and surfaced in the UI as an estimate.
  double get priceMultiplier => switch (this) {
    CardCondition.mint => 1.05,
    CardCondition.nearMint => 1.0,
    CardCondition.excellent => 0.9,
    CardCondition.good => 0.8,
    CardCondition.lightPlayed => 0.7,
    CardCondition.moderatelyPlayed => 0.62,
    CardCondition.heavilyPlayed => 0.5,
    CardCondition.played => 0.55,
    CardCondition.poor => 0.35,
    CardCondition.damaged => 0.35,
  };

  static CardCondition fromCode(String? c) => CardCondition.values.firstWhere(
    (e) => e.code == c,
    orElse: () => CardCondition.nearMint,
  );
}

/// A game tag used by the condition table.
///
/// Conditions are declared before [CardGame] exists, and importing the domain
/// layer from the theme layer would invert the dependency, so the tag mirrors the
/// game ids instead.
enum CardGameTag {
  mtg('mtg'),
  pokemon('pokemon'),
  yugioh('yugioh'),
  lorcana('lorcana'),
  onePiece('onepiece'),
  digimon('digimon'),
  starWarsUnlimited('swu'),
  dragonBall('dragonball'),
  gundam('gundam');

  const CardGameTag(this.id);
  final String id;
}
