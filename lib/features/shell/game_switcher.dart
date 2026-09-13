import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// A slim, always-visible strip showing which game the app is currently scoped
/// to. Tapping it opens the switcher.
///
/// This is the single control that changes what the entire app is looking at:
/// the catalogue, the collection, the portfolio and every price series swap
/// together. The two games are never merged, so this is a context switch rather
/// than a filter.
class GameSwitcherBar extends ConsumerWidget {
  const GameSwitcherBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final game = ref.watch(activeGameProvider);
    final summaries = ref.watch(gameSummariesProvider).value;
    final summary = summaries?[game];
    final c = context.c;

    return Semantics(
      button: true,
      label: 'Current game: ${game.label}. Tap to switch.',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => showGameSwitcherSheet(context, ref),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: game.accent.withValues(alpha: 0.10),
              border: Border(bottom: BorderSide(color: c.hairline)),
            ),
            child: Row(
              children: [
                _GameDot(game: game, size: 10),
                const SizedBox(width: 9),
                Text(
                  game.shortLabel,
                  style: context.t.titleSmall?.copyWith(color: game.accent),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: game.accent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    game.abbreviation,
                    style: context.t.labelSmall?.copyWith(color: game.accent),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    summary == null || summary.totalCards == 0
                        ? (summary?.hasCatalog == true
                              ? '${Fmt.count(summary!.setCount)} sets catalogued'
                              : 'Not downloaded yet')
                        : '${Fmt.count(summary.totalCards)} cards · '
                              '${Fmt.moneyCompact(summary.totalValue)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ),
                Text(
                  'Switch',
                  style: context.t.labelSmall?.copyWith(color: game.accent),
                ),
                Icon(Icons.unfold_more_rounded, size: 16, color: game.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the game switcher as a bottom sheet.
Future<void> showGameSwitcherSheet(BuildContext context, WidgetRef ref) async {
  final chosen = await showModalBottomSheet<CardGame>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _GameSwitcherSheet(),
  );
  if (chosen != null) {
    ref.read(activeGameProvider.notifier).select(chosen);
  }
}

class _GameSwitcherSheet extends ConsumerWidget {
  const _GameSwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final active = ref.watch(activeGameProvider);
    final summaries = ref.watch(gameSummariesProvider).value ?? const {};

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: c.hairline),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.hairlineStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text('Your games', style: context.t.headlineSmall),
            const SizedBox(height: 4),
            Text(
              'Each game keeps its own catalogue, collection and portfolio. '
              'Nothing is ever combined.',
              style: context.t.bodySmall,
            ),
            const SizedBox(height: 18),
            for (final game in CardGame.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _GameCard(
                  game: game,
                  selected: game == active,
                  summary: summaries[game],
                  onTap: () => Navigator.of(context).pop(game),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.game,
    required this.selected,
    required this.summary,
    required this.onTap,
  });

  final CardGame game;
  final bool selected;
  final GameSummary? summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      borderGradient: selected
          ? LinearGradient(
              colors: [
                game.accent.withValues(alpha: 0.9),
                game.accent.withValues(alpha: 0.15),
              ],
            )
          : null,
      semanticLabel: '${game.label}${selected ? ', currently selected' : ''}',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _GameDot(game: game, size: 14),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    game.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleMedium,
                  ),
                ),
                if (selected)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: game.accent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'VIEWING',
                      style: context.t.labelSmall?.copyWith(color: game.accent),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Cards since ${game.catalogueSince} · ${game.dataSource}',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _Stat(
                  label: 'Cards',
                  value: Fmt.count(summary?.totalCards ?? 0),
                ),
                _Stat(
                  label: 'Unique',
                  value: Fmt.count(summary?.uniqueCards ?? 0),
                ),
                _Stat(
                  label: 'Value',
                  value: Fmt.moneyCompact(summary?.totalValue ?? 0),
                ),
                _Stat(
                  label: 'Sets',
                  value: summary?.hasCatalog == true
                      ? Fmt.count(summary!.setCount)
                      : '--',
                ),
              ],
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 200.ms).slideY(begin: 0.04, end: 0);
  }
}

class _GameDot extends StatelessWidget {
  const _GameDot({required this.game, this.size = 10});

  final CardGame game;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: game.gradient,
        boxShadow: [
          BoxShadow(
            color: game.accent.withValues(alpha: 0.5),
            blurRadius: size,
            spreadRadius: -1,
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.t.labelSmall?.copyWith(
              color: context.c.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: context.t.bodyMedium),
        ],
      ),
    );
  }
}
