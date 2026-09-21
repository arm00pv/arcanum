import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// What the collector is still looking for, in the active game.
///
/// A wants list is the other half of a set: the collection screen answers what
/// is in the boxes, and this answers what is missing from them and what it
/// would cost to close the gap. It is scoped to one game for the same reason
/// the collection is - a Magic want and a Lorcana want are not comparable and
/// are not bought with the same money.
class WantsScreen extends ConsumerWidget {
  /// Creates the screen for one game.
  const WantsScreen({super.key, required this.game});

  /// The game whose wants are shown. Passed in rather than read from the
  /// active game so the screen keeps describing the collection it was opened
  /// from if the switcher is changed underneath it.
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final async = ref.watch(wantedCardsProvider(game));
    final cards = async.value ?? const <TcgCard>[];
    final cost = _toBeBought(cards);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: c.accent),
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
                      Text('Wants', style: context.t.headlineMedium),
                      Text(
                        cards.isEmpty
                            ? game.shortLabel
                            : '${game.shortLabel}  ·  '
                                  '${Fmt.count(cards.length)} cards  ·  '
                                  '${Fmt.moneyAdaptive(cost)} to buy',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                  actions: [
                    if (cards.isNotEmpty)
                      IconButton(
                        tooltip: 'Empty the wants list',
                        icon: const Icon(Icons.delete_sweep_outlined),
                        onPressed: () => _confirmClear(context, ref),
                      ),
                  ],
                ),
              ),
              SliverAsyncView<List<TcgCard>>(
                value: async,
                loadingHeight: 320,
                isEmpty: (list) => list.isEmpty,
                emptyIcon: Icons.bookmark_border_rounded,
                emptyTitle: 'Nothing wanted yet',
                emptyMessage:
                    'Open a card and press the bookmark to put it here. Wants '
                    'are kept per game, and are never mixed into your '
                    'collection.',
                onRetry: () => ref.invalidate(wantedIdsProvider(game)),
                builder: (list) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  sliver: SliverList.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) =>
                        _WantRow(card: list[i], game: game),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// What the whole list would cost, priced at the cheapest finish of each.
  ///
  /// A want names a card, not a finish, so the honest price is the cheapest one
  /// quoted: pricing a want at the foil would overstate the bill for a card the
  /// collector would happily buy plain. A card that nothing quotes adds nothing,
  /// so the total is a floor rather than a guess, and it is labelled as one.
  static double _toBeBought(List<TcgCard> cards) {
    var total = 0.0;
    for (final card in cards) {
      total += card.prices.from ?? 0;
    }
    return total;
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Empty the wants list?'),
        content: Text(
          'Every want for ${game.shortLabel} is removed. Your collection is '
          'not touched.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Empty it'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(wantedDaoProvider).clear(game);
    ref.read(wantedRevisionProvider.notifier).bump();
  }
}

/// One wanted printing: what it is, where it is from, and what it costs.
class _WantRow extends ConsumerWidget {
  const _WantRow({required this.card, required this.game});

  final TcgCard card;
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final price = card.prices.from;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: game, cardId: card.id),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: CardThumbnail(
                imageUrl: card.imageUrl(size: 'small'),
                aspectRatio: game.cardAspectRatio,
                width: 46,
                rarity: CardRarity.fromCode(card.rarity),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${card.setCode.toUpperCase()} #${card.collectorNumber}',
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
                  Fmt.moneyAdaptive(price),
                  style: context.t.titleSmall?.copyWith(
                    color: price == null ? c.textTertiary : c.gold,
                  ),
                ),
                Text(
                  'cheapest',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ),
            IconButton(
              tooltip: 'I have this now',
              iconSize: 20,
              icon: Icon(Icons.check_circle_outline_rounded, color: c.positive),
              onPressed: () async {
                await ref.read(wantedDaoProvider).remove(game, card.id);
                ref.read(wantedRevisionProvider.notifier).bump();
              },
            ),
          ],
        ),
      ),
    );
  }
}
