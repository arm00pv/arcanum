import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// How much a problem matters.
enum DeckIssueLevel {
  /// The deck is not legal in its format.
  error,

  /// Legal, but something is probably not what the collector meant.
  warning,

  /// Neither - a limitation of what the app could check.
  note,
}

/// One thing wrong with a deck.
class DeckIssue {
  const DeckIssue({
    required this.level,
    required this.title,
    required this.detail,
    this.cards = const <String>[],
  });

  final DeckIssueLevel level;
  final String title;
  final String detail;

  /// The cards the complaint is about, for showing underneath it.
  final List<String> cards;
}

/// What a legality check found, and what it could not look at.
class DeckCheckResult {
  const DeckCheckResult({required this.issues, required this.banListChecked});

  final List<DeckIssue> issues;

  /// False when the format has a ban list this app has no copy of - the deck
  /// may still be illegal in a way nothing here would catch, and saying so is
  /// the difference between a tool and a liar.
  final bool banListChecked;

  /// True when nothing was found that makes the deck illegal.
  bool get isLegal =>
      issues.every((DeckIssue i) => i.level != DeckIssueLevel.error);

  /// The complaints worth showing first.
  List<DeckIssue> get errors => <DeckIssue>[
    for (final i in issues)
      if (i.level == DeckIssueLevel.error) i,
  ];
}

