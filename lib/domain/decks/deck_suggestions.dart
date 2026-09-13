import 'dart:math' as math;

import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_analysis.dart';
import 'package:arcanum/domain/decks/deck_roles.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// One card the collector already owns that would fit a deck, and why.
///
/// The reasons are the point. A ranked list with no explanation is a slot
/// machine: it cannot be argued with, learned from, or trusted. Every entry
/// here carries the numbers the app actually used, so a suggestion that is
/// wrong is visibly wrong rather than mysteriously wrong.
class DeckSuggestion {
  const DeckSuggestion({
    required this.card,
    required this.owned,
    required this.canAdd,
    required this.score,
    required this.reasons,
  });

  /// The printing to add.
  final TcgCard card;

  /// Copies of this printing the collector holds, across every finish.
  final int owned;

  /// Copies that could go in without breaking the format or overdrawing the
  /// collection.
  final int canAdd;

  /// The ranking. Only ever compared against other suggestions.
  final double score;

  /// Why this card is here, in plain words, citing the data behind it.
  final List<String> reasons;
}

/// How much a card's standing on EDHREC is worth.
///
/// Deliberately less than a role the deck is actually short of: a popular card
/// that does nothing for this deck is still a card that does nothing for it.
const double _popularityWeight = 1.6;

/// A rank at or below which a card is common enough to be worth naming.
///
/// Six thousand is roughly the point where a card is a recognised staple of
/// the format rather than merely a card that sees play.
const int _popularRank = 6000;

/// Suggests cards the collector owns for a deck, best fit first.
///
/// The deck's own shape is the brief: a card scores for filling a role the deck
/// is short of, for being on the deck's tribe, and for landing in a gap in its
/// curve. Popularity counts for something but never leads, because the deck in
/// front of you is better evidence than the average deck of the same colours.
///
/// Only cards the collector already owns and has not already committed are
/// considered, and every format rule that can be applied to a single card is
/// applied: banned names, the copy limit, and the commander's colour identity.
List<DeckSuggestion> suggestForDeck({
  required DeckContents contents,
  required Map<String, TcgCard> ownedCards,
  required Map<String, int> ownedQuantities,
  Set<String> bannedNames = const <String>{},
  int limit = 60,
}) {
  if (ownedCards.isEmpty) return const <DeckSuggestion>[];

  final format = contents.deck.format;
  final analysis = analyseDeck(contents);
  final game = contents.deck.game;

  // Every copy already spoken for, on any board, so a suggestion is never a
  // card the deck already has all of.
  final committed = <String, int>{};
  for (final entry in contents.entries) {
    committed[entry.cardId] = (committed[entry.cardId] ?? 0) + entry.quantity;
  }

  // The commander sets the deck's colours and, in practice, its tribe.
  final commander = _firstCard(contents, DeckBoard.commander);
  final identity = commander == null
      ? const <String>{}
      : <String>{
          for (final String c in commander.colorIdentity) c.toLowerCase(),
        };

  // The deck's own creature types, which is what 'already owned and on plan'
  // actually means for a tribal deck.
  final deckTypes = <String>{
    ...analysis.commanderTypes.map((String t) => t.toLowerCase()),
    for (final entry in analysis.subtypes)
      if (entry.value >= 3) entry.key.toLowerCase(),
  };

  final out = <DeckSuggestion>[];
  for (final card in ownedCards.values) {
    final owned = ownedQuantities[card.id] ?? 0;
    if (owned <= 0) continue;

    final inDeck = committed[card.id] ?? 0;
    final spare = owned - inDeck;
    if (spare <= 0) continue;

    if (bannedNames.isNotEmpty &&
        bannedNames.contains(TcgCard.normaliseName(card.name))) {
      continue;
    }

    final unlimited = format?.unlimited?.call(card) ?? false;
    final allowed = unlimited ? spare : (format?.maxCopies ?? 4) - inDeck;
    final canAdd = math.min(spare, allowed);
    if (canAdd <= 0) continue;

    // A commander deck is its commander's colours, and a card outside them is
    // not a suggestion however good it is.
    if (format != null && format.usesColourIdentity && identity.isNotEmpty) {
      final outside = card.colorIdentity.any(
        (String c) => !identity.contains(c.toLowerCase()),
      );
      if (outside) continue;
    }

    final reasons = <String>[];
    var score = 0.0;

    // ------------------------------------------------------------- role fit
    final roles = rolesOf(card);
    final needed = <DeckRole>[
      for (final role in roles)
        if (role != DeckRole.land && analysis.deficit(role) > 0) role,
    ];
    if (needed.isNotEmpty) {
      final role = needed.first;
      final deficit = analysis.deficit(role);
      final target = analysis.roleTargets[role] ?? 0;
      final held = analysis.roleCounts[role] ?? 0;
      // Full credit once a card closes a sixth of the gap; before that the
      // score rises with how badly the role is missing.
      score += 2.2 * math.min(1.0, deficit / math.max(1.0, target * 0.6));
      score += 0.3 * (needed.length - 1);
      reasons.add('${role.label} - this deck reads as $held of about $target');
    }

    // ------------------------------------------------------------ popularity
    final rank = card.edhrecRank;
    if (rank != null && rank > 0) {
      final popularity = (1 - math.log(rank) / math.log(25000)).clamp(0.0, 1.0);
      score += _popularityWeight * popularity;
      if (rank <= _popularRank) reasons.add('EDHREC rank #$rank');
    }

    // ----------------------------------------------------------------- tribe
    final subtypes = CardTypes.parse(card).subtypes;
    if (deckTypes.isNotEmpty && subtypes.isNotEmpty) {
      final shared = subtypes.firstWhere(
        (String t) => deckTypes.contains(t.toLowerCase()),
        orElse: () => '',
      );
      if (shared.isNotEmpty) {
        final count = analysis.subtypes
            .firstWhere(
              (MapEntry<String, int> e) =>
                  e.key.toLowerCase() == shared.toLowerCase(),
              orElse: () => const MapEntry<String, int>('', 0),
            )
            .value;
        score += 1.1;
        reasons.add(
          count > 0
              ? '$shared - $count cards here share the type'
              : '$shared, like your commander',
        );
      }
    }

    // ----------------------------------------------------------------- curve
    final cmc = card.cmc;
    if (cmc != null && analysis.curveRead && game == CardGame.mtg) {
      final bucket = cmc.floor().clamp(0, kCurveBuckets - 1);
      if (bucket >= 1 && bucket <= 5 && analysis.curve[bucket] == 0) {
        score += 0.5;
        reasons.add('Nothing here costs $bucket yet');
      }
    }

    if (reasons.isEmpty) {
      // A card that fills no hole the app can see still belongs on the list,
      // but it says so rather than claiming a reason it has not got.
      reasons.add('In your collection, and legal here');
    }

    out.add(
      DeckSuggestion(
        card: card,
        owned: owned,
        canAdd: canAdd,
        score: score,
        reasons: reasons,
      ),
    );
  }

  out.sort((DeckSuggestion a, DeckSuggestion b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.card.name.compareTo(b.card.name);
  });
  return out.take(limit).toList();
}

/// The catalogue record of the first card on a board, if it is cached.
TcgCard? _firstCard(DeckContents contents, DeckBoard board) {
  for (final entry in contents.entries) {
    if (entry.board == board && entry.card != null) return entry.card;
  }
  return null;
}
