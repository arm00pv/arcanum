import 'dart:async';

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
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/mana_pips.dart';

/// The Search tab - the fourth bottom-nav destination.
///
/// A full screen with its own [Scaffold] rather than a nested navigator, so the
/// search field survives every tab switch and the results list keeps its scroll
/// position. Typing is debounced before it reaches [searchProvider], so a fast
/// typist issues one query instead of one per keystroke.
///
/// Everything here is scoped to the active game: the query is keyed by
/// [CardGame], the examples offered are that game's staples, and a row only
/// shows a mana cost for Magic.
class SearchScreen extends ConsumerStatefulWidget {
  /// Creates the search screen.
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  /// How long typing must pause before a query is committed.
  static const Duration _debounceDelay = Duration(milliseconds: 350);

  /// The minimum query length the catalogue will answer.
  static const int _minQueryLength = 2;

  /// Examples offered while the field is still empty, per game.
  ///
  /// Searching a Magic staple in a Pokémon catalogue - or the reverse - finds
  /// nothing, so the suggestions follow the active game.
  static const Map<CardGame, List<String>> _quickFilters =
      <CardGame, List<String>>{
    CardGame.mtg: <String>[
      'Lightning Bolt',
      'Sol Ring',
      'Counterspell',
      'Black Lotus',
      'Ragavan',
    ],
    CardGame.pokemon: <String>[
      'Charizard',
      'Pikachu',
      'Blastoise',
      'Mewtwo',
      'Umbreon',
    ],
  };

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;
  String _query = '';
  String _text = '';
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final double offset = _scroll.offset;
      if ((offset - _scrollOffset).abs() > 4) {
        setState(() => _scrollOffset = offset);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- query state

  /// Restarts the debounce window. [_text] tracks the field immediately so the
  /// clear button appears as soon as there is something to clear, while
  /// [_query] - the value the provider family is keyed on - waits for a pause.
  void _onChanged(String value) {
    _debounce?.cancel();
    setState(() => _text = value);
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  /// Commits a query immediately, skipping the debounce.
  void _submit(String value) {
    _debounce?.cancel();
    setState(() {
      _text = value;
      _query = value.trim();
    });
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _text = '';
      _query = '';
    });
  }

  /// Fills the field from a quick-filter chip and searches straight away.
  void _useQuickFilter(String query) {
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    _submit(query);
  }

  void _openCard(TcgCard card) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            CardDetailScreen(game: card.game, cardId: card.id),
      ),
    );
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final CardGame game = ref.watch(activeGameProvider);
    final bool discovering = _query.length < _minQueryLength;
    final AsyncValue<List<TcgCard>> results =
        ref.watch(searchProvider((game: game, query: _query)));
    // Copies owned of each printing in this game, summed across finishes and
    // conditions by the provider itself.
    final Map<String, int> owned =
        ref.watch(ownedQuantityProvider(game)).value ?? const <String, int>{};

    return Scaffold(
      appBar: GlassAppBar(
        scrollOffset: _scrollOffset,
        title: Text('Search', style: context.t.headlineSmall),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(76),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              onChanged: _onChanged,
              onSubmitted: _submit,
              decoration: InputDecoration(
                hintText: game == CardGame.mtg
                    ? 'Card name, set or oracle text'
                    : 'Card name, set or attack text',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  size: 20,
                  color: c.textTertiary,
                ),
                suffixIcon: _text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: c.textSecondary,
                        ),
                        onPressed: _clear,
                      ),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: 120),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: discovering
            ? _discovery(context, c, game)
            : _results(context, c, game, results, owned),
      ),
    );
  }

  // --------------------------------------------------------------- discovery

  /// The state shown before a query is long enough to run.
  List<Widget> _discovery(
    BuildContext context,
    ArcanumColors c,
    CardGame game,
  ) {
    final List<String> quick = _quickFilters[game] ?? const <String>[];
    final bool isMtg = game == CardGame.mtg;

    return <Widget>[
      const SizedBox(height: 12),
      EmptyState(
        icon: Icons.travel_explore_rounded,
        title: isMtg ? 'Search the multiverse' : 'Search every Pokémon set',
        message: 'Type at least two characters - card names, set names and '
            '${isMtg ? 'oracle text' : 'attack and rules text'} all work. '
            'Arcanum answers from your cached ${game.shortLabel} catalogue '
            'first and asks ${game.dataSource} for the rest.',
      ),
      SectionHeader(
        title: 'Quick filters',
        subtitle: '${game.shortLabel} staples - tap one to search for it',
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final String query in quick)
              ActionChip(
                label: Text(query),
                onPressed: () => _useQuickFilter(query),
              ),
          ],
        ),
      ),
      const SectionHeader(title: 'Search tips'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          radius: 20,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _SearchTip(
                icon: Icons.text_fields_rounded,
                label: 'Names',
                detail: isMtg
                    ? 'Partial names work: "bolt" finds Lightning Bolt.'
                    : 'Partial names work: "zard" finds Charizard.',
              ),
              _SearchTip(
                icon: Icons.category_outlined,
                label: 'Sets',
                detail: isMtg
                    ? 'Search a set name such as "Bloomburrow" to browse it.'
                    : 'Search a set name such as "Base Set" to browse it.',
              ),
              _SearchTip(
                icon: Icons.menu_book_rounded,
                label: 'Rules text',
                detail: isMtg
                    ? 'Oracle text is searched, so "draw a card" finds cantrips.'
                    : 'Attacks and rules are searched, so "discard an Energy" '
                        'finds the cards that do it.',
              ),
              _SearchTip(
                icon: Icons.sell_outlined,
                label: 'Prices',
                detail: 'Every result carries the cheapest price '
                    '${game.dataSource} quotes for that printing.',
                last: true,
              ),
            ],
          ),
        ),
      ),
    ];
  }

  // ----------------------------------------------------------------- results

  List<Widget> _results(
    BuildContext context,
    ArcanumColors c,
    CardGame game,
    AsyncValue<List<TcgCard>> results,
    Map<String, int> owned,
  ) {
    return <Widget>[
      const SizedBox(height: 12),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: AsyncValueView<List<TcgCard>>(
          value: results,
          loading: _loadingRows(),
          isEmpty: (List<TcgCard> cards) => cards.isEmpty,
          emptyMessage: 'No ${game.shortLabel} cards matched "$_query"',
          emptyIcon: Icons.search_off_rounded,
          errorTitle: 'Search failed',
          onRetry: () =>
              ref.invalidate(searchProvider((game: game, query: _query))),
          builder: (List<TcgCard> cards) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '${Fmt.count(cards.length)} cards',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
              for (final TcgCard card in cards)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SearchResultTile(
                    card: card,
                    owned: owned[card.id] ?? 0,
                    onTap: () => _openCard(card),
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  /// Placeholder rows shown while a query is in flight.
  Widget _loadingRows() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: LoadingShimmer(
              height: 78,
              borderRadius: BorderRadius.circular(20),
            ),
          ),
      ],
    );
  }
}

