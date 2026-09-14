import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/portfolio/realised.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// What the collection has actually made, by tax year.
///
/// The purchases screen answers "what is this worth against what I paid", which
/// is a question about the shelf. This answers the other one: what left the
/// shelf, for how much, and what it cost - the question a tax year asks, and
/// the reason a sale is recorded rather than a stack quietly deleted.
class RealisedScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const RealisedScreen({super.key});

  @override
  ConsumerState<RealisedScreen> createState() => _RealisedScreenState();
}

class _RealisedScreenState extends ConsumerState<RealisedScreen> {
  int? _selected;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final async = ref.watch(realisedProvider(game));
    final years = async.value?.years ?? const <RealisedYear>[];
    final year = years.isEmpty ? null : _pick(years);

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
                      Text('Realised', style: context.t.titleLarge),
                      Text(
                        year == null
                            ? 'Nothing sold yet in ${game.shortLabel}'
                            : year.hasCostBasis
                            ? '${year.year} · ${Fmt.moneySigned(year.gain)} on '
                                  '${Fmt.count(year.sales)} '
                                  '${year.sales == 1 ? 'sale' : 'sales'}'
                            : '${year.year} · ${Fmt.count(year.sales)} '
                                  '${year.sales == 1 ? 'sale' : 'sales'}, no '
                                  'cost basis recorded',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.bodySmall,
                      ),
                    ],
                  ),
                  actions: <Widget>[
                    IconButton(
                      tooltip: 'Export the tax year as a spreadsheet',
                      onPressed: year == null || _busy
                          ? null
                          : () => _export(year),
                      icon: const Icon(Icons.ios_share_rounded),
                    ),
                  ],
                ),
              ),
              SliverAsyncView<Realised>(
                value: async,
                loadingHeight: 320,
                onRetry: () => ref.invalidate(realisedProvider(game)),
                isEmpty: (Realised r) => r.isEmpty,
                emptyIcon: Icons.receipt_long_outlined,
                emptyTitle: 'Nothing sold yet',
                emptyMessage:
                    'When you sell a card, record the sale from the card '
                    'itself. Arcanum matches it against the purchases it came '
                    'out of, and this screen becomes the tax year: what '
                    'arrived, what it cost and what it made.',
                builder: (Realised r) {
                  final year = _pick(r.years);
                  return SliverList(
                    delegate: SliverChildListDelegate(<Widget>[
                      if (r.years.length > 1)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Wrap(
                            spacing: 8,
                            children: <Widget>[
                              for (final y in r.years)
                                ChoiceChip(
                                  label: Text('${y.year}'),
                                  selected: y.year == year.year,
                                  onSelected: (_) =>
                                      setState(() => _selected = y.year),
                                ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: _YearCard(year: year),
                      ),
                      SectionHeader(
                        title: 'Sales',
                        subtitle: year.rows.length == 1
                            ? '1 sale'
                            : '${year.rows.length} sales',
                      ),
                      for (final row in year.rows)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: _SaleCard(row: row, onUndo: () => _undo(row)),
                        ),
                      const SizedBox(height: 28),
                    ]),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The year on screen: the newest, unless another one has been picked.
  RealisedYear _pick(List<RealisedYear> years) => years.firstWhere(
    (RealisedYear y) => y.year == (_selected ?? years.first.year),
    orElse: () => years.first,
  );

  Future<void> _undo(SaleRow row) async {
    final game = ref.read(activeGameProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Undo this sale?'),
        content: const Text(
          'The copies go back into the collection, and the purchases they came '
          'out of come back with them. The sale leaves the tax year.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Undo'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(bootstrapProvider).collectionFor(game).undoSale(row.sale);
    ref.read(costBasisRevisionProvider.notifier).bump();
    ref.invalidate(collectionOverviewProvider(game));
    ref.invalidate(ownedQuantityProvider(game));
    ref.invalidate(gameSummariesProvider);
  }

  Future<void> _export(RealisedYear year) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final csvText = salesCsv(year.rows);
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}arcanum-realised-${year.year}.csv';
      await File(path).writeAsString(csvText, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(path, mimeType: 'text/csv')],
          subject: 'Arcanum ${year.year} card sales',
        ),
      );
      messenger.showSnackBar(
        SnackBar(content: Text('Exported ${year.rows.length} sales.')),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not export: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The year's totals.
class _YearCard extends StatelessWidget {
  const _YearCard({required this.year});

  final RealisedYear year;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('REALISED IN ${year.year}', style: context.t.labelSmall),
          const SizedBox(height: 6),
          Text(
            year.hasCostBasis ? Fmt.moneySigned(year.gain) : 'unknown',
            style: year.hasCostBasis
                ? context.t.displaySmall?.copyWith(
                    color: year.gain >= 0 ? c.positive : c.negative,
                  )
                : context.t.displaySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _Total(
                  label: 'Proceeds',
                  value: Fmt.money(year.proceeds),
                ),
              ),
              Expanded(
                child: _Total(
                  label: 'Cost basis',
                  value: year.hasCostBasis
                      ? Fmt.money(year.cost)
                      : 'not recorded',
                ),
              ),
              Expanded(
                child: _Total(label: 'Copies', value: Fmt.count(year.copies)),
              ),
            ],
          ),
          if (!year.everyCostKnown) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline_rounded, size: 16, color: c.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    year.unknownCost == 1
                        ? 'One sale has no cost basis, so its gain is not in '
                              'the total. Record what those cards cost and the '
                              'figure completes.'
                        : '${year.unknownCost} sales have no cost basis, so '
                              'their gains are not in the total. Record what '
                              'those cards cost and the figure completes.',
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: context.t.labelSmall?.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: 2),
        Text(value, style: context.t.titleMedium),
      ],
    );
  }
}

/// One recorded sale.
class _SaleCard extends StatelessWidget {
  const _SaleCard({required this.row, required this.onUndo});

  final SaleRow row;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final sale = row.sale;
    final gain = row.gain;
    final where = <String>[
      if (sale.platform.isNotEmpty) sale.platform,
      if (sale.note.isNotEmpty) sale.note,
    ].join('  ·  ');
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.t.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  '${Fmt.dateShort(sale.soldOn)}  ·  ${sale.quantity} × '
                  '${Fmt.money(sale.unitPrice)}'
                  '${sale.fees > 0 ? '  ·  fees ${Fmt.money(sale.fees)}' : ''}'
                  '${row.setCode.isEmpty ? '' : '  ·  ${row.setCode.toUpperCase()}'}',
                  maxLines: 2,
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
                if (where.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.t.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                gain == null ? 'cost unknown' : Fmt.moneySigned(gain),
                style:
                    (gain == null ? context.t.labelSmall : context.t.titleSmall)
                        ?.copyWith(
                          color: gain == null
                              ? c.textTertiary
                              : (gain >= 0 ? c.positive : c.negative),
                        ),
              ),
              const SizedBox(height: 2),
              Text(
                'in ${Fmt.money(row.proceeds)}',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ],
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Undo this sale',
            onPressed: onUndo,
            icon: const Icon(Icons.undo_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
