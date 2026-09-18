import 'package:flutter/foundation.dart';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A game's catalogue: the shared server when there is one to use, the provider
/// whenever there is not.
///
/// This is the whole of step 2's risk management, and the rule it keeps is
/// narrow enough to say in one sentence: the shared catalogue is an
/// optimisation and never a dependency. The phone has no server to prefer, a
/// browser only has one while somebody is signed in and has asked for it, and
/// the five provider clients behind this class are neither changed nor removed
/// - which is what makes the rollback for every step of the migration a switch
/// in Settings rather than a release.
///
/// Two things make the fallback real rather than nominal.
///
/// The decision is made per call rather than at boot, because the catalogue map
/// is built synchronously long before a browser has a session: asking once at
/// startup would answer "no server" for the rest of the session.
///
/// And an answer with nothing in it is not an answer. A catalogue that holds no
/// sets for a game, or nothing for an id it was asked about, has failed in the
/// same way a request that timed out failed - the difference is that it failed
/// quietly - and none of that may be written into the cache as though it were
/// the truth. The cost of this rule is one provider request in the case where
/// the catalogue genuinely has nothing to say, which is what buys never showing
/// an empty Sets tab for a game whose import has not run yet.
class RoutedCatalog extends CardCatalog {
  RoutedCatalog({
    required this.game,
    required CardCatalog provider,
    required CardCatalog server,
    required bool Function() serverAllowed,
  }) : _provider = provider,
       _server = server,
       _mayUseServer = serverAllowed;

  @override
  final CardGame game;

  /// The game's own client, exactly as it is without this class.
  final CardCatalog _provider;

  /// The shared catalogue.
  final CardCatalog _server;

  /// Whether the server may be read for the call about to be made.
  ///
  /// The whole decision - the Settings switch and whether anybody is signed in
  /// - as one question asked at call time, because the answer changes when a
  /// collector signs in and not when the app starts.
  final bool Function() _mayUseServer;

  /// The source currently in play, for the credits and the errors that ask
  /// which one answered.
  @override
  String get sourceName =>
      _mayUseServer() ? _server.sourceName : _provider.sourceName;

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) => _shared(
    read: (CardCatalog server) => server.fetchAllSets(onProgress: onProgress),
    hasAnswer: (List<TcgSet> sets) => sets.isNotEmpty,
    fromProvider: () => _provider.fetchAllSets(onProgress: onProgress),
  );

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) => _shared(
    read: (CardCatalog server) =>
        server.fetchCardsInSet(setCode, onProgress: onProgress),
    hasAnswer: (List<TcgCard> cards) => cards.isNotEmpty,
    fromProvider: () =>
        _provider.fetchCardsInSet(setCode, onProgress: onProgress),
  );

  @override
  Future<TcgCard?> fetchCardById(String id) => _shared(
    read: (CardCatalog server) => server.fetchCardById(id),
    hasAnswer: (TcgCard? card) => card != null,
    fromProvider: () => _provider.fetchCardById(id),
  );

  /// Several printings by id, asked for together.
  ///
  /// A partial answer counts as an answer here, unlike everywhere else in this
  /// class, and the asymmetry is deliberate. Falling back over one id the
  /// catalogue has never heard of would cost a provider request per id in the
  /// batch - the five tcgcsv clients answer a chunk by downloading a whole set,
  /// and the interface's own default asks one at a time - so a batch that
  /// mostly arrived is kept, and the printings missing from it are asked for
  /// again by the next reconciliation. Only a batch the catalogue could answer
  /// nothing at all for goes to the provider.
  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) => _shared(
    read: (CardCatalog server) => server.fetchCardsByIds(ids),
    hasAnswer: (Map<String, TcgCard> cards) => cards.isNotEmpty,
    fromProvider: () => _provider.fetchCardsByIds(ids),
  );

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) => _shared(
    read: (CardCatalog server) => server.search(query, limit: limit),
    hasAnswer: (List<TcgCard> cards) => cards.isNotEmpty,
    fromProvider: () => _provider.search(query, limit: limit),
  );

  /// A printing addressed by its collector number.
  ///
  /// The provider half of this is the interface's default, which is nothing,
  /// and that is not a gap: a number query has never gone to a provider, and
  /// [CatalogRepository.search] answers it from the local cache first. What the
  /// shared catalogue adds is the other half of the same promise - the cache
  /// only holds sets this browser has opened, and a browser that has just
  /// signed in has opened none of them.
  @override
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) => _shared(
    read: (CardCatalog server) =>
        server.fetchCardsByNumber(query, limit: limit),
    hasAnswer: (List<TcgCard> cards) => cards.isNotEmpty,
    fromProvider: () => _provider.fetchCardsByNumber(query, limit: limit),
  );

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) => _shared(
    read: (CardCatalog server) => server.fetchPrintingsOf(groupId),
    hasAnswer: (List<TcgCard> cards) => cards.isNotEmpty,
    fromProvider: () => _provider.fetchPrintingsOf(groupId),
  );

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) => _shared(
    read: (CardCatalog server) => server.refreshPrices(cards),
    hasAnswer: (List<TcgCard> fresh) => fresh.isNotEmpty,
    fromProvider: () => _provider.refreshPrices(cards),
  );

  /// The server's answer, or the provider's.
  ///
  /// [read] is the question, [hasAnswer] decides whether what came back is an
  /// answer at all, and [fromProvider] is what this app does today.
  Future<T> _shared<T>({
    required Future<T> Function(CardCatalog server) read,
    required bool Function(T answer) hasAnswer,
    required Future<T> Function() fromProvider,
  }) async {
    if (!_mayUseServer()) return fromProvider();
    try {
      final T answer = await read(_server);
      if (hasAnswer(answer)) return answer;
      debugPrint('[catalog] ${game.id}: the shared catalogue answered nothing');
    } catch (error) {
      // Swallowed rather than surfaced: a collector is owed the catalogue, not
      // the reason a host they never asked for could not be reached. The
      // console is the only place the failure can be seen at all, which is why
      // it is written there.
      debugPrint('[catalog] ${game.id}: the shared catalogue failed: $error');
    }
    return fromProvider();
  }
}
