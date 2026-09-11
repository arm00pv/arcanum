import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/mana.dart';

/// The trading card games Arcanum supports.
///
/// Every game owns its own catalogue, its own collection and its own analytics.
/// Nothing is merged across games: a Pokémon collection and a Magic collection
/// are separate vaults that happen to live in the same app.
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
  CardGameTag get tag =>
      this == CardGame.mtg ? CardGameTag.mtg : CardGameTag.pokemon;

  /// The finishes and print variants that physically exist for this game.
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
      };

  /// The condition grades recognised by this game's collectors.
  List<CardCondition> get conditions =>
      CardCondition.values.where((c) => c.games.contains(tag)).toList();

  /// The categories used by this game's allocation charts.
  ///
  /// Magic buckets by mana colour, Pokémon by energy type.
  List<ColourBucket> get colourCategories =>
      this == CardGame.mtg ? ManaColor.values : PokemonType.values;

  /// Resolves a stored symbol to this game's category.
  ColourBucket bucketFor(String symbol) => this == CardGame.mtg
      ? ManaColor.fromSymbol(symbol)
      : PokemonType.fromSymbol(symbol);

  /// Picks the single category a card belongs to.
  ///
  /// [values] is a Magic `colorIdentity` or a Pokémon `types` list. Multi-value
  /// cards collapse onto their first entry so every card lands in exactly one
  /// bucket.
  ColourBucket dominantBucket(List<String> values) {
    if (values.isEmpty) return bucketFor('');
    if (this == CardGame.mtg) return ManaColor.dominant(values);
    // Pokémon types have no canonical order, so sort for determinism.
    final sorted = [...values]..sort();
    return PokemonType.fromName(sorted.first);
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
