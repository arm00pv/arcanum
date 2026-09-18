import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A source of card data for exactly one game.
///
/// Magic comes from Scryfall and Pokémon from the Pokémon TCG API, and the two
/// have almost nothing in common at the wire level: different pagination,
/// different collector-number formats, different price vocabularies, different
/// rate limits. Everything above this interface works in [TcgCard] and [TcgSet]
/// and never has to care which game it is looking at.
///
/// It is an abstract class rather than an interface class because one of the
/// methods below carries a body. Dart hands a body to subclasses and to nobody
/// else, and the default it holds is the one a catalogue with no cheaper way to
/// answer several ids should not have to write out.
abstract class CardCatalog {
  /// The game this catalogue serves.
  CardGame get game;

  /// Human readable name of the underlying data source, for the UI credits.
  String get sourceName;

  /// Every set the game has ever printed.
  ///
  /// [onProgress] lets a catalogue that has to make many requests (Pokémon
  /// enriches each set individually) report how far along it is.
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  });

  /// Every printing of a set, ordered by collector number.
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  });

  /// A single printing by provider id. Null when it does not exist.
  Future<TcgCard?> fetchCardById(String id);

  /// Several printings by provider id, asked for together.
  ///
  /// This exists for the one caller that has a list rather than a card: a
  /// collection names its holdings by id while the catalogue behind them is
  /// downloaded set by set, so a browser that has just signed in on an account
  /// asks about hundreds of printings it has never seen. Which of those ids can
  /// be answered in one request is something only the source knows - for the
  /// tcgcsv games, a whole set's worth of them - and a caller holding the list
  /// is in no position to find out.
  ///
  /// The answer is keyed by the id that was asked about, so a caller that
  /// holds a list of ids - several of them naming the same printing, as a
  /// collection does - can put each answer back where it came from without
  /// trusting the order it gets them in. Printings the source cannot answer for
  /// are simply absent rather than guessed at, because the caller is filling in
  /// rows that already exist and a printing nobody knows is a row that keeps
  /// the placeholder it had.
  ///
  /// The body here is what a source can do when its ids address nothing shared:
  /// ask one at a time.
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    final cards = <String, TcgCard>{};
    for (final id in ids) {
      try {
        final card = await fetchCardById(id);
        if (card != null) cards[id] = card;
      } catch (_) {
        // A source that answers one id at a time fails one id at a time as
        // well; the ids after this one still have an answer coming.
      }
    }
    return cards;
  }

  /// Free-text search. Implementations should return printings, not rollups,
  /// because the printing is what carries the price.
  Future<List<TcgCard>> search(String query, {int limit = 100});

  /// The printings a collector number names, for the parse the caller made.
  ///
  /// A number is an address rather than a word, and a source that can only be
  /// asked in words cannot answer one: the five provider clients search names
  /// and rules text, so asking Scryfall for "001" answers with every card that
  /// mentions it. The app has always answered numbers from its own cache for
  /// exactly that reason, and the default here keeps that unchanged - nothing
  /// at all, without a request - so that a source with a real number lookup can
  /// opt in and no provider is dragged into a question it would answer badly.
  ///
  /// The parse is not this method's business. [CollectorQuery.parse] decides
  /// what part of "BT-26-001" is a set code and what the number is, and the
  /// answer is handed over rather than worked out again: one grammar, and it is
  /// in Dart.
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) async => const <TcgCard>[];

  /// Every printing of the same card, for the "other printings" list.
  Future<List<TcgCard>> fetchPrintingsOf(String groupId);

  /// Re-reads current market prices for the supplied printings.
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards);
}

/// Thrown when a catalogue cannot complete a request.
class CatalogException implements Exception {
  const CatalogException(this.message, {this.statusCode, this.source});

  final String message;
  final int? statusCode;
  final String? source;

  @override
  String toString() =>
      'CatalogException($message${statusCode == null ? '' : ', status $statusCode'})';
}
