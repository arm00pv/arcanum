import 'dart:math' as math;

import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_check.dart';
import 'package:arcanum/domain/decks/deck_roles.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// How many mana values the curve keeps before lumping the rest together.
///
/// Seven and up is one bucket because a deck that curves out at seven has a
/// handful of cards up there, and splitting it further says nothing.
const int kCurveBuckets = 8;

/// Type words that describe a card's standing rather than what it is.
///
/// 'Legendary Creature' is a creature; counting the Legendary as a type of its
/// own would put a line in the breakdown that no deckbuilder thinks in.
const Set<String> _supertypes = <String>{
  'legendary',
  'basic',
  'snow',
  'world',
  'ongoing',
  'kindred',
  'tribal',
  'elite',
};

/// A deck read as a shape rather than as a list: what it is made of, where it
/// is thin, and how much of it the app could actually understand.
///
/// Everything here is derived from the cards' own printed words. Nothing is
/// fetched and nothing is guessed from a card's name, and [rolesRead] says
/// plainly when the reading came out too thin to draw conclusions from.
class DeckAnalysis {
  DeckAnalysis({
    required this.game,
    required this.size,
    required this.nonLandSize,
    required this.lands,
    required this.curve,
    required this.costed,
    required this.averageCost,
    required this.withText,
    required this.rolesRead,
    required this.roleCounts,
    required this.roleTargets,
    required this.types,
    required this.subtypes,
    required this.colours,
    required this.commanderTypes,
  });

  /// Which game the deck belongs to.
  final CardGame game;

  /// Copies on the boards that count towards the deck's size.
  final int size;

  /// Copies that are not lands.
  final int nonLandSize;

  /// Copies that are lands.
  final int lands;

  /// Copies by mana value, index 0 to [kCurveBuckets] - 1, the last being
  /// everything at seven or more.
  final List<int> curve;

  /// How many copies carried a mana value at all. The curve is only worth
  /// drawing when this is most of the deck.
  final int costed;

  /// The mean mana value of the copies that had one, or null when none did.
  final double? averageCost;

  /// How many copies printed any rules text. A deck that is mostly vanilla is
  /// not a deck the role reader can say much about.
  final int withText;

  /// True when enough of the deck could be read for role advice to mean
  /// anything. False suppresses the role advice rather than inventing it.
  final bool rolesRead;

  /// Copies filling each role.
  final Map<DeckRole, int> roleCounts;

  /// What [kRoleTargetShare] works out to for a deck this size.
  final Map<DeckRole, int> roleTargets;

  /// Copies by type word - Creature, Instant, Item - most common first.
  final List<MapEntry<String, int>> types;

  /// Copies by subtype - Goblin, Warrior, Ally - most common first.
  final List<MapEntry<String, int>> subtypes;

  /// Copies by colour, keyed by the letter the game prints.
  final List<MapEntry<String, int>> colours;

  /// The commander's own subtypes, so a suggestion can tell whether a card is
  /// on the deck's tribe rather than merely in its colours.
  final Set<String> commanderTypes;

  List<DeckIssue>? _advice;

  /// What the shape of the deck suggests changing, worked out on first use.
  List<DeckIssue> get advice => _advice ??= _buildAdvice();

  /// True when the curve is worth drawing.
  bool get curveRead => size > 0 && costed >= size * 0.5;

  /// True when lands could be counted, which needs a type line on most cards.
  bool get landsRead => size > 0 && lands > 0;

  /// Copies still wanted for a role before it reaches its rule of thumb.
  int deficit(DeckRole role) {
    final target = roleTargets[role] ?? 0;
    final held = roleCounts[role] ?? 0;
    return held >= target ? 0 : target - held;
  }

  /// The roles this deck is short of, thinnest first.
  List<DeckRole> get thinRoles {
    final roles = <DeckRole>[
      for (final role in kRoleTargetShare.keys)
        if (deficit(role) > 0) role,
    ];
    roles.sort((DeckRole a, DeckRole b) => deficit(b).compareTo(deficit(a)));
    return roles;
  }

