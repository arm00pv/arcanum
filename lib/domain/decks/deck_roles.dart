import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A job a card can do in a deck, as far as its rules text can be read.
///
/// Every role is inferred from words the card actually prints rather than from
/// a written-out list of card names: a name list goes stale with every set and,
/// worse, cannot be checked by the person reading the deck. The reading is
/// still a reading - a card that only destroys something as a cost, or a draw
/// spell meant for the opponent, will be miscounted - so roles are shown as a
/// picture of a deck and never as a legality rule.
enum DeckRole {
  land('land', 'Lands'),
  ramp('ramp', 'Ramp'),
  draw('draw', 'Card draw'),
  removal('removal', 'Removal'),
  wipe('wipe', 'Board wipes'),
  counter('counter', 'Counterspells'),
  protection('protection', 'Protection'),
  tutor('tutor', 'Tutors');

  const DeckRole(this.code, this.label);

  /// Stable identifier, never shown.
  final String code;

  /// What the collector sees.
  final String label;

  /// The role for a stored code, or null when it is not one we know.
  static DeckRole? fromCode(String? code) {
    for (final role in DeckRole.values) {
      if (role.code == code) return role;
    }
    return null;
  }
}

/// Roughly how much of a deck each role should fill, as a share of the cards
/// that are not lands.
///
/// These are rules of thumb out of decades of deckbuilding writing, not rules
/// of any game, which is why they drive advice and never an error. A role left
/// out of this map is a matter of taste: counterspells belong in a blue deck
/// and nowhere else, and how many tutors a deck wants is a statement about the
/// person playing it.
const Map<DeckRole, double> kRoleTargetShare = <DeckRole, double>{
  DeckRole.ramp: 0.10,
  DeckRole.draw: 0.10,
  DeckRole.removal: 0.08,
  DeckRole.wipe: 0.03,
  DeckRole.protection: 0.03,
};

/// Share of a deck that should be lands.
///
/// Magic's own guidance is 36-38 lands in a hundred-card Commander deck and 24
/// in sixty, which is close enough to one number to be worth saying once. The
/// app only offers this where it can actually count the lands.
const double kLandShare = 0.36;

/// The two halves of a type line: what a card is, and what it is made of.
///
/// Every game Arcanum covers writes a type line the same way - a handful of
/// type words, an em dash, then subtypes - so one parser reads all four. Games
/// that do not split their types this way simply come back with everything on
/// the left of the dash, which is still the right answer to 'is this a land'.
class CardTypes {
  const CardTypes(this.types, this.subtypes);

  /// Type words before the dash: Creature, Land, Spell Card, Character.
  final List<String> types;

  /// Words after the dash: Goblin, Warrior, Item.
  final List<String> subtypes;

  /// Nothing known about this card's type line.
  static const CardTypes unknown = CardTypes(<String>[], <String>[]);

  /// True when the type line names this type, ignoring case.
  bool has(String type) {
    final wanted = type.toLowerCase();
    return types.any((String t) => t.toLowerCase() == wanted);
  }

  /// True when any word of this subtype appears, ignoring case.
  bool hasSubtype(String subtype) {
    final wanted = subtype.toLowerCase();
    return subtypes.any((String t) => t.toLowerCase() == wanted);
  }

  /// True for a land, which is the one type word every game agrees on.
  bool get isLand => has('land');

  /// True for a card that attacks or blocks.
  bool get isCreature => has('creature') || has('monster') || has('pokemon');

