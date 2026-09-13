import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/decks/deck_format.dart';

/// Where a card sits in a deck.
///
/// The main board is the deck itself; the sideboard is fifteen cards that may be
/// swapped in; a commander is its own slot because Commander counts it
/// separately and reads the deck's colours off it.
enum DeckBoard {
  main('main', 'Deck'),
  side('side', 'Sideboard'),
  commander('commander', 'Commander');

  const DeckBoard(this.code, this.label);

  /// Stored in the database.
  final String code;

  /// Shown to the collector.
  final String label;

  static DeckBoard fromCode(String? code) {
    for (final board in DeckBoard.values) {
      if (board.code == code) return board;
    }
    return DeckBoard.main;
  }

  /// True when cards on this board count towards the deck's size.
  bool get countsTowardsSize => this != DeckBoard.side;
}

/// A deck as stored: its identity, not its contents.
class Deck {
  const Deck({
    required this.id,
    required this.game,
    required this.name,
    required this.formatId,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.cardCount = 0,
    this.uniqueCards = 0,
    this.sideboardCount = 0,
  });

  final int id;
  final CardGame game;
  final String name;

  /// The [DeckFormat.id] this deck is built to.
  final String formatId;

  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Copies on the boards that count towards the deck's size.
  final int cardCount;

  /// Distinct cards across every board.
  final int uniqueCards;

  /// Copies in the sideboard, which the deck size ignores.
  final int sideboardCount;

  /// The format, or null when the deck names one this build no longer has.
  DeckFormat? get format => DeckFormats.byId(formatId);

  /// What to call the format when it is missing.
  String get formatLabel => format?.label ?? 'Unknown format';
}

/// One line of a deck: a card, how many, and where it sits.
class DeckEntry {
  const DeckEntry({
    required this.cardId,
    required this.quantity,
    required this.board,
    required this.game,
    this.category = '',
    this.card,
  });

  final String cardId;
  final int quantity;
  final DeckBoard board;
  final CardGame game;

  /// A free label for the card's job in the deck - Ramp, Removal, Wincon. Only
  /// ever set by the collector; the app never guesses one.
  final String category;

  /// The catalogue record, when the card is cached. Null for a deck imported
  /// before the printing was ever downloaded, which the UI shows as unknown
  /// rather than dropping.
  final TcgCard? card;

  /// How many of this card the collector owns, across every finish.
  int ownedWith(Map<String, int> owned) => owned[cardId] ?? 0;

  /// Copies wanted but not owned.
  int missingWith(Map<String, int> owned) {
    final held = ownedWith(owned);
    return quantity > held ? quantity - held : 0;
  }
}

/// Everything one deck holds, with the catalogue data for each line.
class DeckContents {
  const DeckContents({
    required this.deck,
    required this.entries,
    required this.value,
    required this.missingValue,
  });

  final Deck deck;
  final List<DeckEntry> entries;

  /// What the deck is worth at today's prices.
  final double value;

  /// What the cards still to buy would cost.
  final double missingValue;

  /// Every entry on one board, in the order they were stored.
  List<DeckEntry> board(DeckBoard board) => <DeckEntry>[
    for (final e in entries)
      if (e.board == board) e,
  ];

  /// Copies on the boards that count towards the deck's size.
  int get size => entries
      .where((DeckEntry e) => e.board.countsTowardsSize)
      .fold(0, (int a, DeckEntry e) => a + e.quantity);

  int get sideboardSize => entries
      .where((DeckEntry e) => e.board == DeckBoard.side)
      .fold(0, (int a, DeckEntry e) => a + e.quantity);

  /// Distinct cards across every board.
  int get uniqueCards => entries.length;

  /// Copies still to buy, across every board.
  int missingWith(Map<String, int> owned) =>
      entries.fold(0, (int a, DeckEntry e) => a + e.missingWith(owned));

  /// True when the collector owns every copy the deck calls for.
  bool completeWith(Map<String, int> owned) =>
      entries.every((DeckEntry e) => e.missingWith(owned) == 0);
}
