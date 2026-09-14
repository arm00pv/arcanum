import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// What the sealed sheet came back with.
///
/// Three outcomes, not two: saved, deleted, and dismissed. A sheet that returned
/// null for both "delete" and "never mind" would delete a box every time somebody
/// swiped it away.
class SealedSheetResult {
  /// The collector saved a holding.
  const SealedSheetResult.saved(this.holding) : deleted = false;

  /// The collector deleted the holding being edited.
  const SealedSheetResult.deleted() : holding = null, deleted = true;

  /// The holding as it should now be stored, or null when it was deleted.
  final SealedHolding? holding;

  /// Whether this result means deletion.
  final bool deleted;
}

/// Adds a box, a pack or a deck to the shelf, or edits one already there.
///
/// The price lookup is a convenience and never a requirement: a collector with
/// no companion, or with a product no price list carries, types the name and what
/// they paid and gets the same holding with the same arithmetic.
class SealedSheet extends ConsumerStatefulWidget {
  /// Creates the sheet.
  const SealedSheet({super.key, required this.game, this.holding});

  /// Which collection the holding belongs to.
  final CardGame game;

  /// The holding being edited, or null when adding one.
  final SealedHolding? holding;

  @override
  ConsumerState<SealedSheet> createState() => _SealedSheetState();
}

class _SealedSheetState extends ConsumerState<SealedSheet> {
  late final TextEditingController _name;
  late final TextEditingController _cost;
  late final TextEditingController _value;
  late final TextEditingController _location;
  late final TextEditingController _note;

  late String _setCode;
  late String _setName;
  late SealedCategory _category;
  late int _quantity;
  late String _productId;
  DateTime? _valueAsOf;

  /// Whether prices have been asked for, so the offer list can be shown.
  bool _looking = false;

  @override
  void initState() {
    super.initState();
    final SealedHolding? h = widget.holding;
    _name = TextEditingController(text: h?.name ?? '');
    _cost = TextEditingController(
      text: h?.unitCost == null ? '' : h!.unitCost!.toStringAsFixed(2),
    );
    _value = TextEditingController(
      text: h?.unitValue == null ? '' : h!.unitValue!.toStringAsFixed(2),
    );
    _location = TextEditingController(text: h?.location ?? '');
    _note = TextEditingController(text: h?.note ?? '');
    _setCode = h?.setCode ?? '';
    _setName = h?.setName ?? '';
    _category = h?.category ?? SealedCategory.boosterBox;
    _quantity = h?.quantity ?? 1;
    _productId = h?.productId ?? '';
    _valueAsOf = h?.valueAsOf;
  }

