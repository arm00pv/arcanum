import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Everything the collector has marked as up for trade.
///
/// The point of the pile is the number at the top: what it is worth, so a
/// trade can be judged rather than guessed at. The list can also be shared as
/// plain text, because the other side of a trade is a person with a phone that
/// does not have this app on it.
class TradeScreen extends ConsumerWidget {
  /// Creates the screen.
  const TradeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final async = ref.watch(collectionOverviewProvider(game));
    final lots =
        <ValuedEntry>[
          for (final v in async.value?.entries ?? const <ValuedEntry>[])
            if (v.entry.forTrade) v,
        ]..sort(
          (ValuedEntry a, ValuedEntry b) =>
              (b.totalValue ?? 0).compareTo(a.totalValue ?? 0),
        );
    final cards = lots.fold<int>(
      0,
      (int a, ValuedEntry v) => a + v.entry.quantity,
    );
    final value = lots.fold<double>(
      0,
      (double a, ValuedEntry v) => a + (v.totalValue ?? 0),
    );

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
                      Text('For trade', style: context.t.titleLarge),
                      Text(
                        lots.isEmpty
                            ? game.shortLabel
                            : '${game.shortLabel}  ·  $cards cards  ·  '
                                  '${Fmt.moneyCompact(value)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                  actions: [
                    if (lots.isNotEmpty)
                      IconButton(
                        tooltip: 'Share the list',
                        icon: const Icon(Icons.ios_share_rounded),
                        onPressed: () => _share(context, game, lots),
                      ),
                  ],
                ),
              ),
              SliverAsyncView<CollectionOverview>(
                value: async,
                loadingHeight: 320,
                onRetry: () => ref.invalidate(collectionOverviewProvider(game)),
                isEmpty: (CollectionOverview o) => lots.isEmpty,
                emptyIcon: Icons.swap_horiz_rounded,
                emptyTitle: 'Nothing is up for trade',
                emptyMessage:
                    'Open a card you own and switch on For trade. It stays in '
                    'your collection, and the trade list keeps a running total '
                    'of what the pile is worth.',
                builder: (CollectionOverview o) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  sliver: SliverList.builder(
                    itemCount: lots.length,
                    itemBuilder: (BuildContext context, int i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _TradeRow(valued: lots[i], game: game),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Shares the pile as text somebody else can read.
  Future<void> _share(
    BuildContext context,
    CardGame game,
    List<ValuedEntry> lots,
  ) async {
    final lines = <String>['${game.shortLabel} for trade', ''];
    for (final lot in lots) {
      final card = lot.card;
      final name = card?.name ?? lot.entry.cardId;
      final set = card == null
          ? ''
          : ' (${card.setCode.toUpperCase()} '
                '${card.collectorNumber})';
      lines.add(
        '${lot.entry.quantity}x $name$set  —  '
        '${Fmt.moneyAdaptive(lot.totalValue)}',
      );
    }
    final total = lots.fold<double>(
      0,
      (double a, ValuedEntry v) => a + (v.totalValue ?? 0),
    );
    lines
      ..add('')
      ..add('Total ${Fmt.moneyAdaptive(total)}');

    await SharePlus.instance.share(
      ShareParams(text: lines.join('\n'), subject: 'Arcanum trade list'),
    );
  }
}

/// One stack on the trade pile.
class _TradeRow extends ConsumerWidget {
  const _TradeRow({required this.valued, required this.game});

  final ValuedEntry valued;
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final entry = valued.entry;
    final card = valued.card;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: game, cardId: entry.cardId),
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
                aspectRatio: game.cardAspectRatio,
                width: 42,
                rarity: CardRarity.fromCode(card?.rarity),
                quantity: entry.quantity.toDouble(),
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
                    _detail(entry, card?.setCode, card?.collectorNumber),
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
              Fmt.moneyAdaptive(valued.totalValue),
              style: context.t.titleSmall?.copyWith(color: c.gold),
            ),
            IconButton(
              tooltip: 'Take off the trade pile',
              iconSize: 20,
              icon: Icon(Icons.remove_circle_outline_rounded, color: c.warning),
              onPressed: () async {
                final id = entry.id;
                if (id == null) return;
                await ref.read(activeCollectionProvider).setForTrade(id, false);
                ref.invalidate(collectionOverviewProvider(game));
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _detail(CollectionEntry entry, String? set, String? number) {
    final where = set == null ? '' : '${set.toUpperCase()} #$number  ·  ';
    return '$where${entry.finish.shortLabel}  ·  '
        '${entry.condition.short}';
  }
}
