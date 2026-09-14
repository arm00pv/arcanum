import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// The collection by physical location.
///
/// The app has stored a binder name on every stack since the first version,
/// and the collection screen has never mentioned it. This is the answer to the
/// question a collector actually asks while holding a card - which box is this
/// one in - and to its opposite, what is in this box.
///
/// A stack with no binder is not hidden: it is collected under "Not filed",
/// which is itself useful, because it is the pile nobody has got round to.
class BindersScreen extends ConsumerWidget {
  /// Creates the screen.
  const BindersScreen({super.key});

  /// What an unfiled stack is grouped under.
  static const unfiled = 'Not filed';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final async = ref.watch(collectionOverviewProvider(game));
    final binders = _group(async.value);
    final loose = binders.fold<int>(0, (int a, _Binder b) => a + b.cards);

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
                      Text('Binders', style: context.t.titleLarge),
                      Text(
                        binders.isEmpty
                            ? game.shortLabel
                            : '${game.shortLabel}  ·  ${binders.length} '
                                  '${binders.length == 1 ? 'binder' : 'binders'}  ·  '
                                  '${Fmt.count(loose)} cards',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverAsyncView<CollectionOverview>(
                value: async,
                loadingHeight: 320,
                onRetry: () => ref.invalidate(collectionOverviewProvider(game)),
                isEmpty: (CollectionOverview o) => o.entries.isEmpty,
                emptyIcon: Icons.inventory_2_outlined,
                emptyTitle: 'Nothing to file',
                emptyMessage:
                    'Record where a card lives when you add it - a binder, a '
                    'box, a shelf - and this screen becomes a map of your '
                    '${game.shortLabel} collection.',
                builder: (CollectionOverview o) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  sliver: SliverList.builder(
                    itemCount: binders.length,
                    itemBuilder: (BuildContext context, int i) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _BinderTile(
                        binder: binders[i],
                        game: game,
                        index: i,
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

  /// Gathers the stacks into binders, biggest first.
  static List<_Binder> _group(CollectionOverview? overview) {
    if (overview == null) return const <_Binder>[];
    final byName = <String, List<ValuedEntry>>{};
    for (final valued in overview.entries) {
      final name = valued.entry.binder.trim().isEmpty
          ? unfiled
          : valued.entry.binder.trim();
      byName.putIfAbsent(name, () => <ValuedEntry>[]).add(valued);
    }
    final out = <_Binder>[
      for (final entry in byName.entries)
        _Binder(name: entry.key, stacks: entry.value),
    ]..sort((_Binder a, _Binder b) => b.value.compareTo(a.value));
    return out;
  }
}

/// One binder's worth of stacks.
class _Binder {
  _Binder({required this.name, required this.stacks});

  final String name;
  final List<ValuedEntry> stacks;

  int get cards =>
      stacks.fold(0, (int a, ValuedEntry v) => a + v.entry.quantity);

  int get unique => stacks.length;

  double get value =>
      stacks.fold(0.0, (double a, ValuedEntry v) => a + (v.totalValue ?? 0));

  /// The most valuable stack, which is the one worth knowing about.
  ValuedEntry? get richest {
    if (stacks.isEmpty) return null;
    return stacks.reduce(
      (ValuedEntry a, ValuedEntry b) =>
          (a.totalValue ?? 0) >= (b.totalValue ?? 0) ? a : b,
    );
  }
}

/// One binder in the list.
class _BinderTile extends StatelessWidget {
  const _BinderTile({
    required this.binder,
    required this.game,
    required this.index,
  });

  final _Binder binder;
  final CardGame game;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final richest = binder.richest;

    return GlassCard(
          padding: EdgeInsets.zero,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  BinderDetailScreen(binder: binder.name, game: game),
            ),
          ),
          semanticLabel: '${binder.name}, ${binder.cards} cards',
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              binder.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.t.titleMedium,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            Fmt.moneyCompact(binder.value),
                            style: context.t.titleSmall?.copyWith(
                              color: c.gold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: c.textTertiary,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${Fmt.countOf(binder.cards, 'card')}  ·  '
                        '${binder.unique} '
                        'distinct${richest?.card == null ? '' : '  ·  top: '
                                  '${richest!.card!.name}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 220.ms, delay: (index.clamp(0, 10) * 22).ms)
        .slideX(begin: 0.04, end: 0, curve: Curves.easeOutCubic);
  }
}

/// Everything filed in one binder.
class BinderDetailScreen extends ConsumerWidget {
  /// Creates the screen.
  const BinderDetailScreen({
    super.key,
    required this.binder,
    required this.game,
  });

  /// The binder's name, or [BindersScreen.unfiled].
  final String binder;
  final CardGame game;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final async = ref.watch(collectionOverviewProvider(game));
    final stacks =
        <ValuedEntry>[
          for (final v in async.value?.entries ?? const <ValuedEntry>[])
            if (_nameOf(v.entry) == binder) v,
        ]..sort(
          (ValuedEntry a, ValuedEntry b) =>
              (b.totalValue ?? 0).compareTo(a.totalValue ?? 0),
        );
    final cards = stacks.fold<int>(
      0,
      (int a, ValuedEntry v) => a + v.entry.quantity,
    );
    final value = stacks.fold<double>(
      0,
      (double a, ValuedEntry v) => a + (v.totalValue ?? 0),
    );

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
                      Text(
                        binder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleLarge,
                      ),
                      Text(
                        '$cards cards  ·  ${stacks.length} distinct  ·  '
                        '${Fmt.moneyCompact(value)}',
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverAsyncView<CollectionOverview>(
                value: async,
                loadingHeight: 320,
                onRetry: () => ref.invalidate(collectionOverviewProvider(game)),
                isEmpty: (CollectionOverview o) => stacks.isEmpty,
                emptyIcon: Icons.inbox_rounded,
                emptyTitle: 'Nothing in here',
                emptyMessage: 'This binder holds no cards.',
                builder: (CollectionOverview o) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                  sliver: SliverList.builder(
                    itemCount: stacks.length,
                    itemBuilder: (BuildContext context, int i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _StackTile(valued: stacks[i], game: game),
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

  static String _nameOf(CollectionEntry entry) =>
      entry.binder.trim().isEmpty ? BindersScreen.unfiled : entry.binder.trim();
}

/// One stack inside a binder.
class _StackTile extends StatelessWidget {
  const _StackTile({required this.valued, required this.game});

  final ValuedEntry valued;
  final CardGame game;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final entry = valued.entry;
    final card = valued.card;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CardDetailScreen(game: game, cardId: entry.cardId),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 42,
                rarity: CardRarity.fromCode(card?.rarity),
                quantity: entry.quantity.toDouble(),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? entry.cardId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${card?.setCode.toUpperCase() ?? ''} '
                    '${entry.finish.shortLabel}  ·  ${entry.condition.short}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              Fmt.moneyAdaptive(valued.totalValue),
              style: context.t.titleSmall?.copyWith(color: c.gold),
            ),
          ],
        ),
      ),
    );
  }
}
