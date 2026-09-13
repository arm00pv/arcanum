import 'dart:async';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_source.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// Resolves the best available price history for a printing.
///
/// Resolution order is deliberate: whatever is already stored locally wins, and
/// a network provider is only consulted when the local series is too short to be
/// worth analysing. Results are memoised for the session so scrolling a set grid
/// does not re-query SQLite per tile.
///
/// Providers declare which games they serve, so a Pokémon card is never sent to
/// an MTG-only price endpoint.
class PriceHistoryService {
  PriceHistoryService({required HistoryDao dao, required AppSettings settings})
    : _dao = dao,
      _settings = settings;

  final HistoryDao _dao;
  final AppSettings _settings;

  /// Series shorter than this are treated as "not enough to analyse".
  static const minUsefulPoints = 20;

  final _cache = <String, List<PricePoint>>{};
  final _inFlight = <String, Future<List<PricePoint>>>{};

  /// Network providers configured for a game, most preferred first.
  ///
  /// Every game now has at least one. The companion used to answer for Magic
  /// and Pokémon only, and Yu-Gi-Oh! and Lorcana had nothing at all: neither
  /// YGOPRODeck nor Lorcast publishes a history endpoint, and no free archive
  /// of either exists anywhere. What changed is the samplers - the companion
  /// now records every card of both games once a day, so the one source that
  /// can exist for them is the app's own infrastructure. A trend for those two
  /// starts from the day the sampler was switched on and grows from there,
  /// which is why the companion is listed ahead of the game's own snapshots.
  List<PriceHistorySource> providersFor(CardGame game) {
    final out = <PriceHistorySource>[];
    // Magic has its own endpoint preference because its companion database is
    // rebuilt from MTGJSON and is a different thing entirely; every other game
    // is served by the daily samplers behind the other endpoint.
    final companion = game == CardGame.mtg
        ? _settings.historyEndpoint
        : _settings.pokemonHistoryEndpoint;
    if (companion.isNotEmpty) {
      // serveGame is not decoration: the source declares which games it serves
      // and is filtered out for the others, so leaving it at its Magic default
      // would have quietly dropped this source for every other game.
      out.add(BackfillPackSource(baseUrl: companion, serveGame: game));
    }
    if (_settings.justTcgKey.isNotEmpty) {
      out.add(JustTcgHistorySource(apiKey: _settings.justTcgKey, game: game));
    }
    if (game == CardGame.mtg) {
      // Free, keyless, and the only source with multi-year depth for Magic.
      out.add(MtgStocksHistorySource(cache: _dao));
    } else if (game == CardGame.pokemon) {
      // Free, keyless, and roughly two years deep — but the scrape stopped in
      // September 2024, so it is a historical archive rather than a live feed.
      // Live Pokémon data comes from JustTCG (when keyed), the companion and
      // the app's own daily snapshots.
      out.add(TcgDexPriceHistorySource());
    }
    out.retainWhere((p) => p.supportedGames.contains(game));
    return out;
  }

  /// True when at least one network provider serves this game.
  bool hasNetworkProvider(CardGame game) =>
      providersFor(game).any((p) => p.isConfigured);

  static String _key(CardGame game, String id, CardFinish f) =>
      '${game.id}|$id|${f.code}';

  /// Returns the best series available for a printing, oldest first.
  ///
  /// Never throws: on any failure it degrades to whatever is stored locally.
  Future<List<PricePoint>> historyFor(
    CardGame game,
    String cardId, {
    CardFinish? finish,
    int days = 400,
    bool allowNetwork = true,
    String? cardName,
    String? externalId,
  }) async {
    final f = finish ?? game.finishes.first;
    final k = _key(game, cardId, f);
    final cached = _cache[k];
    if (cached != null && cached.isNotEmpty) return cached;

    final pending = _inFlight[k];
    if (pending != null) return pending;

    final future = _resolve(
      game,
      cardId,
      f,
      days,
      allowNetwork,
      cardName,
      externalId,
    );
    _inFlight[k] = future;
    try {
      final result = await future;
      if (result.isNotEmpty) _cache[k] = result;
      return result;
    } finally {
      _inFlight.remove(k);
    }
  }

  Future<List<PricePoint>> _resolve(
    CardGame game,
    String cardId,
    CardFinish finish,
    int days,
    bool allowNetwork,
    String? cardName,
    String? externalId,
  ) async {
    var local = await _dao.series(game, cardId, finish: finish, days: days);
    if (local.length >= minUsefulPoints || !allowNetwork) return local;

    for (final provider in providersFor(game)) {
      if (!provider.isConfigured) continue;
      try {
        final remote = await provider
            .fetch(
              cardId,
              finish: finish,
              days: days,
              cardName: cardName,
              externalId: externalId,
            )
            .timeout(const Duration(seconds: 25));
        if (remote.length < minUsefulPoints) continue;
        await _dao.recordMany(
          game: game,
          cardId: cardId,
          finish: finish,
          points: remote,
          source: provider.id,
        );
        // Re-read so the merge with local snapshots is applied consistently.
        local = await _dao.series(game, cardId, finish: finish, days: days);
        if (local.length >= minUsefulPoints) return local;
      } catch (_) {
        // Try the next provider.
      }
    }
    return local;
  }

  /// Fetches history for many printings, for the network providers only.
  ///
  /// Bounded concurrency keeps the companion service and any rate-limited API
  /// happy. Returns the number of printings that gained usable history.
  Future<int> backfill(
    CardGame game,
    List<String> cardIds, {
    CardFinish? finish,
    int days = 400,
    int concurrency = 4,
    void Function(int done, int total)? onProgress,
  }) async {
    final f = finish ?? game.finishes.first;
    if (providersFor(game).isEmpty || cardIds.isEmpty) return 0;

    var improved = 0;
    var done = 0;
    final queue = List<String>.from(cardIds);

    Future<void> worker() async {
      while (true) {
        final id = queue.isEmpty ? null : queue.removeLast();
        if (id == null) return;
        final before = (await _dao.series(
          game,
          id,
          finish: f,
          days: days,
        )).length;
        _cache.remove(_key(game, id, f));
        final after = (await historyFor(
          game,
          id,
          finish: f,
          days: days,
        )).length;
        if (after > before && after >= minUsefulPoints) improved++;
        done++;
        onProgress?.call(done, cardIds.length);
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 8), (_) => worker()));
    return improved;
  }

  /// Records today's provider prices as a snapshot, so history accumulates even
  /// without a backfill provider.
  Future<int> recordSnapshots(
    CardGame game,
    Map<String, double?> pricesByCard, {
    CardFinish? finish,
  }) async {
    final f = finish ?? game.finishes.first;
    final now = DateTime.now();
    var n = 0;
    for (final e in pricesByCard.entries) {
      final price = e.value;
      if (price == null || price <= 0) continue;
      await _dao.record(
        game: game,
        cardId: e.key,
        finish: f,
        date: now,
        price: price,
        source: 'snapshot',
      );
      _cache.remove(_key(game, e.key, f));
      n++;
    }
    return n;
  }

  /// Clears the in-memory memoisation, e.g. after a settings change.
  void invalidate() {
    _cache.clear();
    _inFlight.clear();
  }
}
