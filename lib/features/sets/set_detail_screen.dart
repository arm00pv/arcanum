import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/sealed/box_ev_screen.dart';
import 'package:arcanum/features/sets/printing_groups.dart';
import 'package:arcanum/features/sets/set_completion_strip.dart';
import 'package:arcanum/features/sets/set_filter_sheet.dart';
import 'package:arcanum/features/sets/set_filters.dart';
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

  /// What the collector has narrowed the set to. Price and rarity only: what is
  /// owned is the pill in the header, which is a different question and stays
  /// where a collector already reaches for it.
  SetFilter _filter = const SetFilter();

  SetRef get _ref => (game: widget.game, code: widget.setCode);

  /// Opens the filter sheet over the set's binder slots.
  ///
  /// The sheet is handed every slot, not the ones currently on show: the counts
  /// beside each option describe the set, and a sheet that counted only what the
  /// last filter left could never be used to widen it again.
  Future<void> _openFilters(List<PrintingSlot> slots) async {
    final chosen = await showSetFilterSheet(
      context,
      current: _filter,
      slots: slots,
    );
    if (chosen == null || !mounted) return;
    setState(() => _filter = chosen);
  }

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

  /// How much the set holds, in the terms that actually matter.
  ///
  /// A set's printing count and its binder-slot count differ wherever the
  /// provider lists one card several times, which is most Yu-Gi-Oh! sets. The
  /// grid shows slots, so a header quoting only printings would look like a
  /// miscount; quoting both says why the two numbers disagree.
  static String _holdingsLabel(List<TcgCard> cards) {
    final slots = groupIntoSlots(cards).length;
    if (slots == cards.length) return Fmt.countOf(cards.length, 'printing');
    return '${Fmt.countOf(slots, 'card')} · '
        '${Fmt.countOf(cards.length, 'printing')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = widget.game;
    final setAsync = ref.watch(setProvider(_ref));
    final cardsAsync = ref.watch(setCardsProvider(_ref));
    final owned =
        ref.watch(ownedQuantityProvider(game)).value ?? const <String, int>{};
    final set = setAsync.value;

    // Counted in binder slots, matching what the grid shows and what the
    // "Owned" filter selects.
    final ownedInSet = cardsAsync.value == null
        ? 0
        : groupIntoSlots(cardsAsync.value!)
              .where((slot) => slot.ownedWith(owned) > 0)
              .length;

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
          RefreshIndicator(
            color: game.accent,
            backgroundColor: c.surface,
            onRefresh: () async {
              await ref
                  .read(catalogRepositoryProvider)
                  .cardsInSet(game, widget.setCode, forceRefresh: true);
              ref.invalidate(setCardsProvider(_ref));
              // A set that has just been downloaded has slots for the first
              // time, so its completion figure is new information rather than
              // a recalculation of the same numbers.
              ref.invalidate(setCompletionProvider(game));
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
                            // The rows this set stores, which is not always the
                            // provider's published card count: Yu-Gi-Oh!
                            // publishes one row per rarity, so a 126-card set
                            // holds 228 printings here. The list calls the
                            // provider's figure "cards", so this screen says
                            // what it is actually listing rather than repeating
                            // the word and contradicting the number.
                            if (cardsAsync.value != null)
                              _holdingsLabel(cardsAsync.value!),
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodySmall,
                        ),
                      ],
                    ),
                    actions: [
                      _FilterButton(
                        active: _filter.activeCount,
                        onPressed: cardsAsync.value == null
                            ? null
                            : () => _openFilters(
                                groupIntoSlots(cardsAsync.value!),
                              ),
                      ),
                      IconButton(
                        tooltip: _grid ? 'List view' : 'Grid view',
                        onPressed: () => setState(() => _grid = !_grid),
                        icon: Icon(
                          _grid
                              ? Icons.view_list_rounded
                              : Icons.grid_view_rounded,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Box value',
                        onPressed: cardsAsync.value == null
                            ? null
                            : () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => BoxEvScreen(
                                    game: widget.game,
                                    setCode: widget.setCode,
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.calculate_outlined),
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
                                child: Center(
                                  child: SetGlyph(set: set, size: 26),
                                ),
                              ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: PillToggle(
                                options: ['All cards', 'Owned ($ownedInSet)'],
                                selected: _ownedOnly ? 1 : 0,
                                onChanged: (i) =>
                                    setState(() => _ownedOnly = i == 1),
                                height: 34,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // The bar sits above the list rather than in the app bar:
                // the title row is already carrying three facts, and a
                // completion figure that only appears once scrolled past is
                // one nobody reads.
                if (cardsAsync.value != null && cardsAsync.value!.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: SetCompletionStrip(
                        slots: groupIntoSlots(cardsAsync.value!),
                        owned: owned,
                        game: game,
                      ),
                    ),
                  ),
                if (_filter.isActive)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: _FilterSummary(
                        filter: _filter,
                        onEdit: cardsAsync.value == null
                            ? null
                            : () => _openFilters(
                                groupIntoSlots(cardsAsync.value!),
                              ),
                        onClear: () =>
                            setState(() => _filter = const SetFilter()),
                      ),
                    ),
                  ),
                SliverAsyncView<List<TcgCard>>(
                  value: cardsAsync,
                  loadingHeight: 420,
                  onRetry: () => ref.invalidate(setCardsProvider(_ref)),
                  builder: (cards) {
                    // An empty set is handed to a widget of its own, because
                    // which kind of empty it is takes a second question: the
                    // shop either was never asked or answered nothing.
                    if (cards.isEmpty) {
                      return _NothingHere(ref0: _ref, game: game);
                    }
                    // One tile per binder slot, not per printing: the provider
                    // lists a Yu-Gi-Oh! card several times over - by rarity and
                    // by region - and three tiles that differ only in small
                    // print is noise. The versions live inside the slot.
                    final slots = _filter.apply(groupIntoSlots(cards));
                    final visible = _ownedOnly
                        ? slots.where((s) => s.ownedWith(owned) > 0).toList()
                        : slots;
                    if (visible.isEmpty) {
                      // Which of the two ways of seeing nothing happened, said
                      // plainly: the filter can be cleared from here, and a
                      // collector who narrowed a set to nothing should not have
                      // to hunt for the control that did it.
                      final filteredOut = _filter.isActive && slots.isEmpty;
                      return SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 80),
                          child: filteredOut
                              ? EmptyState(
                                  icon: Icons.filter_alt_off_rounded,
                                  title: 'No cards match',
                                  message:
                                      'None of the ${cards.length} printings in '
                                      'this set fits the filter.',
                                  action: FilledButton.tonal(
                                    onPressed: () => setState(
                                      () => _filter = const SetFilter(),
                                    ),
                                    child: const Text('Clear filters'),
                                  ),
                                )
                              : const EmptyState(
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
                              itemBuilder: (context, i) => _SlotGridTile(
                                slot: visible[i],
                                owned: visible[i].ownedWith(owned),
                                price: _filter.summarise(visible[i]),
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
                                child: _SlotListTile(
                                  slot: visible[i],
                                  owned: visible[i].ownedWith(owned),
                                  price: _filter.summarise(visible[i]),
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

/// A set with nothing in it, and which kind of nothing it is.
///
/// A catalogue lists sets before it has cards for them: TCGplayer opens a group
/// page the moment a set is announced, and Gundam's Blazing Fist sits there today
/// with a release date and no products at all. Opening one used to say "pull down
/// to download this set", which is advice that can never work - pulling downloads
/// the same nothing. The shop was asked; the answer was nothing; the screen says
/// so, and says when the cards are expected if the set has a date.
class _NothingHere extends ConsumerWidget {
  const _NothingHere({required this.ref0, required this.game});

  /// The set being looked at.
  final SetRef ref0;

  /// The game it belongs to, for the source's name.
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asked = ref.watch(setAskedProvider(ref0));
    if (asked.isLoading && !asked.hasValue) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 40, 16, 0),
          child: LoadingShimmer(height: 96),
        ),
      );
    }
    final set = ref.watch(setProvider(ref0)).value;
    final released = set?.releasedAt;
    final ahead = released != null && released.isAfter(DateTime.now());
    if (asked.value ?? false) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 60),
          child: EmptyState(
            icon: Icons.event_available_rounded,
            title: 'Not published yet',
            message: ahead
                ? '${game.dataSource} lists this set for ${Fmt.date(released)} '
                      'and has no cards on it yet. They appear here once the '
                      'shop publishes them.'
                : '${game.dataSource} lists this set and has published no cards '
                      'for it. Every set here comes from that shop, so there is '
                      'nothing this screen can show until it does.',
          ),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
        child: EmptyState(
          icon: Icons.inbox_rounded,
          title: 'No cards cached',
          message: 'Nothing has been downloaded for this set yet.',
          action: FilledButton.tonal(
            onPressed: () => ref.invalidate(setCardsProvider(ref0)),
            child: const Text('Download it'),
          ),
        ),
      ),
    );
  }
}

