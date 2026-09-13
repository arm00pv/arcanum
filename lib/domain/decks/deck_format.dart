import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// One way a game's decks are built and judged.
///
/// A format is data, not code: every game's rules are the same handful of
/// numbers plus a couple of flags, so a new format is a line here rather than a
/// subclass. The one rule that genuinely differs per game - what may be held in
/// unlimited copies - is a predicate, because it cannot be expressed as a
/// number for any of them.
class DeckFormat {
  const DeckFormat({
    required this.id,
    required this.label,
    required this.game,
    required this.minCards,
    this.maxCards,
    this.maxCopies = 4,
    this.singleton = false,
    this.hasCommander = false,
    this.sideboardSize = 0,
    this.usesColourIdentity = false,
    this.banListQuery,
    this.unlimited,
    this.notes,
  });

  /// Stable identifier, stored in the database.
  final String id;

  /// What the collector sees.
  final String label;

  final CardGame game;

  /// Cards the main board must hold at least.
  final int minCards;

  /// Cards it may hold at most, when the format caps it.
  final int? maxCards;

  /// Copies of one card allowed, ignoring [unlimited].
  final int maxCopies;

  /// True when every card but the commander must be unique (Commander, Brawl).
  final bool singleton;

  /// True when the deck names a commander, which the colour identity comes
  /// from and which counts towards the deck size.
  final bool hasCommander;

  /// Cards allowed in the sideboard.
  final int sideboardSize;

  /// True when every card must fit the commander's colour identity.
  final bool usesColourIdentity;

  /// Scryfall search that lists this format's banned cards, when the format has
  /// a list we can fetch. Null means the ban list is not checked, and the app
  /// says so rather than implying the deck is legal.
  final String? banListQuery;

  /// Cards that may be held in any number.
  ///
  /// The rule is a name or type test rather than a count: Magic allows any
  /// number of basic lands, Pokemon any number of basic Energy, and neither can
  /// be recognised by a number.
  final bool Function(TcgCard card)? unlimited;

  /// Anything worth saying about the format that a number cannot.
  final String? notes;

  /// True when the format has a ban list this app can check.
  bool get checksBanList => banListQuery != null;

  /// True when the deck has a sideboard at all.
  bool get hasSideboard => sideboardSize > 0;
}

/// Magic's basic lands, which are exempt from the four-copy rule.
const _mtgBasics = <String>{
  'Plains',
  'Island',
  'Swamp',
  'Mountain',
  'Forest',
  'Wastes',
  'Snow-Covered Plains',
  'Snow-Covered Island',
  'Snow-Covered Swamp',
  'Snow-Covered Mountain',
  'Snow-Covered Forest',
};

/// True for a basic land, by name or by type line.
bool _isBasicLand(TcgCard card) {
  if (_mtgBasics.contains(card.name)) return true;
  final type = card.typeLine ?? '';
  return type.startsWith('Basic Land') || type.contains('Basic Land —');
}

/// True for a basic Energy card.
///
/// Pokemon prints them under a handful of names and marks them in the type
/// line; both are checked because the provider does not always give both.
bool _isBasicEnergy(TcgCard card) {
  final type = card.typeLine ?? '';
  if (type.contains('Basic Energy')) return true;
  return card.name.endsWith(' Energy') &&
      const <String>{
        'Grass',
        'Fire',
        'Water',
        'Lightning',
        'Psychic',
        'Fighting',
        'Darkness',
        'Metal',
        'Fairy',
        'Dragon',
      }.any((String t) => card.name.startsWith(t));
}

/// Every format Arcanum knows, grouped by the game it belongs to.
abstract final class DeckFormats {
  static const commander = DeckFormat(
    id: 'commander',
    label: 'Commander',
    game: CardGame.mtg,
    minCards: 100,
    maxCards: 100,
    maxCopies: 1,
    singleton: true,
    hasCommander: true,
    sideboardSize: 0,
    usesColourIdentity: true,
    banListQuery: 'banned:commander',
    // The singleton rule has always exempted basic lands: a Commander deck may
    // hold any number of them, and without that a hundred-card deck cannot be
    // built at all.
    unlimited: _isBasicLand,
  );

