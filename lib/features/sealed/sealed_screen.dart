import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/features/sealed/sealed_sheet.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// The collector's sealed product: boxes, packs, bundles and decks.
///
/// Sealed product is not in the card collection and never will be - a box has no
/// finish, no condition and no printing - but it is worth real money and it is
/// exactly the sort of thing an insurer asks about. So it is tracked as its own
/// shelf, with its own total, and the valuation report adds the two together.
class SealedScreen extends ConsumerStatefulWidget {
  /// Creates the sealed screen.
  const SealedScreen({super.key});

  @override
  ConsumerState<SealedScreen> createState() => _SealedScreenState();
}

class _SealedScreenState extends ConsumerState<SealedScreen> {
  late CardGame _game;

  @override
  void initState() {
    super.initState();
    _game = ref.read(activeGameProvider);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final AsyncValue<SealedPortfolio> portfolio = ref.watch(
      sealedPortfolioProvider(_game),
    );
    final SealedPortfolio? data = portfolio.value;

    return Scaffold(
      appBar: AppBar(
        title: Text('Sealed product', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: <Widget>[
          const SectionHeader(
            title: 'The shelf',
            subtitle: 'Boxes, packs and decks, counted and valued',
          ),
          if (data != null && !data.isEmpty) _totals(data),
          AsyncValueView<SealedPortfolio>(
            value: portfolio,
            isEmpty: (SealedPortfolio p) => p.isEmpty,
            emptyMessage: 'Nothing sealed yet',
            emptyIcon: Icons.inventory_2_outlined,
            onRetry: () => ref.invalidate(sealedPortfolioProvider(_game)),
            builder: (SealedPortfolio p) => _list(p),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add sealed product'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Prices come from the price list your companion keeps, and only '
              'when you look a product up: the figure shown is the last one the '
              'app saw, with the day it saw it. A box nothing has priced is '
              'counted in the shelf and left out of the total rather than '
              'guessed at.',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _totals(SealedPortfolio p) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'SEALED VALUE',
            style: context.t.labelSmall?.copyWith(
              color: c.textTertiary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(Fmt.money(p.totalValue), style: context.t.headlineMedium),
          const SizedBox(height: 10),
          _row('Products held', Fmt.count(p.totalItems)),
          _row('Kinds', Fmt.count(p.holdings.length)),
          if (p.totalCost != null) ...<Widget>[
            _row('What they cost', Fmt.money(p.totalCost)),
            _row(
              'Difference',
              Fmt.moneySigned(p.profit),
              colour: c.forDelta(p.profit ?? 0),
            ),
          ] else
            _row('What they cost', 'Not recorded'),
          if (p.unpriced > 0)
            _row(
              'Nothing has priced',
              '${Fmt.count(p.unpriced)} of ${Fmt.count(p.holdings.length)}',
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Color? colour}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(
          label,
          style: context.t.bodySmall?.copyWith(color: context.c.textSecondary),
        ),
        Text(value, style: context.t.titleSmall?.copyWith(color: colour)),
      ],
    ),
  );

  Widget _list(SealedPortfolio p) => _group(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
    child: Column(
      children: <Widget>[
        for (final SealedHolding holding in p.holdings)
          InkWell(
            onTap: () => _edit(holding),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          holding.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodyMedium,
                        ),
                        Text(
                          <String>[
                            '${holding.quantity} x ${holding.category.label}',
                            if (holding.setCode.isNotEmpty)
                              holding.setName.isEmpty
                                  ? holding.setCode
                                  : '${holding.setName} '
                                        '(${holding.setCode})',
                            if (holding.location.isNotEmpty) holding.location,
                          ].join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.labelSmall?.copyWith(
                            color: context.c.textTertiary,
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
                        Fmt.money(holding.totalValue),
                        style: context.t.titleSmall,
                      ),
                      if (holding.valueAsOf != null)
                        Text(
                          Fmt.ago(holding.valueAsOf),
                          style: context.t.labelSmall?.copyWith(
                            color: context.c.textTertiary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  Future<void> _add() async {
    final SealedSheetResult? result =
        await showModalBottomSheet<SealedSheetResult>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SealedSheet(game: _game),
        );
    final SealedHolding? draft = result?.holding;
    if (draft == null || !mounted) return;
    await ref.read(sealedDaoProvider).insert(draft);
    ref.read(sealedRevisionProvider.notifier).bump();
    if (!mounted) return;
    _snack('Added ${draft.quantity} x ${draft.name}.');
  }

  Future<void> _edit(SealedHolding holding) async {
    final SealedSheetResult? result =
        await showModalBottomSheet<SealedSheetResult>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SealedSheet(game: _game, holding: holding),
        );
    // Dismissal is neither a save nor a delete: the sheet has to say which of
    // the three happened, or swiping it away would remove a box.
    if (result == null || !mounted) return;
    final dao = ref.read(sealedDaoProvider);
    if (result.deleted) {
      await dao.delete(holding.id!);
      ref.read(sealedRevisionProvider.notifier).bump();
      if (!mounted) return;
      _snack('Removed ${holding.name}.');
      return;
    }
    final SealedHolding? edited = result.holding;
    if (edited == null) return;
    await dao.update(edited);
    ref.read(sealedRevisionProvider.notifier).bump();
    if (!mounted) return;
    _snack('Saved ${edited.name}.');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _group({required Widget child, EdgeInsetsGeometry? padding}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          radius: 20,
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      );
}
