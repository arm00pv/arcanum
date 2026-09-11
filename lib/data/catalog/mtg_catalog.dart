import 'package:arcanum/data/api/mtg_adapter.dart';
import 'package:arcanum/data/api/scryfall_client.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Magic: The Gathering card data, served by Scryfall.
class MtgCatalog implements CardCatalog {
  MtgCatalog({ScryfallClient? client}) : _client = client ?? ScryfallClient();

  final ScryfallClient _client;

  @override
  CardGame get game => CardGame.mtg;

  @override
  String get sourceName => 'Scryfall';

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final sets = await _client.fetchAllSets();
      return sets.toTcgSets();
    } on ScryfallException catch (e) {
      throw CatalogException(e.message, statusCode: e.statusCode, source: sourceName);
    }
  }

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      final cards = await _client.fetchCardsInSet(setCode, onProgress: onProgress);
      return cards.toTcgCards();
    } on ScryfallException catch (e) {
      throw CatalogException(e.message, statusCode: e.statusCode, source: sourceName);
    }
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    try {
      final card = await _client.fetchCardById(id);
      return card?.toTcgCard();
    } on ScryfallException catch (e) {
      if (e.isNotFound) return null;
      throw CatalogException(e.message, statusCode: e.statusCode, source: sourceName);
    }
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    try {
      // `unique: false` returns printings rather than one rolled-up card, which
      // is what a collection tracker needs: the printing carries the price.
      final result = await _client.searchCards(query, unique: false);
      return result.cards.take(limit).toList().toTcgCards();
    } on ScryfallException catch (e) {
      if (e.isNotFound) return const [];
      throw CatalogException(e.message, statusCode: e.statusCode, source: sourceName);
    }
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    try {
      final cards = await _client.fetchCardsByOracleId(groupId);
      return cards.toTcgCards();
    } on ScryfallException catch (e) {
      if (e.isNotFound) return const [];
      throw CatalogException(e.message, statusCode: e.statusCode, source: sourceName);
    }
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const [];
    final out = <TcgCard>[];
    // Scryfall's bulk collection endpoint caps at 75 identifiers per call.
    for (var i = 0; i < cards.length; i += 75) {
      final chunk = cards.sublist(i, i + 75 > cards.length ? cards.length : i + 75);
      final identifiers = [
        for (final c in chunk)
          (setCode: c.setCode, collectorNumber: c.collectorNumber),
      ];
      try {
        final fresh = await _client.fetchCollection(identifiers);
        out.addAll(fresh.toTcgCards());
      } on ScryfallException {
        // A partial refresh is still useful; skip the failed chunk.
      }
    }
    return out;
  }
}