/// One search hit: art, identity, price and - when relevant - what the user
/// already owns of that printing.
class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.card,
    required this.owned,
    required this.onTap,
  });

  final TcgCard card;

  /// Copies of this printing in the user's collection, 0 when none.
  final int owned;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final CardRarity rarity = CardRarity.fromCode(card.rarity);

    // Magic only: Pokémon cards carry no mana cost at all. Multi-faced Magic
    // cards keep the cost on the front face.
    final String? manaCost = card.game == CardGame.mtg
        ? card.manaCost ??
            (card.faces.isNotEmpty ? card.faces.first.cost : null)
        : null;

    return GlassCard(
      radius: 20,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                CardThumbnail(
                  imageUrl: card.imageUrl(size: 'small'),
                  width: 56,
                  rarity: rarity,
                  semanticLabel: card.name,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              '${card.setCode.toUpperCase()} '
                              '#${card.collectorNumber}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.t.bodySmall
                                  ?.copyWith(color: c.textTertiary),
                            ),
                          ),
                          const SizedBox(width: 6),
                          RarityBadge(rarity: rarity, compact: true),
                        ],
                      ),
                      if (manaCost != null || owned > 0) ...<Widget>[
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            if (manaCost != null)
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: ManaCostRow(cost: manaCost, size: 13),
                                ),
                              ),
                            if (manaCost != null && owned > 0)
                              const SizedBox(width: 8),
                            if (owned > 0) _OwnedPill(count: owned),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  // The cheapest finish the game's provider actually quotes:
                  // Magic prices non-foil, foil and etched, Pokémon its own
                  // variants.
                  Fmt.money(card.prices.from),
                  maxLines: 1,
                  style: context.t.titleSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "you own N" pill shown on printings already in the collection.
class _OwnedPill extends StatelessWidget {
  const _OwnedPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.accent.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          'You own ${Fmt.count(count)}',
          maxLines: 1,
          style: context.t.labelSmall?.copyWith(color: c.accent),
        ),
      ),
    );
  }
}

/// One line of search guidance.
class _SearchTip extends StatelessWidget {
  const _SearchTip({
    required this.icon,
    required this.label,
    required this.detail,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String detail;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: c.accent),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: context.t.bodySmall?.copyWith(color: c.textSecondary),
                children: <InlineSpan>[
                  TextSpan(
                    text: '$label  ',
                    style: context.t.bodySmall?.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: detail),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