  /// Reads a card's type line, keeping the words in the order printed.
  static CardTypes parse(TcgCard card) {
    final raw = card.typeLine;
    if (raw == null || raw.trim().isEmpty) {
      // Yu-Gi-Oh! keeps its race outside the type line, and it is the closest
      // thing that game has to a creature type, so it stands in for subtypes.
      final race = card.extras['race'];
      if (race is String && race.trim().isNotEmpty) {
        return CardTypes(const <String>[], <String>[race.trim()]);
      }
      return unknown;
    }

    // An em dash separates types from subtypes. A spaced hyphen is accepted
    // too, because a few providers normalise the dash away.
    final parts = raw.split(RegExp(r'\s+[\u2014\u2013]\s+|\s+-\s+'));
    final left = parts.first;
    final right = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    // 'Legendary Creature' is a supertype plus a type; both are useful words.
    final types = left
        .split(RegExp(r'[\s,]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();

    final subtypes = <String>[
      ...right.split(RegExp(r'[\s,]+')),
      // Yu-Gi-Oh! again: 'Effect Monster' says nothing about what the monster
      // is, so the race is folded in alongside whatever the line carried.
      if (card.extras['race'] is String) card.extras['race']! as String,
    ].map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();

    return CardTypes(types, subtypes);
  }
}

/// Reads the roles a card can fill.
///
/// Returns an empty set for a game whose wording Arcanum has no rules for, and
/// for a card with no rules text at all. An unread card is better than a
/// guessed one: the analysis reports how much of the deck it could read, so a
/// thin reading is visible rather than silent.
Set<DeckRole> rolesOf(TcgCard card) {
  final rules = _roleRules[card.game];
  if (rules == null) return const <DeckRole>{};

  final types = CardTypes.parse(card);
  final roles = <DeckRole>{};
  if (types.isLand) roles.add(DeckRole.land);

  final text = _rulesTextOf(card);
  // A land is a land and nothing else. Fetch lands read as ramp and cycling
  // lands read as draw, but both are already counted as lands, and counting
  // them twice describes a deck nobody could build.
  if (types.isLand || text.isEmpty) return roles;

  for (final entry in rules.entries) {
    if (entry.key == DeckRole.land) continue;
    for (final pattern in entry.value) {
      if (pattern.hasMatch(text)) {
        roles.add(entry.key);
        break;
      }
    }
  }
  return roles;
}

/// True when Arcanum has role wording for this game at all.
///
/// A game without it gets no role counts rather than an empty-looking deck.
bool hasRoleRules(CardGame game) => _roleRules.containsKey(game);

/// A card's rules text, both faces, lower-cased for matching.
String _rulesTextOf(TcgCard card) {
  final buffer = StringBuffer(card.oracleText ?? '');
  for (final face in card.faces) {
    final text = face.text;
    if (text != null && text.isNotEmpty) buffer.write('\n$text');
  }
  return buffer.toString().toLowerCase();
}

/// The wording each game uses for each job.
///
/// Kept as data rather than as branches so a new game is a new entry and a
/// correction is a one-line change that a test can pin down.
final Map<CardGame, Map<DeckRole, List<RegExp>>>
_roleRules = <CardGame, Map<DeckRole, List<RegExp>>>{
  CardGame.mtg: _compile(<DeckRole, List<String>>{
    DeckRole.ramp: <String>[
      r'add \{',
      r'\badd (one|two|three|four|five|x) mana\b',
      r'search your library for a (basic )?land',
      r'put (a|up to [a-z]+|target) land card',
      r'create (a|two|three|four|x) treasure',
      r'untap (target|all) land',
    ],
    DeckRole.draw: <String>[
      r'\bdraw (a|one|two|three|four|five|six|seven|eight|nine|ten|x) cards?\b',
      r'\byou draw\b',
      r'\binvestigate\b',
      r'\blook at the top \w+ cards? of your library\b',
    ],
    DeckRole.removal: <String>[
      r'destroy target',
      r'exile target',
      r'deals? \d+ damage to target',
      r'target creature gets -',
      r'return target .{0,40} to (its|their) owner',
      r'put target .{0,40} on top of',
      r'target player sacrifices',
    ],
    DeckRole.wipe: <String>[
      r'destroy all',
      r'exile all',
      r'deals? \d+ damage to each',
      r'all creatures get -',
      r'each creature gets -',
      r'sacrifices? (all|each)',
    ],
    DeckRole.counter: <String>[
      r'counter target .{0,30}spell',
      r'counter target (artifact|creature|enchantment|instant|sorcery|'
          r'planeswalker|activated|triggered|ability)',
    ],
    DeckRole.protection: <String>[
      r'\bhexproof\b',
      r'\bindestructible\b',
      r'\bprotection from\b',
      r'\bregenerate\b',
      r'\bphase out\b',
      r'\bshroud\b',
      r"can't be countered",
    ],
    DeckRole.tutor: <String>[
      r'search your library for a card',
      r'search your library for an? (artifact|creature|enchantment|'
          r'instant|sorcery|planeswalker|legendary)',
    ],
  }),
  CardGame.yugioh: _compile(<DeckRole, List<String>>{
    DeckRole.draw: <String>[r'draw (\d+|a|1) cards?'],
    DeckRole.removal: <String>[
      r'\bdestroy\b',
      r'\bbanish\b',
      r'send .{0,30}to the graveyard',
    ],
    DeckRole.counter: <String>[r'\bnegate\b'],
    DeckRole.protection: <String>[
      r'cannot be destroyed',
      r'unaffected by',
      r'cannot be targeted',
    ],
    DeckRole.tutor: <String>[r'add 1 .{0,40}from your deck to your hand'],
  }),
  CardGame.lorcana: _compile(<DeckRole, List<String>>{
    DeckRole.draw: <String>[r'draw (a|\d+|two|three) cards?'],
    DeckRole.removal: <String>[r'\bbanish\b'],
    DeckRole.protection: <String>[r'\bward\b', r'\bevasive\b'],
    DeckRole.tutor: <String>[r'search your deck for'],
  }),
  CardGame.pokemon: _compile(<DeckRole, List<String>>{
    DeckRole.draw: <String>[r'draw (\d+|a|two|three) cards?'],
    DeckRole.ramp: <String>[r'attach .{0,40}energy'],
    DeckRole.tutor: <String>[r'search your deck for'],
    DeckRole.protection: <String>[r'prevent .{0,30}damage', r'\bheal\b'],
  }),
};

/// Turns a table of regex sources into compiled patterns once, on first use.
Map<DeckRole, List<RegExp>> _compile(
  Map<DeckRole, List<String>> sources,
) => <DeckRole, List<RegExp>>{
  for (final entry in sources.entries)
    entry.key: <RegExp>[
      for (final source in entry.value) RegExp(source, caseSensitive: false),
    ],
};
