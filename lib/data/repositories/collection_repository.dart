import 'dart:math' as math;

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// Aggregated view of everything the user owns in one game.
class CollectionOverview {
  const CollectionOverview({
    required this.game,
    required this.entries,
    required this.totalValue,
    required this.totalCost,
    required this.totalCards,
    required this.uniqueCards,
    required this.valueBySet,
    required this.valueByCategory,
    required this.valueByRarity,
    required this.valueByFinish,
    required this.topHoldings,
    required this.movers,
    required this.pricedCards,
    required this.unpricedCards,
    required this.concentration,
  });

  /// Which game this overview describes.
  final CardGame game;

  /// Every stack, richest first.
  final List<ValuedEntry> entries;

  final double totalValue;

  /// Sum of recorded purchase prices, or null when nothing has a cost basis.
  final double? totalCost;

  final int totalCards;
  final int uniqueCards;

  /// Market value grouped by set name.
  final Map<String, double> valueBySet;

  /// Market value grouped by mana colour (Magic) or energy type (Pokémon).
  final Map<ColourBucket, double> valueByCategory;

  final Map<CardRarity, double> valueByRarity;
  final Map<CardFinish, double> valueByFinish;

  /// The most valuable stacks.
  final List<ValuedEntry> topHoldings;

  /// Stacks with the largest absolute change over the recent window.
  final List<ValuedEntry> movers;

  final int pricedCards;
  final int unpricedCards;

  /// Herfindahl-Hirschman index over holdings, 0 (diversified) to 1 (one card).
  ///
  /// A useful, honest concentration measure: above roughly 0.25 a single card
  /// dominates the collection's risk.
  final double concentration;

  double? get unrealizedProfit =>
      totalCost == null ? null : totalValue - totalCost!;

  double? get unrealizedProfitPercent {
    final cost = totalCost;
    if (cost == null || cost <= 0) return null;
    return (totalValue - cost) / cost * 100.0;
  }

  bool get isEmpty => entries.isEmpty;

  /// An empty overview for a game that has nothing in it yet.
  factory CollectionOverview.empty(CardGame game) => CollectionOverview(
    game: game,
    entries: const [],
    totalValue: 0,
    totalCost: 0,
    totalCards: 0,
    uniqueCards: 0,
    valueBySet: const {},
    valueByCategory: const {},
    valueByRarity: const {},
    valueByFinish: const {},
    topHoldings: const [],
    movers: const [],
    pricedCards: 0,
    unpricedCards: 0,
    concentration: 0,
  );
}

/// Owns one game's collection: what the user has, what it is worth, and how it
/// is changing.
///
/// A repository is created per game, so it is impossible to value a Pokémon
/// holding against a Magic price list or to mix two portfolios in one total.
class CollectionRepository {
  CollectionRepository({
    required this.game,
    required CollectionDao collectionDao,
    required CatalogDao catalogDao,
    required HistoryDao historyDao,
    required PriceHistoryService history,
    required CatalogRepository catalogs,
    required AppSettings settings,
  }) : _catalogs = catalogs,
       _col = collectionDao,
       _cat = catalogDao,
       _hist = historyDao,
       _history = history,
       _settings = settings;

  /// The game this repository is scoped to.
  final CardGame game;

  final CatalogRepository _catalogs;
  final CollectionDao _col;
  final CatalogDao _cat;
  final HistoryDao _hist;
  final PriceHistoryService _history;
  final AppSettings _settings;

  // ------------------------------------------------------------- mutations

  Future<int> addCard({
    required String cardId,
    CardFinish? finish,
    CardCondition? condition,
    String language = 'en',
    int quantity = 1,
    double? purchasePrice,
    DateTime? purchaseDate,
    String binder = '',
    String? notes,
  }) => _col.addOrMerge(
    game: game,
    cardId: cardId,
    finish: finish ?? game.finishes.first,
    condition: condition ?? CardCondition.nearMint,
    language: language,
    quantity: quantity,
    purchasePrice: purchasePrice,
    purchaseDate: purchaseDate,
    binder: binder,
    notes: notes,
  );