  @override
  void dispose() {
    _name.dispose();
    _cost.dispose();
    _value.dispose();
    _location.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bool editing = widget.holding != null;
    final SetRef key = (game: widget.game, code: _setCode);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: GlassCard(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      editing ? 'Edit sealed product' : 'Add sealed product',
                      style: context.t.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Set',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: _pickSet,
                icon: const Icon(Icons.search_rounded, size: 18),
                label: Text(
                  _setCode.isEmpty
                      ? 'Choose a set'
                      : '${_setName.isEmpty ? _setCode : _setName} '
                            '($_setCode)',
                ),
              ),
              const SizedBox(height: 16),
              if (_setCode.isNotEmpty && !_looking)
                OutlinedButton.icon(
                  onPressed: () => setState(() => _looking = true),
                  icon: const Icon(Icons.sell_outlined, size: 18),
                  label: const Text('Look up prices for this set'),
                ),
              if (_looking && _setCode.isNotEmpty) _offers(key),
              const SizedBox(height: 8),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Product',
                  hintText: 'Bloomburrow Play Booster Box',
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Kind',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final SealedCategory category in SealedCategory.values)
                    ChoiceChip(
                      label: Text(category.label),
                      selected: _category == category,
                      onSelected: (_) => setState(() => _category = category),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _cost,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Paid each',
                        prefixText: r'$ ',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _value,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Worth each',
                        prefixText: r'$ ',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Text('How many', style: context.t.bodyMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: 'One fewer',
                    onPressed: _quantity > 1
                        ? () => setState(() => _quantity -= 1)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                  ),
                  Text('$_quantity', style: context.t.titleMedium),
                  IconButton(
                    tooltip: 'One more',
                    onPressed: () => setState(() => _quantity += 1),
                    icon: const Icon(Icons.add_circle_outline_rounded),
                  ),
                ],
              ),
              TextField(
                controller: _location,
                decoration: const InputDecoration(
                  labelText: 'Where it is kept',
                  hintText: 'Top shelf, storage box 2',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  hintText: 'Bought sealed, one corner dented',
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  if (editing)
                    TextButton.icon(
                      onPressed: () =>
                          Navigator.of(context)
                              .pop(const SealedSheetResult.deleted()),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(foregroundColor: c.negative),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _save,
                    child: Text(editing ? 'Save' : 'Add'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The products a price list has for the chosen set.
  Widget _offers(SetRef key) {
    final c = context.c;
    final AsyncValue<List<SealedOffer>> offers = ref.watch(
      sealedOffersProvider(key),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AsyncValueView<List<SealedOffer>>(
        value: offers,
        isEmpty: (List<SealedOffer> list) => list.isEmpty,
        emptyMessage:
            'Nothing came back from the price list for this set. Type the '
            'product in instead.',
        emptyIcon: Icons.cloud_off_rounded,
        loadingHeight: 90,
        onRetry: () => ref.invalidate(sealedOffersProvider(key)),
        builder: (List<SealedOffer> list) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Pick the product',
              style: context.t.labelSmall?.copyWith(color: c.textTertiary),
            ),
            const SizedBox(height: 6),
            for (final SealedOffer offer in list.take(12))
              InkWell(
                onTap: () => setState(() {
                  _name.text = offer.name;
                  _category = offer.category;
                  _productId = offer.productId;
                  if (offer.market != null) {
                    _value.text = offer.market!.toStringAsFixed(2);
                    _valueAsOf = offer.asOf ?? DateTime.now();
                  }
                  _looking = false;
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          offer.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodySmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        Fmt.money(offer.market),
                        style: context.t.labelSmall?.copyWith(color: c.accent),
                      ),
                    ],
                  ),
                ),
              ),
            if (list.length > 12)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'and ${list.length - 12} more; narrow it down by typing the '
                  'name yourself.',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
            if (offers.value?.isNotEmpty ?? false)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Market prices from the price list your companion keeps, not '
                  'offers to buy at.',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSet() async {
    final TcgSet? set = await showModalBottomSheet<TcgSet>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SetPickerSheet(game: widget.game),
    );
    if (set == null || !mounted) return;
    setState(() {
      _setCode = set.code;
      _setName = set.name;
      _looking = false;
    });
  }

  void _save() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('A product needs a name.')));
      return;
    }
    final SealedHolding holding = SealedHolding(
      id: widget.holding?.id,
      game: widget.game,
      setCode: _setCode,
      setName: _setName,
      name: name,
      category: _category,
      quantity: _quantity,
      unitCost: _parse(_cost.text),
      unitValue: _parse(_value.text),
      valueAsOf:
          _valueAsOf ??
          (_parse(_value.text) == null ? null : widget.holding?.valueAsOf),
      location: _location.text.trim(),
      note: _note.text.trim(),
      productId: _productId,
    );
    Navigator.of(context).pop(SealedSheetResult.saved(holding));
  }

  static double? _parse(String text) {
    final value = double.tryParse(text.trim());
    if (value == null || value <= 0) return null;
    return value;
  }
}

/// Picks a set out of the catalogue the app already holds.
class _SetPickerSheet extends ConsumerStatefulWidget {
  const _SetPickerSheet({required this.game});

  final CardGame game;

  @override
  ConsumerState<_SetPickerSheet> createState() => _SetPickerSheetState();
}

class _SetPickerSheetState extends ConsumerState<_SetPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final AsyncValue<List<TcgSet>> sets = ref.watch(setsProvider(widget.game));
    final List<TcgSet> all = sets.value ?? const <TcgSet>[];
    final String q = _query.trim().toLowerCase();
    final List<TcgSet> matches = q.isEmpty
        ? all.take(40).toList()
        : all
              .where(
                (TcgSet s) =>
                    s.name.toLowerCase().contains(q) ||
                    s.code.toLowerCase() == q ||
                    s.code.toLowerCase().startsWith(q),
              )
              .take(60)
              .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: GlassCard(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Which set', style: context.t.titleMedium),
              const SizedBox(height: 10),
              TextField(
                autofocus: true,
                onChanged: (String v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Bloomburrow, or BLB',
                  prefixIcon: Icon(Icons.search_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: AsyncValueView<List<TcgSet>>(
                  value: sets,
                  isEmpty: (List<TcgSet> list) => list.isEmpty,
                  emptyMessage:
                      'No sets are cached for this game yet. Download one from '
                      'the Sets tab first.',
                  emptyIcon: Icons.layers_outlined,
                  onRetry: () => ref.invalidate(setsProvider(widget.game)),
                  builder: (List<TcgSet> _) => ListView.builder(
                    itemCount: matches.length,
                    itemBuilder: (BuildContext context, int i) {
                      final TcgSet set = matches[i];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(set.name),
                        subtitle: Text(
                          '${set.code.toUpperCase()}  ·  '
                          '${Fmt.count(set.cardCount)} cards',
                          style: context.t.labelSmall?.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                        onTap: () => Navigator.of(context).pop(set),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
