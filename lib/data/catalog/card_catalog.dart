import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A source of card data for exactly one game.
///
/// Magic comes from Scryfall and Pokémon from the Pokémon TCG API, and the two
/// have almost nothing in common at the wire level: different pagination,
/// different collector-number formats, different price vocabularies, different
/// rate limits. Everything above this interface works in [TcgCard] and [TcgSet]
/// and never has to care which game it is looking at.
abstract interface class CardCatalog {
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

  /// Free-text search. Implementations should return printings, not rollups,
  /// because the printing is what carries the price.
  Future<List<TcgCard>> search(String query, {int limit = 100});

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