  Future<void> setQuantity(int entryId, int quantity) =>
      _col.setQuantity(entryId, quantity);

  Future<void> removeEntry(int entryId) => _col.delete(entryId);

  /// Puts a stack on the trade pile, or takes it off.
  Future<void> setForTrade(int entryId, bool forTrade) =>
      _col.setForTrade(entryId, forTrade);

  Future<void> updateEntry(CollectionEntry entry) => _col.updateEntry(entry);

  Future<List<CollectionEntry>> entriesForCard(String cardId) =>
      _col.forCard(game, cardId);

  Future<Map<String, List<CollectionEntry>>> entriesForCards(
    List<String> ids,
  ) => _col.forCards(game, ids);

  Future<List<String>> binders() => _col.binders(game);

  Future<int> totalCardCount() => _col.totalCardCount(game);

  Future<int> uniqueCount() => _col.uniqueCount(game);

  // ------------------------------------------------------------- valuation

  /// The market value of one physical copy.
  ///
  /// Falls back to whichever finish the provider actually quotes rather than
  /// reporting nothing, which is what every serious tracker does. Condition is
  /// applied as a multiplier only when the user opts in.
  double? unitValueFor(
    TcgCard card, {
    CardFinish? finish,
    CardCondition condition = CardCondition.nearMint,
  }) {
    final wanted = finish ?? game.finishes.first;
    var base = card.prices.priceFor(wanted);
    // Fall back through the finishes this game actually has, then to anything
    // the provider quoted under a different name.
    if (base == null || base <= 0) {
      for (final f in game.finishes) {
        final v = card.prices.priceFor(f);
        if (v != null && v > 0) {
          base = v;
          break;
        }
      }
    }
    base ??= card.prices.from;
    if (base == null || base <= 0) return null;
    final mult = _settings.conditionAdjust ? condition.priceMultiplier : 1.0;
    return base * mult;
  }

  /// The reference price of a printing, ignoring finish and condition.
  double? referencePrice(TcgCard card) => card.prices.from;

  /// Builds the full portfolio picture for this game.
  Future<CollectionOverview> overview({bool withMovers = false}) async {
    final entries = await _col.all(game);
    if (entries.isEmpty) return CollectionOverview.empty(game);

    final cards = await _cat.cardsByIds(
      game,
      entries.map((e) => e.cardId).toSet().toList(),
    );

    double totalValue = 0;
    double totalCost = 0;
    var hasCost = false;
    var priced = 0;
    var unpriced = 0;

    final bySet = <String, double>{};
    final byCategory = <ColourBucket, double>{};
    final byRarity = <CardRarity, double>{};
    final byFinish = <CardFinish, double>{};
    final valued = <ValuedEntry>[];

    for (final e in entries) {
      final card = cards[e.cardId];
      final unit = card == null
          ? null
          : unitValueFor(card, finish: e.finish, condition: e.condition);
      final v = ValuedEntry(entry: e, unitValue: unit, card: card);
      valued.add(v);

      if (unit == null) {
        unpriced += e.quantity;
      } else {
        priced += e.quantity;
        final value = unit * e.quantity;
        totalValue += value;
        final setName = card!.setName.isEmpty
            ? card.setCode.toUpperCase()
            : card.setName;
        bySet.update(setName, (x) => x + value, ifAbsent: () => value);
        // Magic buckets by colour identity, Pokémon by energy type and
        // Yu-Gi-Oh! by monster attribute; the latter two both carry their
        // category in `colors`, so only Magic needs the other list.
        final bucket = game.dominantBucket(
          game == CardGame.mtg ? card.colorIdentity : card.colors,
        );
        byCategory.update(bucket, (x) => x + value, ifAbsent: () => value);
        byRarity.update(
          CardRarity.fromCode(card.rarity),
          (x) => x + value,
          ifAbsent: () => value,
        );
        byFinish.update(e.finish, (x) => x + value, ifAbsent: () => value);
      }
      final cost = e.totalCost;
      if (cost != null) {
        hasCost = true;
        totalCost += cost;
      }
    }

    valued.sort((a, b) => (b.totalValue ?? 0).compareTo(a.totalValue ?? 0));

    // Concentration over priced holdings only.
    var hhi = 0.0;
    if (totalValue > 0) {
      for (final v in valued) {
        final share = (v.totalValue ?? 0) / totalValue;
        hhi += share * share;
      }
    }

    var movers = const <ValuedEntry>[];
    if (withMovers) movers = await _computeMovers(valued);

    return CollectionOverview(
      game: game,
      entries: valued,
      totalValue: totalValue,
      totalCost: hasCost ? totalCost : null,
      totalCards: entries.fold<int>(0, (a, e) => a + e.quantity),
      uniqueCards: cards.length,
      valueBySet: _sortedByValue(bySet),
      valueByCategory: byCategory,
      valueByRarity: byRarity,
      valueByFinish: byFinish,
      topHoldings: valued.take(10).toList(),
      movers: movers,
      pricedCards: priced,
      unpricedCards: unpriced,
      concentration: hhi,
    );
  }