  static const mtgConstructed = <DeckFormat>[
    DeckFormat(
      id: 'standard',
      label: 'Standard',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:standard',
      unlimited: _isBasicLand,
      sideboardSize: 15,
    ),
    DeckFormat(
      id: 'pioneer',
      label: 'Pioneer',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:pioneer',
      unlimited: _isBasicLand,
      sideboardSize: 15,
    ),
    DeckFormat(
      id: 'modern',
      label: 'Modern',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:modern',
      unlimited: _isBasicLand,
      sideboardSize: 15,
    ),
    DeckFormat(
      id: 'legacy',
      label: 'Legacy',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:legacy',
      unlimited: _isBasicLand,
      sideboardSize: 15,
    ),
    DeckFormat(
      id: 'vintage',
      label: 'Vintage',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:vintage',
      unlimited: _isBasicLand,
      sideboardSize: 15,
      notes:
          'Vintage restricts some cards to one copy rather than banning them.',
    ),
    DeckFormat(
      id: 'pauper',
      label: 'Pauper',
      game: CardGame.mtg,
      minCards: 60,
      banListQuery: 'banned:pauper',
      unlimited: _isBasicLand,
      sideboardSize: 15,
    ),
    DeckFormat(
      id: 'mtg-casual',
      label: 'Casual',
      game: CardGame.mtg,
      minCards: 0,
      unlimited: _isBasicLand,
      sideboardSize: 15,
      notes: 'No size, copy or ban rules are checked.',
    ),
  ];

  static const pokemonFormats = <DeckFormat>[
    DeckFormat(
      id: 'pokemon-standard',
      label: 'Standard',
      game: CardGame.pokemon,
      minCards: 60,
      maxCards: 60,
      unlimited: _isBasicEnergy,
      notes: 'Only one ACE SPEC card is allowed per deck; that is not checked.',
    ),
    DeckFormat(
      id: 'pokemon-expanded',
      label: 'Expanded',
      game: CardGame.pokemon,
      minCards: 60,
      maxCards: 60,
      unlimited: _isBasicEnergy,
    ),
    DeckFormat(
      id: 'pokemon-casual',
      label: 'Casual',
      game: CardGame.pokemon,
      minCards: 0,
      unlimited: _isBasicEnergy,
      notes: 'No size, copy or ban rules are checked.',
    ),
  ];

  static const yugiohFormats = <DeckFormat>[
    DeckFormat(
      id: 'ygo-advanced',
      label: 'Advanced',
      game: CardGame.yugioh,
      minCards: 40,
      maxCards: 60,
      maxCopies: 3,
      sideboardSize: 15,
      notes: 'The Forbidden and Limited lists are not checked.',
    ),
    DeckFormat(
      id: 'ygo-traditional',
      label: 'Traditional',
      game: CardGame.yugioh,
      minCards: 40,
      maxCards: 60,
      maxCopies: 3,
      sideboardSize: 15,
      notes: 'The Forbidden and Limited lists are not checked.',
    ),
    DeckFormat(
      id: 'ygo-casual',
      label: 'Casual',
      game: CardGame.yugioh,
      minCards: 0,
      notes: 'No size or copy rules are checked.',
    ),
  ];

  static const lorcanaFormats = <DeckFormat>[
    DeckFormat(
      id: 'lorcana-core',
      label: 'Core Constructed',
      game: CardGame.lorcana,
      minCards: 60,
      maxCopies: 4,
    ),
    DeckFormat(
      id: 'lorcana-casual',
      label: 'Casual',
      game: CardGame.lorcana,
      minCards: 0,
      notes: 'No size or copy rules are checked.',
    ),
  ];

  /// Every format of one game, in the order the picker shows them.
  static List<DeckFormat> forGame(CardGame game) => switch (game) {
    CardGame.mtg => <DeckFormat>[commander, ...mtgConstructed],
    CardGame.pokemon => pokemonFormats,
    CardGame.yugioh => yugiohFormats,
    CardGame.lorcana => lorcanaFormats,
  };

  /// The format with this id, or null when it is not one we know.
  static DeckFormat? byId(String id) {
    for (final game in CardGame.values) {
      for (final format in forGame(game)) {
        if (format.id == id) return format;
      }
    }
    return null;
  }

  /// The format a new deck of this game starts as.
  static DeckFormat defaultFor(CardGame game) => forGame(game).first;
}
