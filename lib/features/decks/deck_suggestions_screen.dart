import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_roles.dart';
import 'package:arcanum/domain/decks/deck_suggestions.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Cards the collector already owns that would fit one deck, best first.
///
/// The whole screen is a list of arguments: every row says why it is there, in
/// the deck's own numbers. That is the difference between a builder that helps
/// and one that is simply confident.
class DeckSuggestionsScreen extends ConsumerStatefulWidget {
  /// Creates the screen for one deck.
  const DeckSuggestionsScreen({super.key, required this.deckId});

  /// The deck's row id.
  final int deckId;

  @override
  ConsumerState<DeckSuggestionsScreen> createState() =>
      _DeckSuggestionsScreenState();
}

class _DeckSuggestionsScreenState extends ConsumerState<DeckSuggestionsScreen> {
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final contents = ref.watch(deckProvider(widget.deckId)).value;
    final CardGame game = contents?.deck.game ?? ref.watch(activeGameProvider);
    final suggestions = ref.watch(deckSuggestionsProvider(widget.deckId));
    final format = contents?.deck.format;
    final hasCommander =
        (format?.hasCommander ?? false) &&
        (contents?.board(DeckBoard.commander).isEmpty ?? true);

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: game.accent),
              ),
            ),
          ),
          CustomScrollView(
            slivers: <Widget>[
              SliverToBoxAdapter(
                child: GlassAppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text('From your collection', style: context.t.titleLarge),
                      Text(
                        contents == null
                            ? game.shortLabel
                            : 'cards you own that fit ${contents.deck.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverAsyncView<List<DeckSuggestion>>(
                value: suggestions,
                loadingHeight: 320,
                onRetry: () =>
                    ref.invalidate(deckSuggestionsProvider(widget.deckId)),
                isEmpty: (List<DeckSuggestion> value) => value.isEmpty,
                emptyIcon: Icons.auto_awesome_rounded,
                emptyTitle: 'Nothing left to suggest',
                emptyMessage:
                    'Every card you own that fits this deck is already in it, '
                    'or the deck has nothing to build on yet.',
                builder: (List<DeckSuggestion> value) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  sliver: SliverList.builder(
                    itemCount: value.length + 1,
                    itemBuilder: (BuildContext context, int i) {
                      if (i == 0) return const _Explainer();
                      final suggestion = value[i - 1];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _SuggestionRow(
                          suggestion: suggestion,
                          commanderCandidate:
                              hasCommander && _isLegendary(suggestion.card),
                          onAdd: () => _add(suggestion, DeckBoard.main),
                          onCommander: () =>
                              _add(suggestion, DeckBoard.commander),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// True for a card that could lead a commander deck.
  static bool _isLegendary(TcgCard card) {
    final line = card.typeLine ?? '';
    return line.toLowerCase().contains('legendary') &&
        CardTypes.parse(card).isCreature;
  }

  Future<void> _add(DeckSuggestion suggestion, DeckBoard board) async {
    await ref
        .read(deckRepositoryProvider)
        .addCard(widget.deckId, suggestion.card.id, board: board);
    ref.read(deckRevisionProvider.notifier).bump();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 1),
          content: Text(
            board == DeckBoard.commander
                ? '${suggestion.card.name} leads the deck'
                : 'Added ${suggestion.card.name}',
          ),
        ),
      );
  }
}

/// One line explaining what the ranking is and is not.
class _Explainer extends StatelessWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        'Ranked on what this deck is actually short of, then on the tribe it '
        'already plays, then on how popular a card is. Only cards you own are '
        'offered, and nothing its format forbids.',
        style: context.t.bodySmall?.copyWith(color: c.textTertiary),
      ),
    );
  }
}

/// One suggestion, with the numbers behind it.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.commanderCandidate,
    required this.onAdd,
    required this.onCommander,
  });

  final DeckSuggestion suggestion;
  final bool commanderCandidate;
  final VoidCallback onAdd;
  final VoidCallback onCommander;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final card = suggestion.card;
    final price = card.prices.from;

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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
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
                children: <Widget>[
                  Text(
                    card.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    suggestion.reasons.first,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(color: c.accent),
                  ),
                  if (suggestion.reasons.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        suggestion.reasons.skip(1).join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.labelSmall?.copyWith(
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    suggestion.canAdd > 1
                        ? 'you own ${suggestion.owned}  ·  ${suggestion.canAdd} spare'
                        : 'you own ${suggestion.owned}',
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  Fmt.moneyAdaptive(price),
                  style: context.t.labelSmall?.copyWith(
                    color: price == null ? c.textTertiary : c.gold,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (commanderCandidate)
                      IconButton(
                        tooltip: 'Make it the commander',
                        visualDensity: VisualDensity.compact,
                        iconSize: 20,
                        icon: Icon(Icons.military_tech_outlined, color: c.gold),
                        onPressed: onCommander,
                      ),
                    IconButton(
                      tooltip: 'Add to the deck',
                      visualDensity: VisualDensity.compact,
                      iconSize: 22,
                      icon: Icon(
                        Icons.add_circle_outline_rounded,
                        color: c.accent,
                      ),
                      onPressed: onAdd,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
