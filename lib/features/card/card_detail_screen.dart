import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/price_alert.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/quant/quant.dart';
import 'package:arcanum/features/alerts/alerts_screen.dart'
    show showSetAlertSheet;
import 'package:arcanum/features/card/add_to_collection_sheet.dart';
import 'package:arcanum/features/collection/sale_sheet.dart';
import 'package:arcanum/features/card/owned_finishes.dart';
import 'package:arcanum/features/card/price_chart.dart';
import 'package:arcanum/features/collection/want_button.dart';
import 'package:arcanum/features/decks/add_to_deck_sheet.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/mana_pips.dart';
import 'package:arcanum/widgets/sample_art_note.dart';
import 'package:arcanum/widgets/trend_gauge.dart';

/// The full detail view for one printing: art, market prices, the user's own
/// copies, and the on-device price analytics.
class CardDetailScreen extends ConsumerStatefulWidget {
  const CardDetailScreen({super.key, required this.game, required this.cardId});

  /// The game this printing belongs to.
  final CardGame game;

  final String cardId;

  @override
  ConsumerState<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends ConsumerState<CardDetailScreen> {
  final _scrollController = ScrollController();
  double _scrollOffset = 0;
  CardFinish? _finish;

  CardRef get _cardRef => (game: widget.game, id: widget.cardId);

  /// The finish being valued. Defaults to the game's primary finish.
  CardFinish get _effectiveFinish => _finish ?? widget.game.finishes.first;

  AnalyticsKey get _key =>
      (game: widget.game, cardId: widget.cardId, finish: _effectiveFinish);

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
    final cardAsync = ref.watch(cardProvider(_cardRef));
    final analyticsAsync = ref.watch(cardAnalyticsProvider(_key));
    final historyAsync = ref.watch(priceHistoryProvider(_key));
    final entriesAsync = ref.watch(cardEntriesProvider(_cardRef));

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
          AsyncValueView<TcgCard?>(
            value: cardAsync,
            loadingHeight: 500,
            onRetry: () => ref.invalidate(cardProvider(_cardRef)),
            isEmpty: (card) => card == null,
            emptyMessage: 'This printing could not be loaded.',
            builder: (card) {
              if (card == null) {
                return const EmptyState(
                  icon: Icons.help_outline_rounded,
                  title: 'Card not found',
                );
              }
              return CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: GlassAppBar(
                      scrollOffset: _scrollOffset,
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      title: Text(
                        card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleLarge,
                      ),
                      actions: [
                        _DeckButton(card: card),
                        WantButton(card: card),
                        IconButton(
                          tooltip: 'Set a price alert',
                          icon: const Icon(Icons.notifications_none_rounded),
                          onPressed: () => showSetAlertSheet(
                            context,
                            ref,
                            card,
                            initialFinish: _effectiveFinish,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Add to collection',
                          icon: const Icon(Icons.add_circle_outline_rounded),
                          onPressed: () => showAddToCollectionSheet(
                            context,
                            ref,
                            card,
                            initialFinish: _effectiveFinish,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SliverToBoxAdapter(child: _Hero(card: card)),
                  if (SampleArtNote.applies(<TcgCard>[card]))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                        child: SampleArtNote(game: card.game),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 120),
                    sliver: SliverList.list(
                      children: [
                        _Header(card: card),
                        const SizedBox(height: 18),
                        _OwnedSection(
                          entries: entriesAsync.value ?? const [],
                          card: card,
                          finish: _effectiveFinish,
                        ),
                        _AlertSummary(card: card),
                        const SizedBox(height: 18),
                        _MarketSection(
                          card: card,
                          finish: _effectiveFinish,
                          onFinishChanged: (f) => setState(() => _finish = f),
                        ),
                        const SizedBox(height: 18),
                        _AnalyticsSection(
                          analytics: analyticsAsync,
                          history: historyAsync,
                          game: game,
                          onRetry: () =>
                              ref.invalidate(cardAnalyticsProvider(_key)),
                        ),
                        const SizedBox(height: 18),
                        _CardTextSection(card: card),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The card art, large, with a soft glow matching its rarity.
class _Hero extends StatelessWidget {
  const _Hero({required this.card});

  final TcgCard card;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final url = card.imageUrl(size: 'large') ?? card.imageUrl(size: 'normal');

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: rarity.color.withValues(alpha: 0.35),
                  blurRadius: 42,
                  spreadRadius: -6,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: AspectRatio(
                aspectRatio: 488 / 680,
                child: url == null
                    ? const CardBackPlaceholder()
                    : Hero(
                        tag: 'card-${card.id}',
                        child: CachedNetworkImage(
                          imageUrl: url,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 220),
                          placeholder: (_, _) => ColoredBox(
                            color: c.surfaceRaised,
                            child: const Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          ),
                          errorWidget: (_, _, _) => const CardBackPlaceholder(),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 320.ms).slideY(begin: 0.06, end: 0);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.card});
  final TcgCard card;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final game = card.game;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(card.name, style: context.t.headlineMedium),
        if (card.faces.length > 1 && card.faces[1].name != null)
          Text('// ${card.faces[1].name}', style: context.t.bodySmall),
        const SizedBox(height: 8),
        Row(
          children: [
            // Magic shows a mana cost; Pokémon shows its energy types.
            if (game == CardGame.mtg && card.manaCost != null)
              ManaCostRow(cost: card.manaCost, size: 17)
            else if (game == CardGame.mtg)
              // Magic's pips are drawn from its own letters so they come out in
              // WUBRG order, and a card with no colour - a land, an artifact -
              // keeps its colourless pip rather than showing nothing.
              ManaPips(
                symbols: [
                  for (final t in card.colors) game.bucketFor(t).symbol,
                ],
                size: 17,
                showColorless: card.colors.isEmpty,
              )
            else
              // Every other game buckets by something that is not mana, so the
              // categories are handed over whole: a two-colour One Piece Leader
              // is two pips, and a Pokémon Trainer shows the catch-all bucket it
              // was counted in.
              ManaPips(
                buckets: game.bucketsOf(card.colors, includeCatchAll: true),
                size: 17,
              ),
            const SizedBox(width: 10),
            RarityBadge(rarity: rarity),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          card.typeLine ?? '',
          style: context.t.bodyMedium?.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Meta(
              label: card.setCode.toUpperCase(),
              icon: Icons.style_outlined,
            ),
            _Meta(label: '#${card.collectorNumber}', icon: Icons.tag_rounded),
            if (card.artist != null)
              _Meta(label: card.artist!, icon: Icons.brush_outlined),
            if (card.releasedAt != null)
              _Meta(
                label: Fmt.date(card.releasedAt),
                icon: Icons.event_outlined,
              ),
            if (card.reserved)
              const _Meta(label: 'Reserved List', icon: Icons.lock_outline),
            if (card.extras['pokedex'] != null)
              _Meta(
                label: 'Pokédex #${card.extras['pokedex']}',
                icon: Icons.catching_pokemon,
              ),
          ],
        ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c.textTertiary),
          const SizedBox(width: 5),
          Text(
            label,
            style: context.t.labelSmall?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// The user's own copies, with inline quantity control.
class _OwnedSection extends ConsumerWidget {
  const _OwnedSection({
    required this.entries,
    required this.card,
    required this.finish,
  });

  final List<CollectionEntry> entries;
  final TcgCard card;
  final CardFinish finish;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final game = card.game;

    if (entries.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.layers_outlined, color: c.textTertiary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Not in your ${game.shortLabel} collection yet',
                style: context.t.bodyMedium?.copyWith(color: c.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => showAddToCollectionSheet(
                context,
                ref,
                card,
                initialFinish: finish,
              ),
              child: const Text('Add'),
            ),
          ],
        ),
      );
    }

    final total = entries.fold<int>(0, (a, e) => a + e.quantity);

    // The same printing can be owned in several finishes at once, and the
    // quantity steppers below can only ever grow a stack that already exists.
    // Offering the finishes that are still missing is what makes "one foil and
    // one non-foil of the same card" reachable without a detour through the
    // price chips.
    final missing = missingFinishes(entries, game);

    Future<void> addFinish(CardFinish finish) =>
        showAddToCollectionSheet(context, ref, card, initialFinish: finish);

    Future<void> setQuantity(int id, int qty) async {
      await ref
          .read(bootstrapProvider)
          .collectionFor(game)
          .setQuantity(id, qty);
      ref.invalidate(collectionOverviewProvider(game));
      ref.invalidate(ownedQuantityProvider(game));
      ref.invalidate(gameSummariesProvider);
      ref.invalidate(cardEntriesProvider((game: game, id: card.id)));
    }

    /// Moves a stack on and off the trade pile.
    ///
    /// The overview is invalidated rather than patched, because the trade
    /// screen and the ledger both read it and neither should be the one place
    /// that has to remember to update itself.
    Future<void> setForTrade(int id, bool value) async {
      await ref
          .read(bootstrapProvider)
          .collectionFor(game)
          .setForTrade(id, value);
      ref.invalidate(collectionOverviewProvider(game));
      ref.invalidate(cardEntriesProvider((game: game, id: card.id)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'In your collection',
          subtitle:
              '$total ${total == 1 ? 'copy' : 'copies'} across ${entries.length} '
              '${entries.length == 1 ? 'entry' : 'entries'}',
          padding: EdgeInsets.zero,
          trailing: TextButton.icon(
            onPressed: () => addFinish(finish),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
          ),
        ),
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: GlassCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                e.finish.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.t.titleSmall,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              e.condition.label,
                              style: context.t.labelSmall?.copyWith(
                                color: c.textTertiary,
                              ),
                            ),
                          ],
                        ),
                        if (e.binder.isNotEmpty)
                          Text(
                            e.binder,
                            style: context.t.labelSmall?.copyWith(
                              color: c.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Record a sale from this stack',
                    onPressed: () => showSaleSheet(context, ref, card, e),
                    icon: const Icon(Icons.sell_outlined, size: 20),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: e.forTrade
                        ? 'Take off the trade pile'
                        : 'Put on the trade pile',
                    onPressed: () => setForTrade(e.id!, !e.forTrade),
                    icon: Icon(
                      e.forTrade
                          ? Icons.handshake_rounded
                          : Icons.handshake_outlined,
                      size: 20,
                      color: e.forTrade ? c.accent : c.textTertiary,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setQuantity(e.id!, e.quantity - 1),
                    icon: const Icon(
                      Icons.remove_circle_outline_rounded,
                      size: 20,
                    ),
                  ),
                  Text('${e.quantity}', style: context.t.titleMedium),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setQuantity(e.id!, e.quantity + 1),
                    icon: const Icon(
                      Icons.add_circle_outline_rounded,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Add another finish',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in missing)
                _AddFinishChip(
                  finish: f,
                  price: card.prices.priceFor(f),
                  onTap: () => addFinish(f),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A one-tap offer to add a finish of this printing the user does not hold yet.
///
/// It shows the market price for that finish so the choice is informed: a foil
/// copy of a bulk common and a foil copy of a mythic look identical in a list of
/// finish names, and only one of them is worth a trip to the binder.
class _AddFinishChip extends StatelessWidget {
  const _AddFinishChip({
    required this.finish,
    required this.price,
    required this.onTap,
  });

  final CardFinish finish;

  /// This finish's market price, or null when the provider quotes none.
  final double? price;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final p = price;
    return Material(
      color: c.surfaceRaised,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.accent.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 16, color: c.accent),
              const SizedBox(width: 6),
              Text(
                finish.label,
                style: context.t.labelLarge?.copyWith(color: c.accent),
              ),
              if (p != null && p > 0) ...[
                const SizedBox(width: 6),
                Text(
                  Fmt.money(p),
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Market prices, per finish the game actually has.
class _MarketSection extends StatelessWidget {
  const _MarketSection({
    required this.card,
    required this.finish,
    required this.onFinishChanged,
  });

  final TcgCard card;
  final CardFinish finish;
  final ValueChanged<CardFinish> onFinishChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = card.game;

    // Only offer finishes this game physically has, and prefer the ones the
    // provider actually quoted.
    final quoted = card.prices.quotedFinishes;
    final choices = quoted.isNotEmpty ? quoted : game.finishes;
    final selected = choices.contains(finish) ? finish : choices.first;
    final selectedPrice = card.prices.priceFor(selected) ?? card.prices.from;

    final rows = <(String, double?)>[
      for (final f in choices) (f.label, card.prices.priceFor(f)),
      ('Cardmarket (EUR)', card.prices.eur),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Market prices',
          subtitle: 'Updated daily by ${game.dataSource}',
          padding: EdgeInsets.zero,
        ),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(selected.label, style: context.t.bodySmall),
              const SizedBox(height: 2),
              Text(Fmt.money(selectedPrice), style: context.t.displaySmall),
              const SizedBox(height: 14),
              // Games have different numbers of finishes (Magic 3, Pokémon up
              // to 5), so this is a wrapping chip row rather than a fixed
              // segmented control.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in choices)
                    _FinishChip(
                      label: f.shortLabel,
                      price: card.prices.priceFor(f),
                      selected: f == selected,
                      onTap: () => onFinishChanged(f),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Divider(color: c.hairline, height: 1),
              const SizedBox(height: 10),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          r.$1,
                          style: context.t.bodySmall?.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                      Text(
                        r.$2 == null ? '--' : Fmt.money(r.$2),
                        style: context.t.bodyMedium,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FinishChip extends StatelessWidget {
  const _FinishChip({
    required this.label,
    required this.price,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final double? price;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accent.withValues(alpha: 0.22) : c.surfaceRaised,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected ? c.accent.withValues(alpha: 0.65) : c.hairline,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.t.labelMedium?.copyWith(
                  color: selected ? c.accent : c.textPrimary,
                ),
              ),
              if (price != null)
                Text(
                  Fmt.moneyAdaptive(price),
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quantitative panel: score, forecast, chart and indicator readings.
class _AnalyticsSection extends StatelessWidget {
  const _AnalyticsSection({
    required this.analytics,
    required this.history,
    required this.game,
    required this.onRetry,
  });

  final AsyncValue<CardAnalytics> analytics;
  final AsyncValue<List<PricePoint>> history;
  final CardGame game;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Price analysis',
          subtitle: analytics.value == null
              ? 'Computed on this device'
              : '${analytics.value!.effectiveSamples} observations over '
                    '${analytics.value!.windowDays} days',
          padding: EdgeInsets.zero,
          trailing: IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            onPressed: onRetry,
          ),
        ),
        AsyncValueView<CardAnalytics>(
          value: analytics,
          onRetry: onRetry,
          loadingHeight: 260,
          builder: (a) {
            if (a.series.length < 20) {
              return GlassCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  children: [
                    Icon(
                      Icons.hourglass_empty_rounded,
                      color: c.textTertiary,
                      size: 28,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Building price history',
                      style: context.t.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // Each game has a different answer to "where is my
                      // history?", and most of them have nowhere to backfill
                      // from, so the sentence follows the game.
                      switch (game) {
                        CardGame.mtg =>
                          'Arcanum records a price snapshot every day you open '
                              'the app. Trend analysis needs at least a couple of '
                              'weeks of data — connect a history provider in '
                              'Settings to backfill immediately.',
                        CardGame.pokemon =>
                          'Arcanum records a Pokémon price snapshot every day you '
                              'open the app, and the free TCGdex archive supplies '
                              'history up to September 2024. Trend analysis needs '
                              'about three weeks of data — a JustTCG key in Settings '
                              'adds live history immediately.',
                        CardGame.yugioh =>
                          'YGOPRODeck keeps no price history at all, so this '
                              'game has one source and it is yours: the Arcanum '
                              'Sync companion records every Yu-Gi-Oh! printing '
                              'once a day, and the app snapshots the cards you '
                              'own. Analysis begins after a couple of weeks.',
                        CardGame.lorcana =>
                          'Lorcast publishes only current prices, so this game '
                              'has one source and it is yours: the Arcanum Sync '
                              'companion records every Lorcana card once a day, '
                              'and the app snapshots the cards you own. Analysis '
                              'begins after a couple of weeks.',
                        // The three games TCGplayer catalogs are republished
                        // once a day as a price file with no history in it at
                        // all, so they are in Lorcana's position - except that
                        // the companion does not sample them yet, and saying it
                        // did would promise a backfill that never arrives.
                        CardGame.onePiece ||
                        CardGame.starWarsUnlimited ||
                        CardGame.digimon ||
                        CardGame.dragonBall ||
                        CardGame.gundam =>
                          'TCGplayer publishes current prices only: the file '
                              'Arcanum reads is rewritten once a day and keeps '
                              'no history at all. So this game has one source, '
                              'and it is yours - the app records a snapshot of '
                              'the cards you own every day you open it. '
                              'Analysis begins after a couple of weeks.',
                      },
                      textAlign: TextAlign.center,
                      style: context.t.bodySmall,
                    ),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GlassCard(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      TrendGauge(
                        score: a.trendScore,
                        label: a.headline,
                        confidence: a.confidence,
                        size: 172,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        a.summary,
                        textAlign: TextAlign.center,
                        style: context.t.bodySmall?.copyWith(height: 1.45),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _Metric(
                            label: '30-day',
                            value: Fmt.percent(a.momentum30),
                            delta: a.momentum30,
                          ),
                          _Metric(
                            label: '90-day',
                            value: Fmt.percent(a.momentum90),
                            delta: a.momentum90,
                          ),
                          _Metric(
                            label: 'Volatility',
                            value: Fmt.percentPlain(a.volatilityAnnualized),
                          ),
                          _Metric(
                            label: 'Max drop',
                            value: a.maxDrawdown == null
                                ? '--'
                                : Fmt.percentPlain(a.maxDrawdown),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                GlassCard(
                  padding: const EdgeInsets.fromLTRB(8, 18, 18, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          children: [
                            Text('Price history', style: context.t.titleSmall),
                            const Spacer(),
                            if (a.forecast != null)
                              Row(
                                children: [
                                  Container(
                                    width: 14,
                                    height: 2,
                                    color: c.accent,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    '${a.forecast!.point.length}-day range',
                                    style: context.t.labelSmall?.copyWith(
                                      color: c.textTertiary,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      history.when(
                        data: (points) =>
                            PriceChart(series: points, forecast: a.forecast),
                        loading: () => const SizedBox(
                          height: 220,
                          child: Center(child: LoadingShimmer(height: 200)),
                        ),
                        error: (e, _) => SizedBox(
                          height: 220,
                          child: Center(
                            child: Text('$e', style: context.t.bodySmall),
                          ),
                        ),
                      ),
                      if (a.forecast != null && a.forecast!.point.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 12, top: 4),
                          child: Text(
                            'Dashed line: 30-day statistical range '
                            '(${Fmt.money(a.forecast!.lower80.last)} – '
                            '${Fmt.money(a.forecast!.upper80.last)}). '
                            'A range, not a prediction.',
                            style: context.t.labelSmall?.copyWith(
                              color: c.textTertiary,
                              height: 1.4,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (a.anomalies.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  GlassCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 16,
                              color: c.warning,
                            ),
                            const SizedBox(width: 6),
                            Text('Unusual moves', style: context.t.titleSmall),
                          ],
                        ),
                        const SizedBox(height: 8),
                        for (final an in a.anomalies.take(4))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Icon(
                                  an.kind == 'crash'
                                      ? Icons.trending_down_rounded
                                      : an.kind == 'spike'
                                      ? Icons.trending_up_rounded
                                      : Icons.timeline_rounded,
                                  size: 14,
                                  color: an.kind == 'crash'
                                      ? c.negative
                                      : c.warning,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    an.description,
                                    style: context.t.bodySmall,
                                  ),
                                ),
                                Text(
                                  Fmt.dateShort(an.date),
                                  style: context.t.labelSmall?.copyWith(
                                    color: c.textTertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Indicators', style: context.t.titleSmall),
                      const SizedBox(height: 10),
                      for (final r in a.readings) _ReadingRow(reading: r),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.delta});

  final String label;
  final String value;
  final double? delta;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        Text(
          label,
          style: context.t.labelSmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: context.t.titleSmall?.copyWith(
            color: delta == null ? c.textPrimary : c.forDelta(delta!),
          ),
        ),
      ],
    );
  }
}

class _ReadingRow extends StatelessWidget {
  const _ReadingRow({required this.reading});
  final IndicatorReading reading;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final signal = reading.signal;
    final color = signal == null
        ? c.textTertiary
        : signal > 0.15
        ? c.positive
        : signal < -0.15
        ? c.negative
        : c.textTertiary;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              reading.label,
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              reading.value,
              textAlign: TextAlign.right,
              style: context.t.bodyMedium,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              reading.interpretation ?? '',
              textAlign: TextAlign.right,
              style: context.t.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The standing alerts on this printing, if any.
///
/// Shown inline rather than hidden behind the bell so a user does not arm the
/// same rule twice.
class _AlertSummary extends ConsumerWidget {
  const _AlertSummary({required this.card});

  final TcgCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final alerts =
        ref.watch(cardAlertsProvider((game: card.game, id: card.id))).value ??
        const <PriceAlert>[];
    if (alerts.isEmpty) return const SizedBox.shrink();

    final fired = alerts.where((a) => !a.isArmed).length;

    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Alerts',
            subtitle: fired > 0
                ? '$fired of ${alerts.length} have fired'
                : '${alerts.length} watching this printing',
            padding: EdgeInsets.zero,
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              children: [
                for (final a in alerts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          a.isArmed
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_rounded,
                          size: 16,
                          color: a.isArmed ? c.textTertiary : c.warning,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${a.effectiveFinish.shortLabel} · ${a.describe()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.bodySmall,
                          ),
                        ),
                        Text(
                          a.isArmed ? 'watching' : 'fired',
                          style: context.t.labelSmall?.copyWith(
                            color: a.isArmed ? c.textTertiary : c.warning,
                          ),
                        ),
                      ],
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

/// Rules text, presented per game.
class _CardTextSection extends StatelessWidget {
  const _CardTextSection({required this.card});
  final TcgCard card;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final hasFaces = card.faces.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: card.game == CardGame.mtg
              ? 'Card text'
              : 'Attacks & abilities',
          padding: EdgeInsets.zero,
        ),
        GlassCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasFaces)
                for (var i = 0; i < card.faces.length; i++) ...[
                  if (i > 0) ...[
                    const SizedBox(height: 12),
                    Divider(color: c.hairline, height: 1),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    card.faces[i].name ?? card.name,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    card.faces[i].typeLine ?? '',
                    style: context.t.bodySmall?.copyWith(
                      color: c.textSecondary,
                    ),
                  ),
                  if (card.faces[i].text != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      card.faces[i].text!,
                      style: context.t.bodyMedium?.copyWith(height: 1.45),
                    ),
                  ],
                ]
              else ...[
                if (card.oracleText != null)
                  Text(
                    card.oracleText!,
                    style: context.t.bodyMedium?.copyWith(height: 1.45),
                  ),
                if (card.flavorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    card.flavorText!,
                    style: context.t.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: c.textTertiary,
                      height: 1.45,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The button that puts a printing into one of the game's decks.
///
/// The count is shown because a card in three decks is a card the collector
/// may not want to also trade away, and because a button that looks unused on
/// a card already in two decks is a button that lies.
class _DeckButton extends ConsumerWidget {
  const _DeckButton({required this.card});

  final TcgCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count =
        ref
            .watch(cardDeckCountProvider((game: card.game, id: card.id)))
            .value ??
        0;

    return IconButton(
      tooltip: count == 0 ? 'Add to a deck' : 'In $count decks',
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.style_outlined),
      ),
      onPressed: () => showAddToDeckSheet(context, ref, card),
    );
  }
}
