import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/quant/quant.dart';
import 'package:arcanum/features/alerts/alerts_screen.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/settings/settings_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/delta_chip.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/mana_pips.dart';
import 'package:arcanum/widgets/sliver_async.dart';
import 'package:arcanum/widgets/sparkline.dart';

/// The Vault: what the collection is worth, what it is made of, and what moved.
///
/// Every figure on this screen belongs to the active game alone. Switching games
/// in the switcher above rebuilds all of it against the other game's catalogue,
/// collection and price series.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _scrollController = ScrollController();
  double _scrollOffset = 0;
  bool _snapshotting = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSnapshot());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Records today's prices once per day for the active game, so a real history
  /// builds up even without any external provider.
  ///
  /// Snapshots are per game: Magic and Pokémon keep separate timelines, and
  /// opening one must never mark the other as already done for the day.
  Future<void> _maybeSnapshot() async {
    if (_snapshotting) return;
    final game = ref.read(activeGameProvider);
    final settings = ref.read(settingsProvider);
    if (!settings.autoSnapshot) return;
    final last = settings.lastSnapshotFor(game);
    final now = DateTime.now();
    if (last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day) {
      return;
    }
    _snapshotting = true;
    try {
      await ref
          .read(bootstrapProvider)
          .collectionFor(game)
          .recordDailySnapshot();
      if (!mounted) return;
      ref.invalidate(portfolioSeriesProvider(game));
      ref.invalidate(collectionOverviewProvider(game));
    } catch (_) {
      // A failed snapshot must never break the dashboard.
    } finally {
      _snapshotting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);

    // A switch brings a whole different portfolio, with its own snapshot day.
    ref.listen<CardGame>(activeGameProvider, (previous, next) {
      if (previous != next) _maybeSnapshot();
    });

    final overviewAsync = ref.watch(collectionOverviewProvider(game));
    final series =
        ref.watch(portfolioSeriesProvider(game)).value ?? const <PricePoint>[];
    final cards =
        ref.watch(ownedCardsProvider(game)).value ?? const <String, TcgCard>{};
    final cataloguedSets = ref.watch(setCountProvider(game)).value ?? 0;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppTheme.backdrop(c)),
            ),
          ),
          RefreshIndicator(
            color: c.accent,
            backgroundColor: c.surface,
            onRefresh: () async {
              ref.invalidate(collectionOverviewProvider(game));
              ref.invalidate(ownedCardsProvider(game));
              ref.invalidate(portfolioSeriesProvider(game));
              ref.invalidate(setCountProvider(game));
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: GlassAppBar(
                    scrollOffset: _scrollOffset,
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Arcanum', style: context.t.headlineMedium),
                        Text(
                          '${game.shortLabel} vault',
                          style: context.t.bodySmall,
                        ),
                      ],
                    ),
                    actions: [
                      _AlertsButton(game: game),
                      IconButton(
                        tooltip: 'Settings',
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SliverAsyncView<CollectionOverview>(
                  value: overviewAsync,
                  loadingHeight: 420,
                  onRetry: () =>
                      ref.invalidate(collectionOverviewProvider(game)),
                  isEmpty: (o) => o.entries.isEmpty,
                  emptyTitle: 'Your ${game.shortLabel} vault is empty',
                  emptyMessage:
                      'Browse the Sets tab to explore ${game.label} — '
                      '${Fmt.count(cataloguedSets)} sets catalogued from '
                      '${game.dataSource}. Add the copies you own and Arcanum '
                      'values them against live market prices and tracks how '
                      'they move.',
                  builder: (o) => SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
                    sliver: SliverList.list(
                      children: [
                        _ValueHero(overview: o, series: series, game: game),
                        const SizedBox(height: 14),
                        _StatGrid(overview: o),
                        if (o.valueByCategory.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          SectionHeader(
                            title: _categorySectionTitle(game),
                            subtitle: _categorySectionSubtitle(game),
                            padding: const EdgeInsets.only(bottom: 10),
                          ),
                          _CategoryAllocation(values: o.valueByCategory),
                        ],
                        if (o.valueByRarity.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          const SectionHeader(
                            title: 'By rarity',
                            padding: EdgeInsets.only(bottom: 10),
                          ),
                          _RarityAllocation(values: o.valueByRarity),
                        ],
                        if (o.valueBySet.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          const SectionHeader(
                            title: 'Top sets',
                            padding: EdgeInsets.only(bottom: 10),
                          ),
                          _SetAllocation(values: o.valueBySet),
                        ],
                        const SizedBox(height: 22),
                        const SectionHeader(
                          title: 'Most valuable',
                          padding: EdgeInsets.only(bottom: 10),
                        ),
                        for (var i = 0; i < o.topHoldings.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _HoldingRow(
                              valued: o.topHoldings[i],
                              card: cards[o.topHoldings[i].entry.cardId],
                              game: game,
                              index: i,
                            ),
                          ),
                        if (o.movers.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          const SectionHeader(
                            title: 'Recent movement',
                            subtitle: 'Largest price change over the last week',
                            padding: EdgeInsets.only(bottom: 10),
                          ),
                          for (final m in o.movers.take(6))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _MoverRow(
                                valued: m,
                                card: cards[m.entry.cardId],
                                game: game,
                              ),
                            ),
                        ],
                        const SizedBox(height: 22),
                        _InsightCard(overview: o),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What a game's allocation section is called.
///
/// Magic buckets its collection by mana colour, Pokémon by energy type,
/// Yu-Gi-Oh! by monster attribute and Lorcana by ink, so one shared title would
/// be a lie for three games out of four.
String _categorySectionTitle(CardGame game) => switch (game) {
  CardGame.mtg => 'By colour',
  CardGame.pokemon => 'By energy type',
  CardGame.yugioh => 'By attribute',
  CardGame.lorcana => 'By ink',
};

/// Explains what the buckets are measured against, per game.
String _categorySectionSubtitle(CardGame game) => switch (game) {
  CardGame.mtg => 'Market value by colour identity',
  CardGame.pokemon => 'Market value by Pokémon type',
  // Spell and Trap cards carry no attribute, so the chart has a slice for
  // them rather than pretending they belong to one of the seven.
  CardGame.yugioh => 'Market value by attribute, Spells and Traps apart',
  // A handful of cards are printed in two inks; they land in the first.
  CardGame.lorcana => 'Market value by ink',
};

/// The headline: total value, change, and the portfolio curve.
class _ValueHero extends StatelessWidget {
  const _ValueHero({
    required this.overview,
    required this.series,
    required this.game,
  });

  final CollectionOverview overview;
  final List<PricePoint> series;
  final CardGame game;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final values = series.map((p) => p.price).toList();
    final change = values.length >= 2
        ? (values.last / values[values.length - 2] - 1) * 100
        : null;
    final sinceStart = values.length >= 2 && values.first > 0
        ? (values.last / values.first - 1) * 100
        : null;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      borderGradient: LinearGradient(
        colors: [
          c.accent.withValues(alpha: 0.7),
          c.accent.withValues(alpha: 0.05),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'PORTFOLIO VALUE',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const Spacer(),
              if (change != null) DeltaChip(percent: change),
            ],
          ),
          const SizedBox(height: 6),
          Text(Fmt.money(overview.totalValue), style: context.t.displayMedium),
          const SizedBox(height: 4),
          Text(
            '${game.shortLabel} · ${Fmt.count(overview.totalCards)} cards · '
            '${Fmt.count(overview.uniqueCards)} unique · '
            '${overview.valueBySet.length} sets',
            style: context.t.bodySmall,
          ),
          const SizedBox(height: 14),
          if (values.length >= 3) ...[
            Sparkline(
              values: values,
              height: 54,
              color: c.forDelta(sinceStart ?? 0),
              strokeWidth: 2,
            ),
            const SizedBox(height: 6),
            Text(
              'Since ${Fmt.dateShort(series.first.date)}  ·  '
              '${Fmt.percent(sinceStart)}',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ] else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.surfaceRaised,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.hairline),
              ),
              child: Row(
                children: [
                  Icon(Icons.insights_rounded, size: 16, color: c.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Arcanum records one value snapshot per day for '
                      '${game.shortLabel}. Your portfolio curve appears after '
                      'a few days.',
                      style: context.t.labelSmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.overview});
  final CollectionOverview overview;

  @override
  Widget build(BuildContext context) {
    final profit = overview.unrealizedProfit;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Cards',
                value: Fmt.count(overview.totalCards),
                icon: Icons.layers_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                label: 'Unique',
                value: Fmt.count(overview.uniqueCards),
                icon: Icons.style_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: StatTile(
                label: 'Cost basis',
                value: overview.totalCost == null
                    ? '--'
                    : Fmt.moneyCompact(overview.totalCost),
                caption: overview.totalCost == null ? 'Not recorded' : null,
                icon: Icons.receipt_long_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatTile(
                label: 'Unrealised P/L',
                value: profit == null ? '--' : Fmt.moneySigned(profit),
                delta: overview.unrealizedProfitPercent,
                valueColor: profit == null ? null : context.c.forDelta(profit),
                icon: Icons.trending_up_rounded,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Where a game's value sits across its own categories.
///
/// Magic allocates by mana colour, Pokémon by energy type and Yu-Gi-Oh! by
/// monster attribute. They are different concepts that happen to share a shape,
/// so the rows are driven by [ColourBucket] and the swatch is a plain filled
/// circle — a mana pip would be nonsense next to a Pokémon type. Whatever the
/// active game does not use simply never appears in the map.
class _CategoryAllocation extends StatelessWidget {
  const _CategoryAllocation({required this.values});

  /// Market value per category, keyed by mana colour or energy type.
  final Map<ColourBucket, double> values;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final total = values.values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();
    final sorted = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 12,
              child: Row(
                children: [
                  for (final e in sorted)
                    Expanded(
                      flex: ((e.value / total) * 1000).round().clamp(1, 1000),
                      child: ColoredBox(color: e.key.accent),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final e in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  // A filled circle works for a colour and for an energy type
                  // alike, which a mana pip would not.
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: e.key.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.hairline),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      e.key.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(Fmt.moneyCompact(e.value), style: context.t.bodyMedium),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 46,
                    child: Text(
                      Fmt.percentPlain(e.value / total * 100),
                      textAlign: TextAlign.right,
                      style: context.t.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _RarityAllocation extends StatelessWidget {
  const _RarityAllocation({required this.values});
  final Map<CardRarity, double> values;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final total = values.values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();
    final sorted = values.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          for (final e in sorted)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  RarityBadge(rarity: e.key, compact: true),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (e.value / total).clamp(0, 1),
                        minHeight: 7,
                        backgroundColor: c.surfaceRaised,
                        valueColor: AlwaysStoppedAnimation(e.key.color),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 74,
                    child: Text(
                      Fmt.moneyCompact(e.value),
                      textAlign: TextAlign.right,
                      style: context.t.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SetAllocation extends StatelessWidget {
  const _SetAllocation({required this.values});
  final Map<String, double> values;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final top = values.entries.take(6).toList();
    final total = values.values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          for (final e in top)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (e.value / total).clamp(0, 1),
                        minHeight: 6,
                        backgroundColor: c.surfaceRaised,
                        valueColor: AlwaysStoppedAnimation(c.gold),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 70,
                    child: Text(
                      Fmt.moneyCompact(e.value),
                      textAlign: TextAlign.right,
                      style: context.t.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HoldingRow extends StatelessWidget {
  const _HoldingRow({
    required this.valued,
    required this.card,
    required this.game,
    required this.index,
  });

  final ValuedEntry valued;
  final TcgCard? card;

  /// The game the printing belongs to: card lookups are per game.
  final CardGame game;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final share = valued.totalValue;
    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: card == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CardDetailScreen(game: game, cardId: card!.id),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 42,
                rarity: CardRarity.fromCode(card?.rarity),
                quantity: valued.entry.quantity.toDouble(),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? '--',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  Text(
                    card == null
                        ? '--'
                        : '${card!.setCode.toUpperCase()} #${card!.collectorNumber} · '
                              '${valued.entry.quantity} x ${Fmt.moneyAdaptive(valued.unitValue)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              share == null ? '--' : Fmt.money(share),
              style: context.t.titleSmall,
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 180.ms, delay: (index.clamp(0, 10) * 18).ms);
  }
}

class _MoverRow extends StatelessWidget {
  const _MoverRow({
    required this.valued,
    required this.card,
    required this.game,
  });

  final ValuedEntry valued;
  final TcgCard? card;
  final CardGame game;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      onTap: card == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CardDetailScreen(game: game, cardId: card!.id),
              ),
            ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              card?.name ?? '--',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.bodyMedium,
            ),
          ),
          Text(
            Fmt.money(valued.totalValue),
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(width: 10),
          DeltaChip(percent: valued.dayChangePercent, compact: true),
        ],
      ),
    );
  }
}

/// A short, honest read on concentration risk.
class _InsightCard extends StatelessWidget {
  const _InsightCard({required this.overview});
  final CollectionOverview overview;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hhi = overview.concentration;

    final String headline;
    final String body;
    if (hhi > 0.35) {
      headline = 'Highly concentrated';
      body = 'One or two cards dominate your collection. A single price drop would move your total sharply.';
    } else if (hhi > 0.15) {
      headline = 'Moderately concentrated';
      body = 'Your value is spread across a handful of cards. That is typical for a focused collection.';
    } else {
      headline = 'Well diversified';
      body = 'No single card dominates your holdings, so your total is relatively insulated from one card moving.';
    }

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_rounded, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Text('Portfolio read', style: context.t.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(headline, style: context.t.titleMedium),
          const SizedBox(height: 4),
          Text(body, style: context.t.bodySmall?.copyWith(height: 1.45)),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                'Concentration index',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const Spacer(),
              Text(hhi.toStringAsFixed(3), style: context.t.labelMedium),
            ],
          ),
          if (overview.unpricedCards > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${Fmt.count(overview.unpricedCards)} cards have no market price and are '
              'excluded from the total.',
              style: context.t.labelSmall?.copyWith(color: c.warning),
            ),
          ],
        ],
      ),
    );
  }
}

/// The alerts bell, badged with how many rules have fired.
class _AlertsButton extends ConsumerWidget {
  const _AlertsButton({required this.game});

  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final fired = ref.watch(triggeredAlertCountProvider(game)).value ?? 0;

    final button = IconButton(
      tooltip: fired == 0 ? 'Price alerts' : '$fired alert(s) triggered',
      icon: Icon(
        fired == 0
            ? Icons.notifications_none_rounded
            : Icons.notifications_active_rounded,
        color: fired == 0 ? null : c.warning,
      ),
      onPressed: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const AlertsScreen())),
    );

    if (fired == 0) return button;

    return Badge(
      label: Text('$fired'),
      backgroundColor: c.warning,
      child: button,
    );
  }
}
