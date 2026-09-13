import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/sets/printing_groups.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// How much of one set is collected, and what it would take to finish it.
///
/// Counted in binder slots, the same unit the grid below shows and the same
/// one the Owned filter selects, so the number here and the number of tiles
/// that filter leaves can never disagree.
class SetCompletionStrip extends ConsumerWidget {
  /// Creates the strip for one set's slots.
  const SetCompletionStrip({
    super.key,
    required this.slots,
    required this.owned,
    required this.game,
  });

  /// Every binder slot in the set, in binder order.
  final List<PrintingSlot> slots;

  /// How many physical cards are held, keyed by printing id.
  final Map<String, int> owned;

  /// The game the set belongs to, which is the wants list it would join.
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    if (slots.isEmpty) return const SizedBox.shrink();

    final filled = slots.where((s) => s.ownedWith(owned) > 0).length;
    final missing = slots.length - filled;
    final complete = missing == 0;
    final fraction = filled / slots.length;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  complete
                      ? 'Every card in this set is yours.'
                      : '$filled of ${slots.length} collected  ·  '
                            '$missing to go',
                  style: context.t.titleSmall,
                ),
              ),
              Text(
                Fmt.percentPlain(fraction * 100),
                style: context.t.titleSmall?.copyWith(
                  color: complete ? c.positive : c.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: c.hairline,
              valueColor: AlwaysStoppedAnimation<Color>(
                complete ? c.positive : c.accent,
              ),
            ),
          ),
          if (!complete) ...[
            const SizedBox(height: 12),
            // The button goes under the copy rather than beside it: two
            // lines of explanation in half the width is five lines, and the
            // button that follows is squeezed to a stub.
            Text(
              'Every card you are missing goes on your ${game.shortLabel} '
              'wants list, at the cheapest version of each.',
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _wantTheRest(context, ref),
                icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: Text('Want the $missing'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Puts every unfilled slot on the wants list.
  ///
  /// One want per slot rather than per printing: a Yu-Gi-Oh! slot can hold
  /// three versions of one card at wildly different prices, and wanting all
  /// three would put a $681 listing and a 14 cent one on the same list as if
  /// the collector meant to buy both. The slot's own [PrintingSlot.primary]
  /// picks the version a collector would most likely buy.
  Future<void> _wantTheRest(BuildContext context, WidgetRef ref) async {
    final ids = <String>[
      for (final slot in slots)
        if (slot.ownedWith(owned) == 0) slot.primary.id,
    ];
    if (ids.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Want ${ids.length} cards?'),
        content: Text(
          'Every card in this set you do not own goes on your '
          '${game.shortLabel} wants list. Cards you already have are left '
          'alone, and nothing is added to your collection.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add them'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final added = await ref.read(wantedDaoProvider).addAll(game, ids);
    ref.read(wantedRevisionProvider.notifier).bump();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            added == ids.length
                ? 'Wanted $added cards.'
                : 'Wanted $added more cards; the rest were already on '
                      'the list.',
          ),
        ),
      );
  }
}