/// Judges a deck against its format.
///
/// Every rule here is one the app can actually apply. Where a format has a rule
/// that needs data Arcanum does not carry - Yu-Gi-Oh!'s Forbidden list, the
/// single ACE SPEC a Pokemon deck may hold - the result says it went unchecked
/// rather than staying silent, because a green tick the app has not earned is
/// worse than no tick at all.
DeckCheckResult checkDeck(
  DeckContents contents, {
  Set<String> bannedNames = const <String>{},
  bool banListChecked = false,
}) {
  final issues = <DeckIssue>[];
  final format = contents.deck.format;
  final main = contents.board(DeckBoard.main);
  final side = contents.board(DeckBoard.side);
  final commanders = contents.board(DeckBoard.commander);

  if (format == null) {
    issues.add(
      const DeckIssue(
        level: DeckIssueLevel.note,
        title: 'Unknown format',
        detail:
            'This deck names a format this version does not know, so '
            'nothing was checked.',
      ),
    );
    return DeckCheckResult(issues: issues, banListChecked: false);
  }

  // ------------------------------------------------------------------ size
  final size = contents.size;
  if (format.maxCards != null && size > format.maxCards!) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.error,
        title: 'Too many cards',
        detail:
            '${format.label} allows at most ${format.maxCards}. This deck '
            'holds $size.',
      ),
    );
  }
  if (size < format.minCards) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.warning,
        title: 'Not enough cards',
        detail:
            '${format.label} needs at least ${format.minCards}. This deck '
            'holds $size.',
      ),
    );
  }

  if (format.hasCommander && commanders.isEmpty) {
    issues.add(
      const DeckIssue(
        level: DeckIssueLevel.error,
        title: 'No commander',
        detail:
            'This format needs a commander, and a deck without one has no '
            'colour identity to check against.',
      ),
    );
  }
  if (format.hasCommander && commanders.length > 1) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.warning,
        title: 'More than one commander',
        detail:
            'Only the first is used for the colour identity check, and a '
            'deck may name more than one only when they partner.',
        cards: <String>[for (final c in commanders) c.card?.name ?? c.cardId],
      ),
    );
  }

  // ------------------------------------------------------------ copy limits
  // Counted across the deck and the sideboard together, which is how Magic's
  // four-of rule works: a fifth copy hidden in the sideboard is still a fifth.
  final copies = <String, int>{};
  final names = <String, String>{};
  for (final entry in <DeckEntry>[...main, ...side]) {
    copies[entry.cardId] = (copies[entry.cardId] ?? 0) + entry.quantity;
    names[entry.cardId] = entry.card?.name ?? entry.cardId;
  }
  for (final entry in commanders) {
    copies[entry.cardId] = (copies[entry.cardId] ?? 0) + entry.quantity;
    names[entry.cardId] = entry.card?.name ?? entry.cardId;
  }

  final overLimit = <String>[];
  copies.forEach((String id, int count) {
    final limit = format.singleton ? 1 : format.maxCopies;
    if (count <= limit) return;
    final card = _find(contents, id)?.card;
    // Basic lands and basic Energy are exempt from every copy rule, in every
    // format that has one.
    if (card != null && (format.unlimited?.call(card) ?? false)) return;
    overLimit.add('${names[id]} ($count)');
  });
  if (overLimit.isNotEmpty) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.error,
        title: format.singleton
            ? 'More than one copy of a card'
            : 'More than ${format.maxCopies} copies of a card',
        detail: format.singleton
            ? '${format.label} allows one of each card other than basic lands.'
            : '${format.label} allows ${format.maxCopies} of a card, counting '
                  'the sideboard.',
        cards: overLimit,
      ),
    );
  }

  // ------------------------------------------------------- colour identity
  if (format.usesColourIdentity && commanders.isNotEmpty) {
    final identity = <String>{...?commanders.first.card?.colorIdentity};
    final outside = <String>[];
    for (final entry in contents.entries) {
      if (entry.board == DeckBoard.commander) continue;
      final card = entry.card;
      if (card == null) continue;
      final stray = card.colorIdentity.where(
        (String c) => !identity.contains(c),
      );
      if (stray.isNotEmpty) {
        outside.add('${card.name} (${stray.join()})');
      }
    }
    if (outside.isNotEmpty) {
      issues.add(
        DeckIssue(
          level: DeckIssueLevel.error,
          title: 'Outside the commander\'s colours',
          detail:
              'Every card must fit the colour identity of the commander, '
              'which is ${identity.isEmpty ? 'colourless' : identity.join()}.',
          cards: outside,
        ),
      );
    }
  }

  // -------------------------------------------------------------- ban list
  if (format.checksBanList && banListChecked && bannedNames.isNotEmpty) {
    final banned = <String>[];
    for (final entry in contents.entries) {
      final name = entry.card?.name;
      if (name != null && bannedNames.contains(name)) banned.add(name);
    }
    if (banned.isNotEmpty) {
      issues.add(
        DeckIssue(
          level: DeckIssueLevel.error,
          title: 'Banned in ${format.label}',
          detail: 'These cards are on the format\'s banned list.',
          cards: banned.toSet().toList(),
        ),
      );
    }
  }

  // -------------------------------------------------------------- sideboard
  if (format.hasSideboard && contents.sideboardSize > format.sideboardSize) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.error,
        title: 'Sideboard too large',
        detail:
            '${format.label} allows ${format.sideboardSize} sideboard '
            'cards. This one holds ${contents.sideboardSize}.',
      ),
    );
  }
  if (!format.hasSideboard && contents.sideboardSize > 0) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.warning,
        title: 'No sideboard in this format',
        detail:
            '${format.label} has no sideboard, so these '
            '${contents.sideboardSize} cards are not part of a legal deck.',
      ),
    );
  }

  // ------------------------------------------------------------ what is unknown
  final unknown = <String>[
    for (final e in contents.entries)
      if (e.card == null) e.cardId,
  ];
  if (unknown.isNotEmpty) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.warning,
        title: 'Not in the catalogue',
        detail:
            'These printings are not downloaded, so their rules text, '
            'colours and prices were not checked.',
        cards: unknown,
      ),
    );
  }

  if (format.checksBanList && !banListChecked) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.note,
        title: 'Ban list not checked',
        detail:
            'Arcanum has no copy of the ${format.label} banned list yet. '
            'Open the deck and refresh it to fetch one.',
      ),
    );
  }
  if (format.notes != null) {
    issues.add(
      DeckIssue(
        level: DeckIssueLevel.note,
        title: 'Not checked',
        detail: format.notes!,
      ),
    );
  }

  return DeckCheckResult(issues: issues, banListChecked: banListChecked);
}

/// The entry holding this printing, whichever board it is on.
DeckEntry? _find(DeckContents contents, String cardId) {
  for (final entry in contents.entries) {
    if (entry.cardId == cardId) return entry;
  }
  return null;
}

/// The colour identity a set of cards spans, for showing on a deck tile.
String colourIdentityLabel(Iterable<TcgCard> cards) {
  final identity = <String>{};
  for (final card in cards) {
    identity.addAll(card.colorIdentity);
  }
  if (identity.isEmpty) return 'Colourless';
  const order = <String>['W', 'U', 'B', 'R', 'G'];
  final sorted = order.where(identity.contains).toList();
  return sorted.isEmpty ? identity.join() : sorted.join();
}
