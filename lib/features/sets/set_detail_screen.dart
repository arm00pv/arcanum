import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/sets/sets_screen.dart' show SetGlyph;
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';
import 'package:arcanum/widgets/mana_pips.dart';

/// Shows every card in a set, in binder order.
///
/// Ordering is by collector number, matching how the cards are physically
/// collated — which is what a collector expects when working through a set. The
/// ordering logic is shared across games, so it handles Magic's `1a` suffixes
/// and Pokémon's `TG01`/`SV001` prefixes alike.
class SetDetailScreen extends ConsumerStatefulWidget {
  const SetDetailScreen({super.key, required this.game, required this.setCode});

  /// The game this set belongs to.
  final CardGame game;

  /// The set's code (Magic) or set id (Pokémon).
  final String setCode;

  @override
  ConsumerState<SetDetailScreen> createState() => _SetDetailScreenState();
}

class _SetDetailScreenState extends ConsumerState<SetDetailScreen> {
  final _scrollController = ScrollController();
  double _scrollOffset = 0;
  bool _grid = true;
  bool _ownedOnly = false;

  SetRef get _ref => (game: widget.game, code: widget.setCode);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = widget.game;
    final setAsync = ref.watch(setProvider(_ref));
    final cardsAsync = ref.watch(setCardsProvider(_ref));
    final owned = ref.watch(ownedQuantityProvider(game)).value ?? const <String, int>{};
    final set = setAsync.value;

    final ownedInSet =
        cardsAsync.value?.where((x) => (owned[x.id] ?? 0) > 0).length ?? 0;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration:
                  BoxDecoration(gradient: AppTheme.backdrop(c, tint: game.accent)),
            ),
          ),
          RefreshIndicator(
            color: game.accent,
            backgroundColor: c.surface,
            onRefresh: () async {
              await ref
                  .read(catalogRepositoryProvider)
                  .cardsInSet(game, widget.setCode, forceRefresh: true);
              ref.invalidate(setCardsProvider(_ref));
            },
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: GlassAppBar(
                    scrollOffset: _scrollOffset,
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          set?.name ?? widget.setCode.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.titleLarge,
                        ),
                        Text(
                          [
                            if (set != null) Fmt.date(set.releasedAt),
                            if (set?.series != null) set!.series!,
                            '${cardsAsync.value?.length ?? set?.cardCount ?? 0} cards',
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodySmall,
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: _grid ? 'List view' : 'Grid view',
                        onPressed: () => setState(() => _grid = !_grid),
                        icon: Icon(
                          _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                        ),
                      ),
                    ],
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(52),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: Row(
                          children: [
                            if (set != null)
                              SizedBox(
                                width: 30,
                                height: 30,
                                child: Center(child: SetGlyph(set: set, size: 26)),
                              ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: PillToggle(
                                options: ['All cards', 'Owned ($ownedInSet)'],
                                selected: _ownedOnly ? 1 : 0,
                                onChanged: (i) => setState(() => _ownedOnly = i == 1),
                                height: 34,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SliverAsyncView<List<TcgCard>>(
                  value: cardsAsync,
                  loadingHeight: 420,
                  onRetry: () => ref.invalidate(setCardsProvider(_ref)),
                  isEmpty: (cards) => cards.isEmpty,
                  emptyTitle: 'No cards cached',
                  emptyMessage: 'Pull down to download this set from ${game.dataSource}.',
                  builder: (cards) {
                    final visible = _ownedOnly
                        ? cards.where((x) => (owned[x.id] ?? 0) > 0).toList()
                        : cards;
                    if (visible.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 80),
                          child: EmptyState(
                            icon: Icons.inbox_rounded,
                            title: 'Nothing owned here yet',
                            message: 'You have not added any cards from this set.',
                          ),
                        ),
                      );
                    }
                    return _grid
                        ? SliverPadding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 120),
                            sliver: SliverGrid.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 10,
                                childAspectRatio: 0.52,
                              ),
                              itemCount: visible.length,
                              itemBuilder: (context, i) => _CardGridTile(
                                card: visible[i],
                                owned: owned[visible[i].id] ?? 0,
                                index: i,
                              ),
                            ),
                          )
                        : SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
                            sliver: SliverList.builder(
                              itemCount: visible.length,
                              itemBuilder: (context, i) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _CardListTile(
                                  card: visible[i],
                                  owned: owned[visible[i].id] ?? 0,
                                  index: i,
                                ),
                              ),
                            ),
                          );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A card as a poster: art forward, with the collector number always visible.
class _CardGridTile extends StatelessWidget {
  const _CardGridTile({required this.card, required this.owned, required this.index});

  final TcgCard card;
  final int owned;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final price = card.prices.from;

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: card.game, cardId: card.id),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CardThumbnail(
              imageUrl: card.imageUrl(size: 'normal'),
              heroTag: 'card-${card.id}',
              rarity: rarity,
              quantity: owned > 0 ? owned.toDouble() : null,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: c.hairline),
                ),
                child: Text(
                  '#${card.collectorNumber}',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
              const Spacer(),
              if (price != null)
                Text(
                  Fmt.moneyAdaptive(price),
                  style: context.t.labelMedium?.copyWith(color: c.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            card.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodySmall?.copyWith(color: c.textPrimary),
          ),
        ],
      ),
    )
        .animate()
        .fadeIn(duration: 200.ms, delay: (index.clamp(0, 18) * 18).ms)
        .scale(begin: const Offset(0.96, 0.96), end: const Offset(1, 1));
  }
}

/// A card as a row: dense, price-forward, with the game's own identifying marks.
class _CardListTile extends StatelessWidget {
  const _CardListTile({required this.card, required this.owned, required this.index});

  final TcgCard card;
  final int owned;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final premium = card.game.finishes
        .where((f) => f.isPremium && (card.prices.priceFor(f) ?? 0) > 0)
        .toList();

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: card.game, cardId: card.id),
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
                width: 46,
                rarity: rarity,
                quantity: owned > 0 ? owned.toDouble() : null,
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
                  Row(
                    children: [
                      Text(
                        '#${card.collectorNumber}',
                        style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                      ),
                      const SizedBox(width: 6),
                      RarityBadge(rarity: rarity, compact: true),
                      const SizedBox(width: 6),
                      // Magic identifies cards by mana cost, Pokémon by energy
                      // type — showing the wrong one would be nonsense.
                      if (card.game == CardGame.mtg && card.manaCost != null)
                        ManaCostRow(cost: card.manaCost, size: 13)
                      else
                        ManaPips(
                          symbols: card.colors.isEmpty
                              ? const []
                              : [card.game.bucketFor(card.colors.first).symbol],
                          size: 13,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(Fmt.money(card.prices.from), style: context.t.titleSmall),
                if (premium.isNotEmpty)
                  Text(
                    '${premium.first.shortLabel} '
                    '${Fmt.money(card.prices.priceFor(premium.first))}',
                    style: context.t.labelSmall?.copyWith(color: c.gold),
                  ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 180.ms, delay: (index.clamp(0, 14) * 16).ms);
  }
}
