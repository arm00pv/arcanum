import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';

/// The bookmark that adds a printing to the wants list, or takes it off.
///
/// It reads the list rather than holding its own flag, so a card marked from
/// one screen is marked on every other one immediately - and so a card that was
/// bought and removed from the wants list stops claiming to be wanted.
class WantButton extends ConsumerWidget {
  /// Creates the button for one printing.
  const WantButton({super.key, required this.card, this.iconSize});

  /// The printing the button acts on. Its own game decides which list it joins.
  final TcgCard card;

  /// Optional glyph size, for use in a dense row.
  final double? iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wanted =
        ref.watch(wantedIdsProvider(card.game)).value?.contains(card.id) ??
        false;

    return IconButton(
      tooltip: wanted ? 'Remove from wants' : 'Want this card',
      iconSize: iconSize,
      icon: Icon(
        wanted ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        color: wanted ? context.c.accent : null,
      ),
      onPressed: () async {
        final dao = ref.read(wantedDaoProvider);
        if (wanted) {
          await dao.remove(card.game, card.id);
        } else {
          await dao.add(card.game, card.id);
        }
        ref.read(wantedRevisionProvider.notifier).bump();
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(
                wanted
                    ? 'Removed from wants'
                    : 'Wanted. It is in the wants list until you own it.',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
      },
    );
  }
}