/// A card as a poster: art forward, with the collector number always visible.
class _CardGridTile extends StatelessWidget {
  const _CardGridTile({
    required this.card,
    required this.owned,
    required this.index,
    this.slot,
    this.slotPrice,
    this.onTap,
  });

  final TcgCard card;
  final int owned;
  final int index;

  /// The binder slot this tile stands for, when it stands for one.
  ///
  /// Set from the set grid and null when a tile is shown on its own. When it is
  /// present the tile speaks for every version at that number: the price
  /// becomes a starting point and the rarity gives way to the version count,
  /// because a slot holding four different rarities cannot be summarised by
  /// showing one of them.
  final PrintingSlot? slot;

  /// Overrides the default tap, which opens this single printing.
  final VoidCallback? onTap;

  /// The prices the filter leaves on show for this slot.
  ///
  /// Passed in rather than read off the slot, so a "$100 and up" pass does not
  /// headline a card with the price of a version it has just hidden.
  final SlotPrice? slotPrice;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final versions = slot;
    final shown =
        slotPrice ??
        SlotPrice(
          versions?.lowestPrice ?? card.prices.from,
          versions?.highestPrice ?? card.prices.from,
        );
    final spread = shown.hasSpread;
    final price = shown.low;

    return GestureDetector(
          onTap:
              onTap ??
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CardDetailScreen(game: card.game, cardId: card.id),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: c.surfaceRaised,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: c.hairline),
                    ),
                    child: Text(
                      '#${card.collectorNumber}',
                      style: context.t.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (price != null)
                    Text(
                      // A slot whose versions are worth different money says so
                      // rather than quoting one of them as if it were the price.
                      spread
                          ? 'from ${Fmt.moneyAdaptive(price)}'
                          : Fmt.moneyAdaptive(price),
                      style: context.t.labelMedium?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      card.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // A slot holding versions shows how many instead of a rarity:
                  // the rarity varies inside it, so any one of them would be a
                  // claim about the whole slot that is not true.
                  if (versions != null && versions.hasVersions)
                    _VersionChip(count: versions.versionCount)
                  else
                    RarityBadge(
                      rarity: rarity,
                      compact: true,
                      code: card.rarityCode,
                    ),
                ],
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
  const _CardListTile({
    required this.card,
    required this.owned,
    required this.index,
    this.slot,
    this.slotPrice,
    this.onTap,
  });

  final TcgCard card;
  final int owned;
  final int index;

  /// The binder slot this row stands for, when it stands for one. See
  /// [_CardGridTile.slot].
  final PrintingSlot? slot;

  /// Overrides the default tap, which opens this single printing.
  final VoidCallback? onTap;

  /// The prices the filter leaves on show. See [_CardGridTile.slotPrice].
  final SlotPrice? slotPrice;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = CardRarity.fromCode(card.rarity);
    final versions = slot;
    final shown =
        slotPrice ??
        SlotPrice(
          versions?.lowestPrice ?? card.prices.from,
          versions?.highestPrice ?? card.prices.from,
        );
    final spread = shown.hasSpread;
    final price = shown.low;
    final premium = card.game.finishes
        .where((f) => f.isPremium && (card.prices.priceFor(f) ?? 0) > 0)
        .toList();

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap:
          onTap ??
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  CardDetailScreen(game: card.game, cardId: card.id),
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
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (versions != null && versions.hasVersions)
                        _VersionChip(count: versions.versionCount)
                      else
                        RarityBadge(
                          rarity: rarity,
                          compact: true,
                          code: card.rarityCode,
                        ),
                      const SizedBox(width: 6),
                      // Magic identifies cards by mana cost, Pokémon by energy
                      // type — showing the wrong one would be nonsense.
                      if (card.game == CardGame.mtg && card.manaCost != null)
                        ManaCostRow(cost: card.manaCost, size: 13)
                      else if (card.game == CardGame.mtg)
                        ManaPips(
                          symbols: card.colors.isEmpty
                              ? const []
                              : [card.game.bucketFor(card.colors.first).symbol],
                          size: 13,
                          showColorless: card.colors.isEmpty,
                        )
                      else
                        // One pip, not all of them: this is a list row. The
                        // category is the game's own, which is why it is handed
                        // over as a bucket rather than as a letter.
                        ManaPips(
                          buckets: card.colors.isEmpty
                              ? const <ColourBucket>[]
                              : <ColourBucket>[
                                  card.game.bucketFor(card.colors.first),
                                ],
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
                Text(
                  spread ? 'from ${Fmt.money(price)}' : Fmt.money(price),
                  style: context.t.titleSmall,
                ),
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

/// A grid tile standing for a whole binder slot.
///
/// The rendering is the ordinary card tile's, because a slot's versions share
/// the artwork and the number; only the tap and the two summary figures differ.
class _SlotGridTile extends StatelessWidget {
  const _SlotGridTile({
    required this.slot,
    required this.owned,
    required this.price,
    required this.index,
  });

  final PrintingSlot slot;
  final int owned;
  final SlotPrice price;
  final int index;

  @override
  Widget build(BuildContext context) => _CardGridTile(
    card: slot.primary,
    owned: owned,
    index: index,
    slot: slot,
    slotPrice: price,
    onTap: () => openSlot(context, slot),
  );
}

/// A list row standing for a whole binder slot.
class _SlotListTile extends StatelessWidget {
  const _SlotListTile({
    required this.slot,
    required this.owned,
    required this.price,
    required this.index,
  });

  final PrintingSlot slot;
  final int owned;
  final SlotPrice price;
  final int index;

  @override
  Widget build(BuildContext context) => _CardListTile(
    card: slot.primary,
    owned: owned,
    index: index,
    slot: slot,
    slotPrice: price,
    onTap: () => openSlot(context, slot),
  );
}

/// Opens a slot: straight to the card when there is one version, and to the
/// list of versions when there are several.
///
/// Choosing between versions is a real decision - they are worth different
/// money and they are different cards to own - so a slot holding more than one
/// asks rather than picking silently on the collector's behalf.
Future<void> openSlot(BuildContext context, PrintingSlot slot) {
  if (!slot.hasVersions) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CardDetailScreen(game: slot.primary.game, cardId: slot.primary.id),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _VersionSheet(slot: slot),
  );
}

/// The versions of one card at one collector number, cheapest first.
class _VersionSheet extends StatelessWidget {
  const _VersionSheet({required this.slot});

  final PrintingSlot slot;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: GlassCard(
          radius: 22,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(slot.name, style: context.t.titleMedium),
              const SizedBox(height: 2),
              Text(
                // The count earns its place here: it is the reason the set
                // showed one tile where the provider lists several rows.
                '#${slot.collectorNumber} · ${slot.versionCount} versions, '
                'cheapest first',
                style: context.t.bodySmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: slot.printings.length,
                  itemBuilder: (BuildContext context, int i) {
                    final card = slot.printings[i];
                    final rarity = CardRarity.fromCode(card.rarity);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GlassCard(
                        radius: 14,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        onTap: () {
                          Navigator.of(context).pop();
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => CardDetailScreen(
                                game: card.game,
                                cardId: card.id,
                              ),
                            ),
                          );
                        },
                        child: Row(
                          children: <Widget>[
                            RarityBadge(
                              rarity: rarity,
                              compact: true,
                              code: card.rarityCode,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    card.rarity,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.t.titleSmall,
                                  ),
                                  // The region code is the only thing telling
                                  // two same-rarity versions apart.
                                  if (card.printingCode != null)
                                    Text(
                                      card.printingCode!,
                                      maxLines: 1,
                                      style: context.t.labelSmall?.copyWith(
                                        color: c.textTertiary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              Fmt.moneyAdaptive(card.prices.from),
                              style: context.t.titleSmall,
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: c.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small chip saying how many versions a slot holds.
class _VersionChip extends StatelessWidget {
  const _VersionChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: c.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.accent.withValues(alpha: 0.40)),
      ),
      child: Text(
        '$count×',
        style: context.t.labelSmall?.copyWith(
          color: c.accent,
          height: 1.1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The control that opens the filter sheet, carrying how much is set.
class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.active, required this.onPressed});

  /// How many filters are on, for the badge.
  final int active;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final button = IconButton(
      tooltip: active == 0 ? 'Filter cards' : 'Filter cards, $active on',
      onPressed: onPressed,
      icon: Icon(
        active == 0 ? Icons.tune_rounded : Icons.filter_alt_rounded,
        color: active == 0 ? null : c.accent,
      ),
    );
    if (active == 0) return button;
    return Badge(
      label: Text('$active'),
      backgroundColor: c.accent,
      child: button,
    );
  }
}

/// What a filter is currently doing, said in chips that can be tapped away.
///
/// The grid alone cannot explain why cards are missing. A row naming the filter
/// that removed them turns a screen that looks broken into one that is
/// obviously narrowed - and the chips are the way back out.
class _FilterSummary extends StatelessWidget {
  const _FilterSummary({
    required this.filter,
    required this.onEdit,
    required this.onClear,
  });

  final SetFilter filter;

  /// Opens the sheet again, or null while the set has not loaded.
  final VoidCallback? onEdit;

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final rarities = filter.rarities.toList()..sort();
    final labels = <String>[
      if (filter.filtersPrice) describePrice(filter.price),
      ...rarities,
      if (filter.sort != SetSort.number) filter.sort.label,
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        for (final label in labels) _SummaryChip(label: label, onTap: onEdit),
        _SummaryChip(
          label: 'Clear',
          icon: Icons.close_rounded,
          onTap: onClear,
          muted: true,
        ),
      ],
    );
  }
}

/// One chip of the filter summary.
class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.label,
    required this.onTap,
    this.icon,
    this.muted = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Whether the chip is the way out rather than part of the filter.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tint = muted ? c.textSecondary : c.accent;
    return Material(
      color: c.surfaceRaised,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: muted ? c.hairline : tint.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 13, color: tint),
                const SizedBox(width: 4),
              ],
              Text(label, style: context.t.labelMedium?.copyWith(color: tint)),
            ],
          ),
        ),
      ),
    );
  }
}
