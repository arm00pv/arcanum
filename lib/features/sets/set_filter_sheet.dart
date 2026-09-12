import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/features/sets/printing_groups.dart';
import 'package:arcanum/features/sets/set_filters.dart';
import 'package:arcanum/widgets/glass.dart';

/// Asks the collector how to narrow a set, and hands back what they chose.
///
/// Returns null when the sheet is dismissed without a decision, so the caller
/// keeps whatever it already had rather than being handed a default.
Future<SetFilter?> showSetFilterSheet(
  BuildContext context, {
  required SetFilter current,
  required List<PrintingSlot> slots,
}) {
  return showModalBottomSheet<SetFilter>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _SetFilterSheet(initial: current, slots: slots),
  );
}

class _SetFilterSheet extends StatefulWidget {
  const _SetFilterSheet({required this.initial, required this.slots});

  final SetFilter initial;
  final List<PrintingSlot> slots;

  @override
  State<_SetFilterSheet> createState() => _SetFilterSheetState();
}

class _SetFilterSheetState extends State<_SetFilterSheet> {
  late SetFilter _draft = widget.initial;

  /// The top of the price slider: the set's dearest card, rounded up.
  ///
  /// Fixed for the life of the sheet rather than following the draft, so the
  /// handles do not jump under the finger as the window narrows.
  late final double _ceiling = _computeCeiling();

  double _computeCeiling() {
    var dearest = 0.0;
    for (final slot in widget.slots) {
      final high = slot.highestPrice;
      if (high != null && high > dearest) dearest = high;
    }
    return niceCeil(dearest);
  }

  int get _shown => widget.slots.where(_draft.matches).length;

  /// How many slots a price window alone would leave.
  int _countForWindow(PriceWindow window) =>
      widget.slots.where((slot) => window.matches(slot)).length;

  /// The window the slider currently represents.
  PriceWindow get _sliderWindow => _draft.price ?? const PriceWindow();

  double get _low => _sliderWindow.min ?? 0;

  double get _high => _sliderWindow.max ?? _ceiling;

  void _setRange(double low, double high) {
    // A handle pulled to either end means "no bound on that side", which is how
    // the collector reads it: pushing the top handle to the far right is asking
    // for everything, not for a ceiling at the dearest card in the set.
    final window = PriceWindow(
      min: low <= 0 ? null : low,
      max: high >= _ceiling ? null : high,
    );
    setState(() => _draft = _draft.withPrice(window.isEmpty ? null : window));
  }

  /// Prices a slider handle can land on, coarser towards the top of the range.
  ///
  /// Two decimals everywhere would let a 900 dollar handle move in single
  /// cents - travel nobody can aim - while a set holding both a 681 dollar card
  /// and a 2 dollar one needs the same slider to be usable at both ends.
  double _snap(double value) {
    if (value >= 100) return value.roundToDouble();
    if (value >= 10) return (value * 2).roundToDouble() / 2;
    return (value * 100).roundToDouble() / 100;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final facets = rarityFacets(widget.slots);
    final selectedBand =
        _draft.price == null ? null : PriceBand.matching(_draft.price!);
    final unpricedShown = _draft.price?.unpriced ?? false;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: GlassCard(
            radius: 22,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Filter cards', style: context.t.titleMedium),
                    ),
                    Text(
                      '$_shown of ${widget.slots.length}',
                      style: context.t.labelMedium?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _Section(
                          title: 'Price',
                          note: 'A card matches on any of its versions',
                          children: <Widget>[
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                _ChoiceChip(
                                  label: 'Any price',
                                  count: widget.slots.length,
                                  selected: _draft.price == null,
                                  onTap: () => setState(
                                    () => _draft = _draft.withPrice(null),
                                  ),
                                ),
                                for (final band in PriceBand.values)
                                  _ChoiceChip(
                                    label: band.label,
                                    count: _countForWindow(band.window),
                                    selected: selectedBand == band,
                                    onTap: () => setState(
                                      () =>
                                          _draft = _draft.withPrice(band.window),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            _RangeRow(
                              low: _low,
                              high: _high,
                              ceiling: _ceiling,
                              unpriced: unpricedShown,
                              onChanged: (range) =>
                                  _setRange(_snap(range.start), _snap(range.end)),
                            ),
                          ],
                        ),
                        if (facets.isNotEmpty)
                          _Section(
                            title: 'Rarity',
                            note: 'As the provider prints it',
                            children: <Widget>[
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: <Widget>[
                                  for (final facet in facets)
                                    _ChoiceChip(
                                      label: facet.rarity,
                                      count: facet.count,
                                      selected:
                                          _draft.rarities.contains(facet.rarity),
                                      onTap: () => setState(
                                        () => _draft =
                                            _draft.toggleRarity(facet.rarity),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        _Section(
                          title: 'Order',
                          note: 'Unpriced cards always sort last',
                          children: <Widget>[
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: <Widget>[
                                for (final order in SetSort.values)
                                  _ChoiceChip(
                                    label: order.label,
                                    selected: _draft.sort == order,
                                    onTap: () => setState(
                                      () => _draft = _draft.withSort(order),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: _draft.isActive
                          ? () => setState(() => _draft = const SetFilter())
                          : null,
                      child: const Text('Reset'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(_draft),
                      child: Text(
                        _shown == 1 ? 'Show 1 card' : 'Show $_shown cards',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A titled group of controls.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.note});

  final String title;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Text(
                title.toUpperCase(),
                style: context.t.labelSmall?.copyWith(
                  color: c.textSecondary,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (note != null) ...<Widget>[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// The live price range, with both ends readable as money.
class _RangeRow extends StatelessWidget {
  const _RangeRow({
    required this.low,
    required this.high,
    required this.ceiling,
    required this.unpriced,
    required this.onChanged,
  });

  final double low;
  final double high;
  final double ceiling;
  final bool unpriced;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bottom = low <= 0 ? 'Any' : Fmt.money(low);
    final top = high >= ceiling ? 'Any' : Fmt.money(high);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              'Range',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
            const Spacer(),
            Text(
              '$bottom - $top',
              style: context.t.labelMedium?.copyWith(color: c.textPrimary),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            rangeThumbShape:
                const RoundRangeSliderThumbShape(enabledThumbRadius: 9),
          ),
          child: RangeSlider(
            min: 0,
            max: ceiling,
            values: RangeValues(low.clamp(0, ceiling), high.clamp(low, ceiling)),
            onChanged: onChanged,
          ),
        ),
        if (unpriced)
          Text(
            'Cards the provider prices at nothing are included too.',
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
      ],
    );
  }
}

/// One selectable option, with the number of cards behind it.
class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// How many cards the option would leave, when that is known.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Material(
      color: selected ? c.accent.withValues(alpha: 0.22) : c.surfaceRaised,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: selected ? c.accent.withValues(alpha: 0.65) : c.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                label,
                style: context.t.labelMedium?.copyWith(
                  color: selected ? c.accent : c.textPrimary,
                ),
              ),
              if (count != null) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: context.t.labelSmall?.copyWith(
                    color: selected
                        ? c.accent.withValues(alpha: 0.85)
                        : c.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
