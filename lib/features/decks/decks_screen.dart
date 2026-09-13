import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/decks/deck_detail_screen.dart';
import 'package:arcanum/features/decks/deck_form.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Every deck of the active game, with what each is worth and what it needs.
///
/// This is the one screen where a collection stops being an inventory: the
/// same 751 cards are worth something different depending on whether they sit
/// in a deck that gets played or in a box.
class DecksScreen extends ConsumerWidget {
  /// Creates the decks tab.
  const DecksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final async = ref.watch(decksProvider(game));
    final decks = async.value ?? const <DeckContents>[];

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
            onRefresh: () async => ref.invalidate(decksProvider(game)),
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: GlassAppBar(
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Decks', style: context.t.headlineMedium),
                        Text(
                          _subtitle(game, decks),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodySmall,
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'New deck',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () => createDeck(context, ref, game),
                      ),
                    ],
                  ),
                ),
                SliverAsyncView<List<DeckContents>>(
                  value: async,
                  loadingHeight: 320,
                  isEmpty: (list) => list.isEmpty,
                  emptyIcon: Icons.style_outlined,
                  emptyTitle: 'No decks yet',
                  emptyMessage:
                      'A deck is a list of cards with a format attached. '
                      'Build one and Arcanum will show how much of it you '
                      'already own, what the rest would cost, and whether it '
                      'is legal.',
                  onRetry: () => ref.invalidate(decksProvider(game)),
                  builder: (list) => SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                    sliver: SliverList.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _DeckTile(contents: list[i], index: i),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The line under the title: which game, how many decks, what they are worth.
  static String _subtitle(CardGame game, List<DeckContents> decks) {
    if (decks.isEmpty) return game.shortLabel;
    final total = decks.fold(0.0, (double a, DeckContents d) => a + d.value);
    final noun = decks.length == 1 ? 'deck' : 'decks';
    return '${game.shortLabel}  ·  ${decks.length} $noun  ·  '
        '${Fmt.moneyCompact(total)}';
  }
}

/// One deck in the list.
class _DeckTile extends StatelessWidget {
  const _DeckTile({required this.contents, required this.index});

  final DeckContents contents;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final deck = contents.deck;
    final format = deck.format;
    final target = format?.minCards ?? 0;
    final size = contents.size;
    final complete = target > 0 && size >= target;
    final missing = contents.missingValue;

    return GlassCard(
          padding: EdgeInsets.zero,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DeckDetailScreen(deckId: deck.id),
            ),
          ),
          semanticLabel: '${deck.name}, ${deck.formatLabel}',
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        deck.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      Fmt.moneyCompact(contents.value),
                      style: context.t.titleSmall?.copyWith(color: c.gold),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.textTertiary,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _MetaLine(
                  format: deck.formatLabel,
                  size: size,
                  target: target,
                  sideboard: contents.sideboardSize,
                  missing: missing,
                ),
                if (target > 0) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: (size / target).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: c.hairline,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        complete ? c.positive : c.accent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 220.ms, delay: (index.clamp(0, 12) * 22).ms)
        .slideX(begin: 0.04, end: 0, curve: Curves.easeOutCubic);
  }
}

/// The format, size and cost line on a deck tile.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.format,
    required this.size,
    required this.target,
    required this.sideboard,
    required this.missing,
  });

  final String format;
  final int size;
  final int target;
  final int sideboard;
  final double missing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        DeckChip(label: format),
        const SizedBox(width: 8),
        Text(
          target > 0 ? '$size/$target cards' : '$size cards',
          style: context.t.bodySmall,
        ),
        if (sideboard > 0) ...[
          Text('  ·  ', style: context.t.bodySmall),
          Text('$sideboard side', style: context.t.bodySmall),
        ],
        if (missing > 0) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${Fmt.moneyCompact(missing)} to finish',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.t.labelSmall?.copyWith(color: c.warning),
            ),
          ),
        ],
      ],
    );
  }
}

/// The small accent pill a deck wears beside its format.
class DeckChip extends StatelessWidget {
  /// Creates the chip.
  const DeckChip({super.key, required this.label, this.colour});

  final String label;
  final Color? colour;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final tint = colour ?? c.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(label, style: context.t.labelSmall?.copyWith(color: tint)),
    );
  }
}
