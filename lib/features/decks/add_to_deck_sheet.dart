import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/decks/deck_form.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// Puts a card into one of the game's decks, from the card's own screen.
///
/// A sheet rather than a screen: the collector already decided what to add,
/// and the only remaining question is which deck.
Future<void> showAddToDeckSheet(
  BuildContext context,
  WidgetRef ref,
  TcgCard card,
) async {
  final decks = await ref.read(deckRepositoryProvider).all(card.game);
  if (!context.mounted) return;

  final chosen = await showModalBottomSheet<_DeckChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => _DeckSheet(decks: decks, card: card),
  );
  if (chosen == null) return;

  await ref
      .read(deckRepositoryProvider)
      .addCard(
        chosen.deckId,
        card.id,
        board: chosen.board,
        quantity: chosen.quantity,
      );
  ref.read(deckRevisionProvider.notifier).bump();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(chosen.message(card.name))));
}

/// What the sheet hands back.
class _DeckChoice {
  const _DeckChoice({
    required this.deckId,
    required this.deckName,
    required this.board,
    required this.quantity,
  });

  final int deckId;
  final String deckName;
  final DeckBoard board;
  final int quantity;

  String message(String cardName) => quantity == 1
      ? 'Added $cardName to $deckName.'
      : 'Added $quantity $cardName to $deckName.';
}

/// The sheet: which deck, which board, how many.
class _DeckSheet extends ConsumerStatefulWidget {
  const _DeckSheet({required this.decks, required this.card});

  final List<DeckContents> decks;
  final TcgCard card;

  @override
  ConsumerState<_DeckSheet> createState() => _DeckSheetState();
}

class _DeckSheetState extends ConsumerState<_DeckSheet> {
  int? _deckId;
  DeckBoard _board = DeckBoard.main;
  int _quantity = 1;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final decks = widget.decks;
    final chosen = _chosen(decks);
    final format = chosen?.deck.format;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: GlassCard(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add to a deck', style: context.t.titleMedium),
            const SizedBox(height: 4),
            Text(
              widget.card.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 16),
            if (decks.isEmpty)
              Text(
                'There are no ${widget.card.game.shortLabel} decks yet.',
                style: context.t.bodyMedium,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final deck in decks)
                    ChoiceChip(
                      label: Text(deck.deck.name),
                      selected: deck.deck.id == _deckId,
                      onSelected: (_) => setState(() {
                        _deckId = deck.deck.id;
                        _board = DeckBoard.main;
                      }),
                    ),
                ],
              ),
            if (chosen != null) ...[
              if (format != null &&
                  (format.hasCommander || format.hasSideboard)) ...[
                const SizedBox(height: 16),
                Text('Board', style: context.t.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    for (final board in <DeckBoard>[
                      DeckBoard.main,
                      if (format.hasCommander) DeckBoard.commander,
                      if (format.hasSideboard) DeckBoard.side,
                    ])
                      ChoiceChip(
                        label: Text(board.label),
                        selected: board == _board,
                        onSelected: (_) => setState(() => _board = board),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Copies', style: context.t.titleSmall),
                  const Spacer(),
                  IconButton(
                    onPressed: _quantity > 1
                        ? () => setState(() => _quantity -= 1)
                        : null,
                    icon: const Icon(Icons.remove_rounded, size: 18),
                  ),
                  Text('$_quantity', style: context.t.titleMedium),
                  IconButton(
                    onPressed: () => setState(() => _quantity += 1),
                    icon: const Icon(Icons.add_rounded, size: 18),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (decks.isEmpty)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final id = await createDeck(
                          context,
                          ref,
                          widget.card.game,
                        );
                        if (id != null && context.mounted) {
                          Navigator.of(context).pop(
                            _DeckChoice(
                              deckId: id,
                              deckName: 'the new deck',
                              board: DeckBoard.main,
                              quantity: 1,
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('New deck'),
                    ),
                  )
                else ...[
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: chosen == null
                          ? null
                          : () => Navigator.of(context).pop(
                              _DeckChoice(
                                deckId: chosen.deck.id,
                                deckName: chosen.deck.name,
                                board: _board,
                                quantity: _quantity,
                              ),
                            ),
                      child: const Text('Add'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The deck the collector picked, or null while none is picked.
  DeckContents? _chosen(List<DeckContents> decks) {
    for (final deck in decks) {
      if (deck.deck.id == _deckId) return deck;
    }
    return null;
  }
}
