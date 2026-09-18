import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/codes.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/collection/binders_screen.dart';
import 'package:arcanum/features/collection/purchases_screen.dart';
import 'package:arcanum/features/collection/trade_screen.dart';
import 'package:arcanum/features/collection/wants_screen.dart';
import 'package:arcanum/features/scan/scan_screen.dart';
import 'package:arcanum/features/sealed/sealed_screen.dart';
import 'package:arcanum/features/transfer/paste_import_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// How the collection list is ordered.
enum _CollectionSort { value, name, recent, quantity, change }

/// Everything the user owns in the active game, valued against live prices.
///
/// The screen is scoped end to end to [activeGameProvider]: the overview, the
/// card data behind every row and the header line all describe one game's
/// collection, never a blend of two.
class CollectionScreen extends ConsumerStatefulWidget {
  const CollectionScreen({super.key});

  @override
  ConsumerState<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends ConsumerState<CollectionScreen> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  double _scrollOffset = 0;
  String _query = '';
  _CollectionSort _sort = _CollectionSort.value;
  bool _listMode = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
  }

  /// Opens one of the other views of the collection.
  void _open(BuildContext context, String choice) {
    final Widget screen = switch (choice) {
      'purchases' => const PurchasesScreen(),
      'binders' => const BindersScreen(),
      'paste' => const PasteImportScreen(),
      'scan' => const ScanScreen(),
      'sealed' => const SealedScreen(),
      _ => const TradeScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final overviewAsync = ref.watch(collectionOverviewProvider(game));
    final cards =
        ref.watch(ownedCardsProvider(game)).value ?? const <String, TcgCard>{};
    final overview = overviewAsync.value;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: c.positive),
              ),
            ),
          ),
          RefreshIndicator(
            color: c.accent,
            backgroundColor: c.surface,
            onRefresh: () async {
              ref.invalidate(collectionOverviewProvider(game));
              ref.invalidate(ownedCardsProvider(game));
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
                        Text('Collection', style: context.t.headlineMedium),
                        if (overview != null)
                          Text(
                            // The game comes first: with two collections in one
                            // app it must be obvious which one is on screen.
                            '${game.shortLabel}  ·  '
                            '${Fmt.countOf(overview.totalCards, 'card')}  ·  '
                            '${Fmt.count(overview.uniqueCards)} unique  ·  '
                            '${Fmt.moneyCompact(overview.totalValue)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.bodySmall,
                          ),
                      ],
                    ),
                    actions: [
                      // Counted rather than assumed: an empty bookmark is a
                      // dead end, and a number is the only reason to open it.
                      IconButton(
                        tooltip: 'Wants',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => WantsScreen(game: game),
                          ),
                        ),
                        icon: Badge(
                          isLabelVisible:
                              (ref.watch(wantedCountProvider(game)).value ??
                                  0) >
                              0,
                          label: Text(
                            '${ref.watch(wantedCountProvider(game)).value ?? 0}',
                          ),
                          child: const Icon(Icons.bookmark_border_rounded),
                        ),
                      ),
                      IconButton(
                        tooltip: _listMode ? 'Grid view' : 'List view',
                        onPressed: () => setState(() => _listMode = !_listMode),
                        icon: Icon(
                          _listMode
                              ? Icons.grid_view_rounded
                              : Icons.view_list_rounded,
                        ),
                      ),
                      // The collection seen three other ways: by what it cost,
                      // by where it is filed, and by what is up for trade.
                      PopupMenuButton<String>(
                        onSelected: (String choice) => _open(context, choice),
                        itemBuilder: (BuildContext context) =>
                            const <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                value: 'purchases',
                                child: Text('Purchases'),
                              ),
                              PopupMenuItem<String>(
                                value: 'binders',
                                child: Text('Binders'),
                              ),
                              PopupMenuItem<String>(
                                value: 'trade',
                                child: Text('For trade'),
                              ),
                              PopupMenuItem<String>(
                                value: 'paste',
                                child: Text('Paste a list'),
                              ),
                              PopupMenuItem<String>(
                                value: 'scan',
                                child: Text('Scan a card'),
                              ),
                              PopupMenuItem<String>(
                                value: 'sealed',
                                child: Text('Sealed product'),
                              ),
                            ],
                      ),
                    ],
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Filter your ${game.shortLabel} collection',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: PillToggle(
                      options: const ['Value', 'Recent', 'Qty', 'Change'],
                      selected: _sortPillIndex,
                      onChanged: (i) => setState(() => _sort = _pillSorts[i]),
                    ),
                  ),
                ),
                SliverAsyncView<CollectionOverview>(
                  value: overviewAsync,
                  loadingHeight: 320,
                  onRetry: () =>
                      ref.invalidate(collectionOverviewProvider(game)),
                  isEmpty: (o) => o.entries.isEmpty,
                  emptyTitle: 'Nothing in your ${game.shortLabel} collection',
                  emptyMessage:
                      'Your ${game.shortLabel} collection is empty. Browse a set or '
                      'search for a card to add your first copy to your '
                      '${game.collectionNoun}.',
                  builder: (o) {
                    final rows = _applySort(_filter(o.entries, cards));
                    if (rows.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 60),
                          child: EmptyState(
                            icon: Icons.search_off_rounded,
                            title: 'Nothing matches',
                            message: 'Try a different filter.',
                          ),
                        ),
                      );
                    }
                    return _listMode
                        ? SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                            sliver: SliverList.builder(
                              itemCount: rows.length,
                              itemBuilder: (context, i) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _EntryRow(
                                  valued: rows[i],
                                  card: cards[rows[i].entry.cardId],
                                  game: game,
                                  index: i,
                                ),
                              ),
                            ),
                          )
                        : SliverPadding(
                            padding: const EdgeInsets.fromLTRB(14, 8, 14, 120),
                            sliver: SliverGrid.builder(
                              // Bounded by the card, not by a count, so a
                              // desktop window shows the collection rather than
                              // three cards the size of a plate.
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 190,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 0.5,
                                  ),
                              itemCount: rows.length,
                              itemBuilder: (context, i) => _EntryGridTile(
                                valued: rows[i],
                                card: cards[rows[i].entry.cardId],
                                game: game,
                                index: i,
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

  static const _pillSorts = <_CollectionSort>[
    _CollectionSort.value,
    _CollectionSort.recent,
    _CollectionSort.quantity,
    _CollectionSort.change,
  ];

  int get _sortPillIndex {
    final i = _pillSorts.indexOf(_sort);
    return i < 0 ? 0 : i;
  }

  List<ValuedEntry> _filter(
    List<ValuedEntry> entries,
    Map<String, TcgCard> cards,
  ) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return entries;
    // The code as printed too: a card filed under "ST23" answers to "ST-23".
    final folded = Codes.fold(_query);
    return entries.where((v) {
      final card = cards[v.entry.cardId];
      if (card == null) return false;
      return card.name.toLowerCase().contains(q) ||
          card.setName.toLowerCase().contains(q) ||
          card.setCode.toLowerCase().contains(q) ||
          Codes.matches(card.setCode, folded) ||
          v.entry.binder.toLowerCase().contains(q);
    }).toList();
  }

  List<ValuedEntry> _applySort(List<ValuedEntry> entries) {
    final out = List<ValuedEntry>.from(entries);
    switch (_sort) {
      case _CollectionSort.value:
        out.sort((a, b) => (b.totalValue ?? 0).compareTo(a.totalValue ?? 0));
      case _CollectionSort.name:
        out.sort((a, b) => a.entry.cardId.compareTo(b.entry.cardId));
      case _CollectionSort.recent:
        out.sort((a, b) => b.entry.updatedAt.compareTo(a.entry.updatedAt));
      case _CollectionSort.quantity:
        out.sort((a, b) => b.entry.quantity.compareTo(a.entry.quantity));
      case _CollectionSort.change:
        out.sort(
          (a, b) => (b.dayChangePercent ?? 0).abs().compareTo(
            (a.dayChangePercent ?? 0).abs(),
          ),
        );
    }
    return out;
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.valued,
    required this.card,
    required this.game,
    required this.index,
  });

  final ValuedEntry valued;
  final TcgCard? card;

  /// The game this entry belongs to: card lookups and analytics are per game.
  final CardGame game;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final e = valued.entry;
    final rarity = CardRarity.fromCode(card?.rarity);

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
              width: 46,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 46,
                rarity: rarity,
                quantity: e.quantity.toDouble(),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? 'Unknown printing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        card == null
                            ? '--'
                            : '${card!.setCode.toUpperCase()} #${card!.collectorNumber}',
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                      // Any finish the game actually prints is worth a badge:
                      // Magic's foils and etched, Pokémon's holos, reverse holos
                      // and 1st editions. A non-foil needs none.
                      if (e.finish != CardFinish.nonfoil) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: c.gold.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            e.finish.shortLabel,
                            maxLines: 1,
                            style: context.t.labelSmall?.copyWith(
                              color: c.gold,
                            ),
                          ),
                        ),
                      ],
                      if (e.condition != CardCondition.nearMint) ...[
                        const SizedBox(width: 4),
                        Text(
                          e.condition.short,
                          style: context.t.labelSmall?.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                      if (e.binder.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            e.binder,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.labelSmall?.copyWith(
                              color: c.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  valued.totalValue == null
                      ? '--'
                      : Fmt.money(valued.totalValue),
                  style: context.t.titleSmall,
                ),
                const SizedBox(height: 2),
                if (valued.unitValue != null)
                  Text(
                    '${e.quantity} x ${Fmt.moneyAdaptive(valued.unitValue)}',
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                if (valued.profit != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      Fmt.moneySigned(valued.profit),
                      style: context.t.labelSmall?.copyWith(
                        color: c.forDelta(valued.profit!),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 180.ms, delay: (index.clamp(0, 14) * 16).ms);
  }
}

class _EntryGridTile extends StatelessWidget {
  const _EntryGridTile({
    required this.valued,
    required this.card,
    required this.game,
    required this.index,
  });

  final ValuedEntry valued;
  final TcgCard? card;
  final CardGame game;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GestureDetector(
      onTap: card == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CardDetailScreen(game: game, cardId: card!.id),
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) =>
                  CardThumbnail(
                    imageUrl: card?.imageUrl(
                      size: CardThumbnail.renditionFor(
                        width: box.maxWidth,
                        devicePixelRatio: MediaQuery.devicePixelRatioOf(
                          context,
                        ),
                      ),
                    ),
                    rarity: CardRarity.fromCode(card?.rarity),
                    quantity: valued.entry.quantity.toDouble(),
                    borderRadius: BorderRadius.circular(10),
                  ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            card?.name ?? '--',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodySmall?.copyWith(color: c.textPrimary),
          ),
          Text(
            valued.totalValue == null
                ? '--'
                : Fmt.moneyAdaptive(valued.totalValue),
            style: context.t.labelMedium?.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 200.ms, delay: (index.clamp(0, 18) * 18).ms);
  }
}