  Future<List<ValuedEntry>> _computeMovers(List<ValuedEntry> valued) async {
    final top = valued.take(60).toList();
    final out = <ValuedEntry>[];
    for (final v in top) {
      if (v.unitValue == null) continue;
      final series = await _history.historyFor(
        game,
        v.entry.cardId,
        finish: v.entry.finish,
        days: 90,
        allowNetwork: false,
      );
      if (series.length < 8) continue;
      final first = series[series.length - 8].price;
      if (first <= 0) continue;
      final pct = (series.last.price / first - 1) * 100.0;
      out.add(
        ValuedEntry(
          entry: v.entry,
          unitValue: v.unitValue,
          card: v.card,
          dayChangePercent: pct,
        ),
      );
    }
    out.sort(
      (a, b) => (b.dayChangePercent ?? 0).abs().compareTo(
        (a.dayChangePercent ?? 0).abs(),
      ),
    );
    return out.take(10).toList();
  }

  static Map<String, double> _sortedByValue(Map<String, double> m) {
    final entries = m.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {for (final e in entries) e.key: e.value};
  }

  // -------------------------------------------------------------- analytics

  /// Runs the full on-device analytics engine for one printing.
  Future<CardAnalytics> analyticsFor(
    String cardId, {
    CardFinish? finish,
    int windowDays = 400,
    bool allowNetwork = true,
  }) async {
    final wanted = finish ?? game.finishes.first;
    final card = await _cat.cardById(game, cardId);
    final series = await _history.historyFor(
      game,
      cardId,
      finish: wanted,
      days: windowDays,
      allowNetwork: allowNetwork,
      cardName: card?.name,
      // Pokémon has no Scryfall id, so a provider's own product id is handed
      // over when the catalogue captured one.
      externalId: card?.extras['tcgplayerId']?.toString(),
    );
    return analyzeSeries(
      series,
      windowDays: _effectiveWindow(series, windowDays),
    );
  }

  /// Sizes the analysis window to the data actually available.
  ///
  /// The engine's confidence term compares the number of real observations with
  /// the window length, so passing a fixed 400-day window would report a
  /// perfectly dense 90-day series as "thin data" purely because the card is
  /// younger than the window. Measuring against the true span makes coverage
  /// mean what it should: how densely the period is actually sampled.
  static int _effectiveWindow(List<PricePoint> series, int requested) {
    if (series.length < 2) return requested;
    final span = series.last.date.difference(series.first.date).inDays + 1;
    return span.clamp(14, requested);
  }

