import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Searches the catalogue and drops what is found straight into a deck.
///
/// A picker rather than a trip through the card screen: building a deck means
/// adding thirty cards in a row, and thirty round trips through a detail page
/// is the difference between a feature and a chore.
class DeckCardPicker extends ConsumerStatefulWidget {
  /// Creates the picker for one deck.
  const DeckCardPicker({super.key, required this.deckId, required this.game});

  final int deckId;
  final CardGame game;

  @override
  ConsumerState<DeckCardPicker> createState() => _DeckCardPickerState();
}

class _DeckCardPickerState extends ConsumerState<DeckCardPicker> {
  final _controller = TextEditingController();
  String _query = '';
  DeckBoard _board = DeckBoard.main;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final search = ref.watch(
      searchProvider((game: widget.game, query: _query)),
    );
    final deck = ref.watch(deckProvider(widget.deckId)).value;
    final format = deck?.deck.format;

    // A format without a sideboard has no business offering one, and a deck
    // that is not a commander deck has nothing to put there.
    final boards = <DeckBoard>[
      DeckBoard.main,
      if (format?.hasCommander ?? false) DeckBoard.commander,
      if (format?.hasSideboard ?? false) DeckBoard.side,
    ];
    final short = _query.trim().length < 2;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: widget.game.accent),
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
                      Text('Add cards', style: context.t.titleLarge),
                      Text(
                        deck == null
                            ? widget.game.shortLabel
                            : 'to ${deck.deck.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    onChanged: (String v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search ${widget.game.shortLabel} cards',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _controller.clear();
                                setState(() => _query = '');
                              },
                            ),
                    ),
                  ),
                ),
              ),
              if (boards.length > 1)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: PillToggle(
                      options: <String>[
                        for (final board in boards) board.label,
                      ],
                      selected: boards.indexWhere((DeckBoard b) => b == _board),
                      onChanged: (int i) => setState(() => _board = boards[i]),
                    ),
                  ),
                ),
              SliverAsyncView<List<TcgCard>>(
                value: search,
                loadingHeight: 300,
                onRetry: () => ref.invalidate(
                  searchProvider((game: widget.game, query: _query)),
                ),
                isEmpty: (List<TcgCard> cards) => cards.isEmpty,
                emptyIcon: Icons.search_rounded,
                emptyTitle: short ? 'Search the catalogue' : 'Nothing found',
                emptyMessage: short
                    ? 'Two letters or more. Results come from what is '
                          'already downloaded, plus a live lookup.'
                    : 'Try part of the card name.',
                builder: (List<TcgCard> cards) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
                  sliver: SliverList.builder(
                    itemCount: cards.length,
                    itemBuilder: (BuildContext context, int i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _Result(
                        card: cards[i],
                        inDeck: _inDeck(deck, cards[i].id),
                        onAdd: () => _add(cards[i]),
                      ),
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

  /// How many copies of this printing the deck already holds, on any board.
  static int _inDeck(DeckContents? deck, String cardId) {
    if (deck == null) return 0;
    var total = 0;
    for (final entry in deck.entries) {
      if (entry.cardId == cardId) total += entry.quantity;
    }
    return total;
  }

  Future<void> _add(TcgCard card) async {
    await ref
        .read(deckRepositoryProvider)
        .addCard(widget.deckId, card.id, board: _board);
    ref.read(deckRevisionProvider.notifier).bump();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text('Added ${card.name} to ${_board.label}'),
        ),
      );
  }
}

/// One search result, with what the deck already holds.
class _Result extends StatelessWidget {
  const _Result({
    required this.card,
    required this.inDeck,
    required this.onAdd,
  });

  final TcgCard card;
  final int inDeck;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final price = card.prices.from;
    final where = '${card.setCode.toUpperCase()} #${card.collectorNumber}';

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: onAdd,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: CardThumbnail(
                imageUrl: card.imageUrl(size: 'small'),
                width: 42,
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
                    inDeck == 0 ? where : '$where  ·  $inDeck in this deck',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: inDeck == 0 ? c.textTertiary : c.accent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              Fmt.moneyAdaptive(price),
              style: context.t.titleSmall?.copyWith(
                color: price == null ? c.textTertiary : c.gold,
              ),
            ),
            IconButton(
              tooltip: 'Add to the deck',
              icon: Icon(Icons.add_circle_outline_rounded, color: c.accent),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}
