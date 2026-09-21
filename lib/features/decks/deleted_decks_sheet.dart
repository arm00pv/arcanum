import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// The decks this device has deleted, and the way back for each of them.
///
/// The delete dialog says a deletion is not final, and this is where that stops
/// being a sentence and becomes something a collector can use. A deletion is a
/// mark on a row - the row stays, its lines stay, and nothing purges either
/// (docs/deck-sync.md, section 4.3) - so "deleted" is a state a deck can be in
/// and be taken out of, and a snack bar that lasts a few seconds is not an
/// answer to having deleted the wrong one.
///
/// Deliberately a sheet over the deck list rather than a screen of its own: for
/// most collectors it holds nothing most of the time, and a route that is
/// usually empty is a route nobody finds.
///
/// Restoring is the same edit the account already knows how to weigh. It clears
/// the mark and stamps the row, so the deletion is an older edit than the
/// revival and loses to it wherever the deck is - which is why a deck put back
/// here is not put back here only.
Future<void> showDeletedDecks(
  BuildContext context,
  WidgetRef ref,
  CardGame game,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (BuildContext context) => _DeletedDecksSheet(game: game),
);

/// The list itself.
class _DeletedDecksSheet extends ConsumerWidget {
  const _DeletedDecksSheet({required this.game});

  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    // An answer that has not arrived yet is drawn as an empty list rather than
    // as a spinner: this query is one local join over tens of rows, and a sheet
    // that flashes a spinner for a millisecond reads as a sheet that flickered.
    final List<Deck> decks =
        ref.watch(deletedDecksProvider(game)).value ?? const <Deck>[];

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
          children: <Widget>[
            Text('Deleted decks', style: context.t.titleMedium),
            const SizedBox(height: 4),
            Text(
              'A deletion keeps the deck and its cards, so putting one back '
              'puts all of it back.',
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 14),
            if (decks.isEmpty)
              Text(
                'No ${game.shortLabel} deck has been deleted here.',
                style: context.t.bodyMedium,
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: decks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (BuildContext context, int i) =>
                      _DeletedRow(deck: decks[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One deleted deck, with the button that brings it back.
class _DeletedRow extends ConsumerWidget {
  const _DeletedRow({required this.deck});

  final Deck deck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final parts = <String>[
      deck.formatLabel,
      '${deck.cardCount} ${deck.cardCount == 1 ? 'card' : 'cards'}',
    ];
    if (deck.sideboardCount > 0) parts.add('${deck.sideboardCount} side');

    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                deck.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                parts.join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall?.copyWith(color: c.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: () async {
            await ref.read(deckRepositoryProvider).restore(deck.id);
            ref.read(deckRevisionProvider.notifier).bump();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text('${deck.name} is back.')));
          },
          child: const Text('Put back'),
        ),
      ],
    );
  }
}
