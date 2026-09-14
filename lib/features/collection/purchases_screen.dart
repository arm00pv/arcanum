import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/collection/realised_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// What the collection has cost, and what it is worth now.
///
/// The app has stored a purchase price since the first version and never done
/// anything with it. This is the screen that makes typing one in worth the
/// trouble: the only honest answer to "is this hobby paying for itself" needs
/// both halves, and half of it was already sitting in the database.
class PurchasesScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const PurchasesScreen({super.key});

  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

/// How the lots are ordered.
enum _LotSort { best, worst, biggest }

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  _LotSort _sort = _LotSort.best;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final async = ref.watch(collectionOverviewProvider(game));
    final overview = async.value;
    final lots = _lots(overview, _sort);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: game.accent),
              ),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: GlassAppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Purchases', style: context.t.titleLarge),
                      Text(
                        _subtitle(overview, game),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                  actions: <Widget>[
                    IconButton(
                      tooltip: 'What has actually been sold',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RealisedScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.receipt_long_outlined),
                    ),
                  ],
                ),
              ),
              SliverAsyncView<CollectionOverview>(
                value: async,
                loadingHeight: 380,
                onRetry: () => ref.invalidate(collectionOverviewProvider(game)),
                isEmpty: (CollectionOverview o) => o.entries.isEmpty,
                emptyIcon: Icons.savings_outlined,
                emptyTitle: 'Nothing owned yet',
                emptyMessage:
                    'Add cards to your ${game.shortLabel} collection and '
                    'record what you paid, and this screen will work out what '
                    'the collection cost against what it is worth.',
                builder: (CollectionOverview o) {
                  final recorded = _withCost(o);
                  if (recorded.isEmpty) {
                    return const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(24, 40, 24, 120),
                        child: EmptyState(
                          icon: Icons.receipt_long_outlined,
                          title: 'No purchase prices yet',
                          message:
                              'Arcanum stores what you paid when you add a '
                              'card, and it never leaves this phone. Record a '
                              'price on any card and it appears here as a '
                              'cost basis against what it is worth today.',
                        ),
                      ),
                    );
                  }
                  return SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 120),
                    sliver: SliverList.list(
                      children: [
                        _Ledger(overview: o, lots: recorded),
                        const SizedBox(height: 16),
                        PillToggle(
                          options: const <String>['Best', 'Worst', 'Biggest'],
                          selected: _sort.index,
                          onChanged: (int i) =>
                              setState(() => _sort = _LotSort.values[i]),
                        ),
                        const SizedBox(height: 12),
                        for (int i = 0; i < lots.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _LotTile(
                              valued: lots[i],
                              game: game,
                              index: i,
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _subtitle(CollectionOverview? overview, CardGame game) {
    if (overview == null) return game.shortLabel;
    final cost = overview.totalCost;
    if (cost == null) return '${game.shortLabel}  ·  no costs recorded';
    return '${game.shortLabel}  ·  ${Fmt.moneyCompact(cost)} spent  ·  '
        '${Fmt.moneyCompact(overview.totalValue)} now';
  }

  /// The stacks that have a cost to compare against.
  static List<ValuedEntry> _withCost(CollectionOverview overview) =>
      <ValuedEntry>[
        for (final e in overview.entries)
          if (e.entry.totalCost != null) e,
      ];

  /// The same stacks, ordered the way the collector asked.
  static List<ValuedEntry> _lots(CollectionOverview? overview, _LotSort sort) {
    if (overview == null) return const <ValuedEntry>[];
    final lots = _withCost(overview);

    int byPercent(ValuedEntry a, ValuedEntry b) {
      final pa = a.profitPercent;
      final pb = b.profitPercent;
      if (pa == null && pb == null) return 0;
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pa.compareTo(pb);
    }

    switch (sort) {
      case _LotSort.best:
        lots.sort((ValuedEntry a, ValuedEntry b) => byPercent(b, a));
      case _LotSort.worst:
        lots.sort(byPercent);
      case _LotSort.biggest:
        lots.sort(
          (ValuedEntry a, ValuedEntry b) =>
              (b.profit ?? 0).compareTo(a.profit ?? 0),
        );
    }
    return lots.take(40).toList();
  }
}

/// The headline figures.
class _Ledger extends StatelessWidget {
  const _Ledger({required this.overview, required this.lots});

  final CollectionOverview overview;
  final List<ValuedEntry> lots;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    var cost = 0.0;
    var value = 0.0;
    var cards = 0;
    for (final lot in lots) {
      cost += lot.entry.totalCost ?? 0;
      value += lot.totalValue ?? 0;
      cards += lot.entry.quantity;
    }
    final profit = value - cost;
    final percent = cost > 0 ? profit / cost * 100 : null;
    final worth = profit >= 0;
    // Coverage matters as much as the number: a gain worked out over a tenth
    // of the collection is a fact about that tenth, and saying so is the
    // difference between a report and a misleading one.
    final covered = overview.totalCards == 0
        ? 0
        : (cards / overview.totalCards * 100).round();
    final coverage = covered >= 100
        ? 'Every card in the collection has a recorded cost.'
        : 'A cost is recorded for $covered% of the collection, $cards '
              'of ${overview.totalCards} cards. The rest is left out rather '
              'than guessed at.';

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Figure(label: 'Spent', value: Fmt.moneyAdaptive(cost)),
              _Figure(label: 'Worth now', value: Fmt.moneyAdaptive(value)),
              _Figure(
                label: 'Unrealised',
                value: Fmt.moneySigned(profit),
                colour: worth ? c.positive : c.negative,
                sub: percent == null ? null : '${Fmt.percent(percent)} on cost',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            coverage,
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// One headline figure.
class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    this.colour,
    this.sub,
  });

  final String label;
  final String value;
  final Color? colour;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sub = this.sub;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.titleMedium?.copyWith(color: colour),
          ),
          if (sub != null)
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.labelSmall?.copyWith(
                color: colour ?? c.textTertiary,
              ),
            ),
        ],
      ),
    );
  }
}

/// One stack, priced against what it cost.
class _LotTile extends StatelessWidget {
  const _LotTile({
    required this.valued,
    required this.game,
    required this.index,
  });

  final ValuedEntry valued;
  final CardGame game;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final entry = valued.entry;
    final card = valued.card;
    final profit = valued.profit;
    final percent = valued.profitPercent;
    final up = (profit ?? 0) >= 0;
    final tint = up ? c.positive : c.negative;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: game, cardId: entry.cardId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            SizedBox(
              width: 40,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 40,
                quantity: entry.quantity.toDouble(),
                rarity: CardRarity.fromCode(card?.rarity),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? entry.cardId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'paid ${Fmt.moneyAdaptive(entry.totalCost)}  ·  '
                    'now ${Fmt.moneyAdaptive(valued.totalValue)}',
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  Fmt.moneySigned(profit),
                  style: context.t.titleSmall?.copyWith(color: tint),
                ),
                if (percent != null)
                  Text(
                    Fmt.percent(percent),
                    style: context.t.labelSmall?.copyWith(color: tint),
                  ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 200.ms, delay: (index.clamp(0, 10) * 20).ms);
  }
}