  /// The advice worth showing for a deck of this shape, worst first.
  ///
  /// Capped at four, because a panel of twelve observations is a panel nobody
  /// reads. Nothing here is an error: an unusual deck is allowed to be unusual,
  /// and every one of these is a rule of thumb rather than a rule of the game.
  List<DeckIssue> _buildAdvice() {
    if (size < 20) return const <DeckIssue>[];
    final issues = <DeckIssue>[];

    // ---------------------------------------------------------------- lands
    final landTarget = (size * kLandShare).round();
    if (landsRead && game == CardGame.mtg) {
      if (lands < size * 0.30) {
        issues.add(
          DeckIssue(
            level: DeckIssueLevel.warning,
            title: 'Only $lands lands',
            detail:
                'A $size-card deck usually wants around $landTarget. Mana '
                'problems lose more games than any other single thing.',
          ),
        );
      } else if (lands > size * 0.46) {
        issues.add(
          DeckIssue(
            level: DeckIssueLevel.note,
            title: '$lands lands is a lot',
            detail:
                'Around $landTarget is the usual starting point. Spare slots '
                'are usually worth more as spells.',
          ),
        );
      }
    }

    // ---------------------------------------------------------------- roles
    if (rolesRead) {
      for (final role in thinRoles) {
        final held = roleCounts[role] ?? 0;
        final target = roleTargets[role] ?? 0;
        // Only worth saying when the gap is real rather than a rounding error.
        if (target < 2 || held > target * 0.5) continue;
        issues.add(
          DeckIssue(
            level: held == 0 ? DeckIssueLevel.warning : DeckIssueLevel.note,
            title: held == 0
                ? 'No ${role.label.toLowerCase()}'
                : '${role.label} is thin',
            detail:
                'This deck reads as $held; about $target is the usual '
                'starting point for a deck this size.',
          ),
        );
      }
    }

    // ---------------------------------------------------------------- curve
    final average = averageCost;
    if (curveRead && average != null && nonLandSize >= 20) {
      if (average > 3.6) {
        issues.add(
          DeckIssue(
            level: DeckIssueLevel.note,
            title: 'An expensive curve',
            detail:
                'The average mana value here is ${average.toStringAsFixed(1)}. '
                'Cheaper cards mean more of the deck gets played.',
          ),
        );
      } else if (curve[2] == 0 && size >= 40) {
        issues.add(
          const DeckIssue(
            level: DeckIssueLevel.note,
            title: 'Nothing at two mana',
            detail:
                'Two is where most decks want their busiest slot, and nothing '
                'here costs two.',
          ),
        );
      }
    }

    issues.sort(
      (DeckIssue x, DeckIssue y) =>
          _severity(y.level).compareTo(_severity(x.level)),
    );
    return issues.take(4).toList();
  }
}

/// Reads a deck's shape off its cards.
///
/// Lands come from the type line, roles from the rules text and the curve from
/// the mana value. A deck whose cards are not in the catalogue yet simply comes
/// back with less known about it, which [DeckAnalysis.rolesRead] and
/// [DeckAnalysis.curveRead] report rather than hide.
DeckAnalysis analyseDeck(DeckContents contents) {
  final game = contents.deck.game;

  // Only the boards that count: a sideboard is fifteen cards held in reserve,
  // and letting it skew the curve and the role counts would describe a deck
  // nobody actually plays.
  final counting = <DeckEntry>[
    for (final entry in contents.entries)
      if (entry.board.countsTowardsSize) entry,
  ];

  final curve = List<int>.filled(kCurveBuckets, 0);
  final roleCounts = <DeckRole, int>{};
  final types = <String, int>{};
  final subtypes = <String, int>{};
  final colours = <String, int>{};
  final commanderTypes = <String>{};

  var size = 0;
  var lands = 0;
  var costed = 0;
  var withText = 0;
  var costTotal = 0.0;

  for (final entry in counting) {
    final quantity = entry.quantity;
    size += quantity;
    final card = entry.card;
    if (card == null) continue;

    final cardTypes = CardTypes.parse(card);
    if (cardTypes.isLand) lands += quantity;

    for (final role in rolesOf(card)) {
      roleCounts[role] = (roleCounts[role] ?? 0) + quantity;
    }

    for (final type in cardTypes.types) {
      if (_supertypes.contains(type.toLowerCase())) continue;
      final key = _titleCase(type);
      types[key] = (types[key] ?? 0) + quantity;
    }
    for (final subtype in cardTypes.subtypes) {
      final key = _titleCase(subtype);
      subtypes[key] = (subtypes[key] ?? 0) + quantity;
      if (entry.board == DeckBoard.commander) commanderTypes.add(key);
    }
    for (final colour in card.colorIdentity) {
      final key = colour.toUpperCase();
      colours[key] = (colours[key] ?? 0) + quantity;
    }

    final hasText =
        (card.oracleText ?? '').trim().isNotEmpty ||
        card.faces.any((TcgCardFace f) => (f.text ?? '').trim().isNotEmpty);
    if (hasText) withText += quantity;

    final cmc = card.cmc;
    if (cmc != null) {
      costed += quantity;
      costTotal += cmc * quantity;
      curve[cmc.floor().clamp(0, kCurveBuckets - 1)] += quantity;
    }
  }

  final nonLandSize = size - lands;
  return DeckAnalysis(
    game: game,
    size: size,
    nonLandSize: nonLandSize,
    lands: lands,
    curve: curve,
    costed: costed,
    averageCost: costed == 0 ? null : costTotal / costed,
    withText: withText,
    // The reader needs rules for the game and words on the cards. Two fifths of
    // the deck is the bar: below it these counts describe the app's vocabulary
    // more than they describe the deck.
    rolesRead: hasRoleRules(game) && size > 0 && withText >= size * 0.4,
    roleCounts: roleCounts,
    roleTargets: <DeckRole, int>{
      for (final entry in kRoleTargetShare.entries)
        entry.key: math.max(1, (nonLandSize * entry.value).round()),
    },
    types: _ranked(types),
    subtypes: _ranked(subtypes),
    colours: _ranked(colours),
    commanderTypes: commanderTypes,
  );
}

/// The entries of a tally, biggest first, ties broken alphabetically so the
/// order never wobbles between two runs over the same deck.
List<MapEntry<String, int>> _ranked(Map<String, int> tally) {
  final entries = tally.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return entries;
}

/// Capitalises a type word the way a card prints it.
String _titleCase(String word) {
  if (word.isEmpty) return word;
  return word[0].toUpperCase() + word.substring(1).toLowerCase();
}

int _severity(DeckIssueLevel level) => switch (level) {
  DeckIssueLevel.error => 2,
  DeckIssueLevel.warning => 1,
  DeckIssueLevel.note => 0,
};
