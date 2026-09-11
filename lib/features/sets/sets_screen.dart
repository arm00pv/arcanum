import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/features/sets/set_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// Browses every set of the active game, newest first.
///
/// The catalogue runs to a thousand sets for Magic, so the screen is built
/// around filtering rather than paging: search by name or code, narrow by set
/// type, and re-sort.
class SetsScreen extends ConsumerStatefulWidget {
  const SetsScreen({super.key});

  @override
  ConsumerState<SetsScreen> createState() => _SetsScreenState();
}

class _SetsScreenState extends ConsumerState<SetsScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  String _query = '';
  String? _typeFilter;
  SetSort _sort = SetSort.newest;
  double _scrollOffset = 0;
  bool _refreshing = false;
  int _progressDone = 0;
  int _progressTotal = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refresh(CardGame game) async {
    setState(() {
      _refreshing = true;
      _progressDone = 0;
      _progressTotal = 0;
    });
    try {
      await ref.read(catalogRepositoryProvider).loadSets(
            game,
            forceRefresh: true,
            onProgress: (done, total) {
              if (mounted) setState(() => _progressDone = done);
              _progressTotal = total;
            },
          );
      ref.invalidate(setsProvider(game));
      ref.invalidate(setTypeCountsProvider(game));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${game.shortLabel} catalogue refreshed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not refresh: $e')));
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final setsAsync = ref.watch(setsProvider(game));
    final ownedBySet =
        ref.watch(ownedBySetProvider(game)).value ?? const <String, int>{};
    final typeCounts =
        ref.watch(setTypeCountsProvider(game)).value ?? const <String, int>{};

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppTheme.backdrop(c, tint: game.accent)),
            ),
          ),
          RefreshIndicator(
            onRefresh: () => _refresh(game),
            color: game.accent,
            backgroundColor: c.surface,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: GlassAppBar(
                    scrollOffset: _scrollOffset,
                    title: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Sets', style: context.t.headlineMedium),
                        Text(
                          'Every ${game.shortLabel} printing since ${game.catalogueSince}',
                          style: context.t.bodySmall,
                        ),
                      ],
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Refresh catalogue',
                        onPressed: _refreshing ? null : () => _refresh(game),
                        icon: _refreshing
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: game.accent,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                ),
                if (_refreshing)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _progressTotal > 0
                                ? 'Downloading set details — $_progressDone of $_progressTotal'
                                : 'Downloading catalogue…',
                            style: context.t.labelSmall,
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: _progressTotal > 0
                                  ? _progressDone / _progressTotal
                                  : null,
                              minHeight: 3,
                              backgroundColor: c.surfaceRaised,
                              valueColor: AlwaysStoppedAnimation(game.accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _query = v),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search sets by name or code',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: SizedBox(
                      height: 36,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _TypeChip(
                            label: 'All',
                            count: typeCounts.values.fold<int>(0, (a, b) => a + b),
                            selected: _typeFilter == null,
                            onTap: () => setState(() => _typeFilter = null),
                          ),
                          for (final entry in _topTypes(typeCounts))
                            _TypeChip(
                              label: Fmt.setType(entry.key),
                              count: entry.value,
                              selected: _typeFilter == entry.key,
                              onTap: () => setState(() =>
                                  _typeFilter = _typeFilter == entry.key ? null : entry.key),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                    child: PillToggle(
                      options: const ['Newest', 'Oldest', 'A-Z', 'Largest'],
                      selected: _sort.index,
                      onChanged: (i) => setState(() => _sort = SetSort.values[i]),
                    ),
                  ),
                ),
                SliverAsyncView<List<TcgSet>>(
                  value: setsAsync,
                  loadingHeight: 300,
                  onRetry: () => ref.invalidate(setsProvider(game)),
                  isEmpty: (sets) => sets.isEmpty,
                  emptyTitle: 'No ${game.shortLabel} sets yet',
                  emptyMessage:
                      'Pull down to download the catalogue from ${game.dataSource}.',
                  builder: (sets) {
                    final filtered = _applyFilters(sets);
                    if (filtered.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: 60),
                          child: EmptyState(
                            icon: Icons.filter_alt_off_rounded,
                            title: 'No sets match',
                            message: 'Try a different search term or clear the type filter.',
                          ),
                        ),
                      );
                    }
                    return SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
                      sliver: SliverList.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _SetTile(
                            set: filtered[i],
                            owned: ownedBySet[filtered[i].code] ?? 0,
                            index: i,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<TcgSet> _applyFilters(List<TcgSet> sets) {
    final q = _query.trim().toLowerCase();
    var out = sets.where((s) => !s.digital).toList();
    if (_typeFilter != null) {
      out = out.where((s) => s.setType == _typeFilter).toList();
    }
    if (q.isNotEmpty) {
      out = out
          .where((s) =>
              s.name.toLowerCase().contains(q) || s.code.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case SetSort.newest:
        out.sort((a, b) => (b.releasedAt ?? DateTime(1900))
            .compareTo(a.releasedAt ?? DateTime(1900)));
      case SetSort.oldest:
        out.sort((a, b) => (a.releasedAt ?? DateTime(2100))
            .compareTo(b.releasedAt ?? DateTime(2100)));
      case SetSort.name:
        out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case SetSort.size:
        out.sort((a, b) => b.cardCount.compareTo(a.cardCount));
    }
    return out;
  }

  /// The most populous set types, so the filter row stays readable.
  static List<MapEntry<String, int>> _topTypes(Map<String, int> counts) {
    final entries = counts.entries.where((e) => e.value >= 8).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(9).toList();
  }
}

/// Renders a set's symbol, which differs by game: Magic ships monochrome SVGs,
/// Pokémon ships full-colour logos.
class SetGlyph extends StatelessWidget {
  const SetGlyph({super.key, required this.set, this.size = 30});

  final TcgSet set;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    if (set.hasSvgIcon) {
      return SvgPicture.network(
        set.iconSvgUri!,
        width: size * 0.86,
        height: size * 0.86,
        colorFilter: ColorFilter.mode(c.textPrimary, BlendMode.srcIn),
        placeholderBuilder: (_) => Icon(
          Icons.style_outlined,
          size: size * 0.7,
          color: c.textTertiary.withValues(alpha: 0.4),
        ),
      );
    }

    if (set.logoUri != null && set.logoUri!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: set.logoUri!,
        width: size,
        height: size,
        fit: BoxFit.contain,
        placeholder: (_, _) => Icon(
          Icons.style_outlined,
          size: size * 0.7,
          color: c.textTertiary.withValues(alpha: 0.4),
        ),
        errorWidget: (_, _, _) =>
            Icon(Icons.style_outlined, size: size * 0.7, color: c.textTertiary),
      );
    }

    return Icon(Icons.style_outlined, size: size * 0.7, color: c.textTertiary);
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? c.accent.withValues(alpha: 0.22) : c.surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? c.accent.withValues(alpha: 0.6) : c.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: context.t.labelMedium?.copyWith(
                    color: selected ? c.accent : c.textSecondary,
                  ),
                ),
                const SizedBox(width: 6),
                Text('$count',
                    style: context.t.labelSmall?.copyWith(color: c.textTertiary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row in the set list: symbol, name, code, release date, size, owned count.
class _SetTile extends StatelessWidget {
  const _SetTile({required this.set, required this.owned, required this.index});

  final TcgSet set;
  final int owned;
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SetDetailScreen(game: set.game, setCode: set.code),
          ),
        );
      },
      semanticLabel: '${set.name}, ${set.cardCount} cards',
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: Center(child: SetGlyph(set: set, size: 32)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          set.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        set.code.toUpperCase(),
                        style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(Fmt.dateShort(set.releasedAt), style: context.t.bodySmall),
                      Text('  ·  ', style: context.t.bodySmall),
                      Text('${set.cardCount} cards', style: context.t.bodySmall),
                      if (set.series != null) ...[
                        Text('  ·  ', style: context.t.bodySmall),
                        Flexible(
                          child: Text(
                            set.series!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.bodySmall,
                          ),
                        ),
                      ],
                      if (owned > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.positive.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            '$owned owned',
                            style: context.t.labelSmall?.copyWith(color: c.positive),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 220.ms, delay: (index.clamp(0, 12) * 22).ms)
        .slideX(begin: 0.04, end: 0, curve: Curves.easeOutCubic);
  }
}
