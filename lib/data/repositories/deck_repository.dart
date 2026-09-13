import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Decks, with their cards priced and their gaps counted.
///
/// The DAO stores lines; this turns them into something a screen can draw by
/// joining the catalogue on and adding up what the collector still has to buy.
/// The owned counts are passed in rather than read here, because the app
/// already computes them once per game and a second source of truth for "how
/// many do I have" is how the two drift apart.
class DeckRepository {
  DeckRepository({required DeckDao dao, required CatalogRepository catalog})
    : _dao = dao,
      _catalog = catalog;

  final DeckDao _dao;
  final CatalogRepository _catalog;

  /// Every deck of a game, newest change first, priced and counted.
  Future<List<DeckContents>> all(
    CardGame game, {
    Map<String, int> owned = const <String, int>{},
  }) async {
    final decks = await _dao.decks(game);
    if (decks.isEmpty) return const <DeckContents>[];
    final byId = await _cardsFor(game, decks.map((Deck d) => d.id));
    return <DeckContents>[
      for (final deck in decks)
        _assemble(deck, byId[deck.id] ?? const <DeckEntry>[], owned),
    ];
  }

  /// One deck, priced and counted.
  Future<DeckContents?> contents(
    int deckId, {
    Map<String, int> owned = const <String, int>{},
  }) async {
    final deck = await _dao.deck(deckId);
    if (deck == null) return null;
    final entries = await _withCards(deck);
    return _assemble(deck, entries, owned);
  }

  /// Creates a deck and hands back its id.
  Future<int> create({
    required CardGame game,
    required String name,
    required String formatId,
  }) => _dao.createDeck(game: game, name: name, formatId: formatId);

  Future<void> rename(int id, String name) => _dao.updateDeck(id, name: name);

  Future<void> setFormat(int id, String formatId) =>
      _dao.updateDeck(id, formatId: formatId);

  Future<void> setNotes(int id, String notes) => _dao.updateDeck(
    id,
    notes: notes.trim().isEmpty ? null : notes.trim(),
    clearNotes: notes.trim().isEmpty,
  );

  Future<void> delete(int id) => _dao.deleteDeck(id);

  Future<void> addCard(
    int deckId,
    String cardId, {
    DeckBoard board = DeckBoard.main,
    int quantity = 1,
  }) => _dao.addCard(deckId, cardId, board: board, quantity: quantity);

  Future<void> setQuantity(
    int deckId,
    String cardId,
    DeckBoard board,
    int quantity,
  ) => _dao.setQuantity(deckId, cardId, board, quantity);

  Future<void> moveCard(
    int deckId,
    String cardId,
    DeckBoard from,
    DeckBoard to,
  ) => _dao.moveCard(deckId, cardId, from, to);

  Future<void> removeCard(int deckId, String cardId, DeckBoard board) =>
      _dao.removeCard(deckId, cardId, board);

  Future<void> clear(int deckId) => _dao.clearDeck(deckId);

  /// The decks holding this printing, so a card can offer to leave one.
  Future<List<Deck>> holding(CardGame game, String cardId) =>
      _dao.decksContaining(game, cardId);

  /// Loads the catalogue record for every card in these decks at once.
  Future<Map<int, List<DeckEntry>>> _cardsFor(
    CardGame game,
    Iterable<int> deckIds,
  ) async {
    final out = <int, List<DeckEntry>>{};
    final wanted = <String>{};
    for (final id in deckIds) {
      final entries = await _dao.entries(id, game);
      out[id] = entries;
      for (final e in entries) {
        wanted.add(e.cardId);
      }
    }
    if (wanted.isEmpty) return out;
    final cards = await _catalog.cardsByIds(game, wanted.toList());
    return <int, List<DeckEntry>>{
      for (final entry in out.entries)
        entry.key: <DeckEntry>[
          for (final line in entry.value) _withCard(line, cards[line.cardId]),
        ],
    };
  }

  /// Attaches catalogue data to one deck's lines.
  Future<List<DeckEntry>> _withCards(Deck deck) async {
    final entries = await _dao.entries(deck.id, deck.game);
    if (entries.isEmpty) return entries;
    final cards = await _catalog.cardsByIds(
      deck.game,
      entries.map((DeckEntry e) => e.cardId).toList(),
    );
    return <DeckEntry>[
      for (final line in entries) _withCard(line, cards[line.cardId]),
    ];
  }

  static DeckEntry _withCard(DeckEntry line, TcgCard? card) => DeckEntry(
    cardId: line.cardId,
    quantity: line.quantity,
    board: line.board,
    game: line.game,
    category: line.category,
    card: card,
  );

  /// Adds the money to a set of lines.
  static DeckContents _assemble(
    Deck deck,
    List<DeckEntry> entries,
    Map<String, int> owned,
  ) {
    var value = 0.0;
    var missingValue = 0.0;
    for (final entry in entries) {
      final price = entry.card?.prices.from;
      if (price != null) value += price * entry.quantity;
      final missing = entry.missingWith(owned);
      if (missing > 0 && price != null) missingValue += price * missing;
    }
    return DeckContents(
      deck: deck,
      entries: entries,
      value: value,
      missingValue: missingValue,
    );
  }
}
