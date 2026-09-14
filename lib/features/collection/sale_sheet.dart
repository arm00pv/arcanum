import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// Records a sale out of one stack.
///
/// The point of the sheet is the three numbers under the fields: what will
/// arrive, what the copies cost, and what that leaves. They are worked out with
/// the same first-in-first-out match the recorder uses, so the figure shown
/// before the button is pressed is the figure that gets stored.
///
/// The sheet can also take a negative view of itself: when a stack has no
/// purchase price behind it, the cost and gain lines say so instead of showing
/// a zero, because a zero on a tax sheet is a claim that the cards were free.
Future<void> showSaleSheet(
  BuildContext context,
  WidgetRef ref,
  TcgCard card,
  CollectionEntry entry,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) => _SaleSheet(card: card, entry: entry),
  );
}

class _SaleSheet extends ConsumerStatefulWidget {
  const _SaleSheet({required this.card, required this.entry});

  final TcgCard card;
  final CollectionEntry entry;

  @override
  ConsumerState<_SaleSheet> createState() => _SaleSheetState();
}

class _SaleSheetState extends ConsumerState<_SaleSheet> {
  late final TextEditingController _price;
  late final TextEditingController _fees;
  late final TextEditingController _platform;
  late final TextEditingController _note;
  late int _quantity;
  late DateTime _soldOn;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final market = widget.card.prices.priceFor(widget.entry.finish);
    _price = TextEditingController(
      text: market == null ? '' : market.toStringAsFixed(2),
    );
    _fees = TextEditingController();
    _platform = TextEditingController();
    _note = TextEditingController();
    _quantity = 1;
    _soldOn = DateTime.now();
  }

  @override
  void dispose() {
    _price.dispose();
    _fees.dispose();
    _platform.dispose();
    _note.dispose();
    super.dispose();
  }

  double get _unitPrice => double.tryParse(_price.text.trim()) ?? 0;
  double get _feeValue => double.tryParse(_fees.text.trim()) ?? 0;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _soldOn,
      firstDate: DateTime(1993),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _soldOn = picked);
  }

  Future<void> _record() async {
    if (_busy) return;
    final entryId = widget.entry.id;
    if (entryId == null) return;
    setState(() => _busy = true);
    final game = widget.card.game;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(bootstrapProvider)
          .collectionFor(game)
          .recordSale(
            entry: widget.entry,
            quantity: _quantity,
            unitPrice: _unitPrice,
            soldOn: _soldOn,
            fees: _feeValue,
            platform: _platform.text.trim(),
            note: _note.text.trim(),
          );
      ref.read(costBasisRevisionProvider.notifier).bump();
      ref.invalidate(collectionOverviewProvider(game));
      ref.invalidate(ownedQuantityProvider(game));
      ref.invalidate(gameSummariesProvider);
      ref.invalidate(cardEntriesProvider((game: game, id: widget.card.id)));
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Sold $_quantity '
            '${_quantity == 1 ? 'copy' : 'copies'} for '
            '${Fmt.money(_unitPrice * _quantity - _feeValue)}',
          ),
        ),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = widget.card.game;
    final entry = widget.entry;
    final basis = ref.watch(cardCostBasisProvider((game, widget.card.id)));
    // The preview is the same match the recorder runs, so what the sheet says
    // is what the ledger will say.
    final lots = basis.value?.lots ?? const <CardLot>[];
    final preview = matchFifo(lots, _quantity);
    final cost = preview.cost;
    final proceeds = _unitPrice * _quantity - _feeValue;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.hairlineStrong,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text('Record a sale', style: context.t.headlineSmall),
              const SizedBox(height: 2),
              Text(
                '${widget.card.name} · ${entry.finish.label} · '
                '${entry.condition.label}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall?.copyWith(color: c.textSecondary),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: _Field(
                      label: 'Quantity',
                      child: Row(
                        children: <Widget>[
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: _quantity > 1
                                ? () => setState(() => _quantity--)
                                : null,
                            icon: const Icon(Icons.remove_rounded, size: 18),
                          ),
                          Text('$_quantity', style: context.t.titleMedium),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            onPressed: _quantity < entry.quantity
                                ? () => setState(() => _quantity++)
                                : null,
                            icon: const Icon(Icons.add_rounded, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: 'Sold for, each',
                      child: TextField(
                        controller: _price,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          prefixText: r'$',
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: _Field(
                      label: 'Fees',
                      child: TextField(
                        controller: _fees,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'postage, commission',
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: 'Sold on',
                      child: OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.event_rounded, size: 16),
                        label: Text(Fmt.dateShort(_soldOn)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Field(
                label: 'Where',
                child: TextField(
                  controller: _platform,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'a marketplace, a shop, a person',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _Field(
                label: 'Note',
                child: TextField(
                  controller: _note,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'optional',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: <Widget>[
                    _Line(
                      label: 'Proceeds',
                      value: Fmt.money(proceeds),
                      strong: true,
                    ),
                    const SizedBox(height: 6),
                    _Line(
                      label: 'Cost basis',
                      value: cost == null ? 'not recorded' : Fmt.money(cost),
                      muted: cost == null,
                    ),
                    const SizedBox(height: 6),
                    _Line(
                      label: cost == null ? 'Gain' : 'Gain',
                      value: cost == null
                          ? 'unknown'
                          : Fmt.moneySigned(proceeds - cost),
                      muted: cost == null,
                      accent: cost == null ? null : proceeds - cost >= 0,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      cost == null
                          ? 'This stack has no purchase price behind it, so '
                                'Arcanum will not invent one: the sale is '
                                'recorded, and the tax sheet reports it as an '
                                'unknown cost rather than as a gain.'
                          : 'Matched against ${preview.matches.length} '
                                '${preview.matches.length == 1 ? 'purchase' : 'purchases'}, '
                                'oldest first.',
                      style: context.t.labelSmall?.copyWith(
                        color: c.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy || _unitPrice <= 0 ? null : _record,
                  icon: const Icon(Icons.sell_rounded, size: 18),
                  label: Text(_busy ? 'Recording...' : 'Record the sale'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label.toUpperCase(),
          style: context.t.labelSmall?.copyWith(
            color: c.textTertiary,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.label,
    required this.value,
    this.strong = false,
    this.muted = false,
    this.accent,
  });

  final String label;
  final String value;
  final bool strong;
  final bool muted;
  final bool? accent;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final colour = muted
        ? c.textTertiary
        : accent == null
        ? null
        : (accent! ? c.positive : c.negative);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ),
        Text(
          value,
          style: (strong ? context.t.titleMedium : context.t.bodyMedium)
              ?.copyWith(color: colour),
        ),
      ],
    );
  }
}