  /// Analytics for many printings at once, keyed by card id.
  ///
  /// Reads only local history so a large collection never triggers a flood of
  /// network requests.
  Future<Map<String, CardAnalytics>> analyticsForMany(
    List<String> cardIds, {
    CardFinish? finish,
    int windowDays = 400,
  }) async {
    final wanted = finish ?? game.finishes.first;
    final seriesMap = await _hist.seriesForCards(
      game,
      cardIds,
      finish: wanted,
      days: windowDays,
    );
    return {
      for (final e in seriesMap.entries)
        e.key: analyzeSeries(
          e.value,
          windowDays: _effectiveWindow(e.value, windowDays),
        ),
    };
  }

  // -------------------------------------------------------------- snapshots

  /// Records today's prices for everything owned in this game.
  ///
  /// Returns the number of observations written.
  Future<int> recordDailySnapshot({bool force = false}) async {
    final last = _settings.lastSnapshotFor(game);
    if (!force && last != null) {
      final now = DateTime.now();
      final sameDay =
          last.year == now.year &&
          last.month == now.month &&
          last.day == now.day;
      if (sameDay) return 0;
    }

    final entries = await _col.all(game);
    if (entries.isEmpty) return 0;

    // Pull today's market price for everything owned before recording it.
    // Cached prices are only as fresh as the last set download, so without
    // this the snapshot would faithfully record a stale number and the
    // resulting history would be quietly wrong.
    try {
      await _catalogs.refreshPrices(
        game,
        entries.map((e) => e.cardId).toSet().toList(),
      );
    } catch (_) {
      // Offline, or the provider refused. Recording what we have beats
      // skipping the day and leaving a hole in the series.
    }

    final cards = await _cat.cardsByIds(
      game,
      entries.map((e) => e.cardId).toSet().toList(),
    );

    var written = 0;
    final byFinish = <CardFinish, Map<String, double?>>{};
    for (final e in entries) {
      final card = cards[e.cardId];
      if (card == null) continue;
      byFinish.putIfAbsent(e.finish, () => {})[e.cardId] =
          card.prices.priceFor(e.finish) ?? card.prices.from;
    }

    for (final e in byFinish.entries) {
      written += await _history.recordSnapshots(game, e.value, finish: e.key);
    }

    // Also keep a portfolio-level series for the dashboard chart.
    final ov = await overview();
    await _hist.recordPortfolioSnapshot(
      game: game,
      totalValue: ov.totalValue,
      uniqueCards: ov.uniqueCards,
      totalCards: ov.totalCards,
    );

    _settings.setLastSnapshot(game, DateTime.now());
    return written;
  }

  /// The portfolio value series for this game, oldest first.
  Future<List<PricePoint>> portfolioSeries({int days = 400}) =>
      _hist.portfolioSeries(game, days: days);

  /// Pulls real history for this game's whole collection from the configured
  /// providers.
  Future<int> backfillCollection({
    void Function(int done, int total)? onProgress,
  }) async {
    final entries = await _col.all(game);
    if (entries.isEmpty) return 0;
    final byFinish = <CardFinish, List<String>>{};
    for (final e in entries) {
      byFinish.putIfAbsent(e.finish, () => []).add(e.cardId);
    }
    var improved = 0;
    for (final e in byFinish.entries) {
      improved += await _history.backfill(
        game,
        e.value.toSet().toList(),
        finish: e.key,
        onProgress: onProgress,
      );
    }
    return improved;
  }

  /// Total market value, used by the dashboard headline.
  Future<double> totalValue() async => (await overview()).totalValue;

  /// Standard deviation of holding values, a crude risk read-out.
  static double spreadOf(CollectionOverview o) {
    if (o.entries.isEmpty) return 0;
    final values = o.entries.map((e) => e.totalValue ?? 0).toList();
    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance =
        values
            .map((v) => math.pow(v - mean, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    return math.sqrt(variance);
  }
}
