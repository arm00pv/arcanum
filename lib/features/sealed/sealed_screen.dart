import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/data/sealed/sealed_refresh.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:arcanum/features/sealed/box_ev_screen.dart';
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
  bool _refreshing = false;

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
    // What the boxes on the shelf are worth opened. Null while it loads, which
    // is a card that is simply absent rather than one that says zero.
    final BoxShelf? shelf = ref.watch(boxShelfProvider(_game)).value;

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
          if (shelf != null && !shelf.isEmpty && data != null && !data.isEmpty)
            _opened(shelf),
          AsyncValueView<SealedPortfolio>(
            value: portfolio,
            isEmpty: (SealedPortfolio p) => p.isEmpty,
            emptyMessage: 'Nothing sealed yet',
            emptyIcon: Icons.inventory_2_outlined,
            onRetry: () => ref.invalidate(sealedPortfolioProvider(_game)),
            builder: (SealedPortfolio p) => _list(p, shelf),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add sealed product'),
            ),
          ),
          if (data != null && data.holdings.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: OutlinedButton.icon(
                onPressed: _refreshing ? null : () => _refresh(data),
                icon: _refreshing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 18),
                label: Text(
                  _refreshing ? 'Asking the price list...' : 'Refresh prices',
                ),
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

  /// The shelf's answer for one row, matched on the row it came from.
  BoxOpening? _openingOf(BoxShelf? shelf, SealedHolding holding) {
    if (shelf == null || holding.id == null) return null;
    for (final BoxOpening opening in shelf.openings) {
      if (opening.holdingId == holding.id) return opening;
    }
    return null;
  }

  /// What the boxes are worth opened against what they are worth shut.
  ///
  /// The two figures come from the same boxes on purpose: a total that covers
  /// one set of boxes subtracted from a total that covers another is how a
  /// valuation ends up wrong without ever looking wrong, so the comparison is
  /// taken over the boxes where both sides are known and says how many that is.
  Widget _opened(BoxShelf shelf) {
    final c = context.c;
    final unvalued = shelf.unvalued;
    // Counted in boxes rather than in rows: a row of two displays is two boxes,
    // and the breakdown beside this line counts them the same way.
    var unvaluedBoxes = 0;
    for (final BoxOpening opening in unvalued) {
      unvaluedBoxes += opening.quantity;
    }
    final byBlocker = <BoxBlocker, int>{};
    for (final BoxOpening opening in unvalued) {
      final blocker = opening.blocker;
      if (blocker == null) continue;
      byBlocker[blocker] = (byBlocker[blocker] ?? 0) + opening.quantity;
    }
    final costs = shelf.cost;

    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'OPENED OR KEPT',
            style: context.t.labelSmall?.copyWith(
              color: c.textTertiary,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            shelf.hasAnswer
                ? 'What these boxes are worth as cards, against what they sell '
                      'for.'
                : 'What these boxes are worth as cards. None can be valued both '
                      'ways yet.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (shelf.hasAnswer) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: StatTile(
                    label: 'Kept sealed',
                    value: Fmt.money(shelf.sealedBoth),
                    icon: Icons.inventory_2_outlined,
                    caption: shelf.bothCount == 1
                        ? 'The one box with both'
                        : 'The ${shelf.bothCount} boxes with both',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: StatTile(
                    label: 'Opened',
                    value: Fmt.money(shelf.openedBoth),
                    icon: Icons.all_inbox_rounded,
                    caption: 'What the cards in them add up to',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row(
              'Opening pays better by',
              Fmt.moneySigned(shelf.difference),
              colour: c.forDelta(shelf.difference),
            ),
            if (costs != null)
              _row(
                'Against what they cost',
                Fmt.moneySigned(shelf.againstCost),
              ),
            const SizedBox(height: 6),
            Text(
              shelf.openingPays
                  ? 'On these boxes, the cards inside are worth more than the '
                        'boxes sell for.'
                  : 'On these boxes, the boxes sell for more than the cards '
                        'inside are worth.',
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ],
          if (unvalued.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              unvaluedBoxes == 1
                  ? 'One box is not counted, because its value as cards is '
                        'unknown:'
                  : '${Fmt.count(unvaluedBoxes)} boxes are not counted, '
                        'because their value as cards is unknown:',
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: 6),
            for (final MapEntry<BoxBlocker, int> entry in byBlocker.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${Fmt.count(entry.value)} × ${entry.key.label}',
                  style: context.t.bodySmall?.copyWith(
                    // The one thing the collector can fix is the one thing that
                    // is not greyed out.
                    color: entry.key == BoxBlocker.noComposition
                        ? c.warning
                        : c.textTertiary,
                  ),
                ),
              ),
            if (shelf.unstated.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BoxEvScreen(
                        game: _game,
                        setCode: shelf.unstated.first.setCode,
                        productId: shelf.unstated.first.productId,
                        productName: shelf.unstated.first.name,
                        heldPrice: shelf.unstated.first.price,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.calculate_outlined, size: 18),
                  label: Text(
                    shelf.unstated.length == 1
                        ? 'State what that box holds'
                        : 'State what those boxes hold',
                  ),
                ),
              ),
            ],
          ],
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

  Widget _list(SealedPortfolio p, BoxShelf? shelf) => _group(
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
                      // What this box is worth opened, beside what it sells
                      // for. Only boxes that can be valued both ways get the
                      // line: a blank one would read as nothing, not as
                      // unknown.
                      if (_openingOf(shelf, holding)?.opened != null)
                        Text(
                          'opened '
                          '${Fmt.money(_openingOf(shelf, holding)!.opened)}',
                          style: context.t.labelSmall?.copyWith(
                            color: context.c.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  // A box of a set the app has cards for can be compared with
                  // the cards inside it, which is a different question from
                  // what the box sells for.
                  if (holding.setCode.isNotEmpty &&
                      (holding.category == SealedCategory.boosterBox ||
                          holding.category == SealedCategory.bundle))
                    IconButton(
                      tooltip: 'Box value',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BoxEvScreen(
                            game: holding.game,
                            setCode: holding.setCode,
                            productId: holding.productId,
                            productName: holding.name,
                            heldPrice: holding.unitValue,
                          ),
                        ),
                      ),
                      icon: const Icon(Icons.calculate_outlined, size: 20),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  /// Asks the price list what the shelf is worth now.
  ///
  /// A figure written once and never revisited is a figure that ages in place,
  /// which is the one thing a valuation must not do quietly.
  Future<void> _refresh(SealedPortfolio portfolio) async {
    setState(() => _refreshing = true);
    try {
      final settings = ref.read(settingsProvider);
      final SealedRefresh report = await refreshSealedPrices(
        game: _game,
        holdings: portfolio.holdings,
        source: CompanionSealedSource(endpoint: settings.historyEndpoint),
        dao: ref.read(sealedDaoProvider),
      );
      ref.read(sealedRevisionProvider.notifier).bump();
      if (!mounted) return;
      _snack(report.summary);
    } catch (error) {
      if (!mounted) return;
      _snack('Could not refresh: $error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

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
