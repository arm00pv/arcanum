import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/glass.dart';

/// Opens the "add to collection" sheet for a printing.
///
/// The sheet is scoped to the card's own game: [CardGame.finishes] decides
/// which finishes can be picked, [CardGame.conditions] which grades, and the
/// entry is written through that game's collection repository. Nothing is ever
/// added to another game's vault.
///
/// Returns true when something was added, so the caller can refresh.
///
/// This sheet only ever *adds*. Editing an entry that already exists - its
/// grade, its binder, what was paid for it - means loading that row and writing
/// it back through [CollectionDao.updateEntry], which is a different job from
/// this one; a parameter that appeared to offer it would instead merge into the
/// existing stack and quietly inflate the quantity.
Future<bool> showAddToCollectionSheet(
  BuildContext context,
  WidgetRef ref,
  TcgCard card, {
  CardFinish? initialFinish,
}) async {
  final CardGame game = card.game;
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        _AddToCollectionSheet(card: card, initialFinish: initialFinish),
  );
  if (result == true) {
    ref.invalidate(collectionOverviewProvider(game));
    ref.invalidate(ownedQuantityProvider(game));
    ref.invalidate(ownedBySetProvider(game));
    ref.invalidate(gameSummariesProvider);
    ref.invalidate(cardEntriesProvider((game: game, id: card.id)));
  }
  return result ?? false;
}

/// What the sheet says about the copies the user already has.
///
/// This line used to read 'Added to your Magic collection' before anything had
/// been added - the one claim a sheet like this must not make, because the whole
/// point of it is to say what pressing the button is about to do. [copies] is
/// null while the count is still being read, which is not the same as none.
String ownershipNote({required CardGame game, required int? copies}) {
  if (copies == null) return 'Checking what you already have...';
  if (copies <= 0) return 'Not in your ${game.shortLabel} collection yet';
  return 'You already own $copies '
      '${copies == 1 ? 'copy' : 'copies'} of this printing';
}

class _AddToCollectionSheet extends ConsumerStatefulWidget {
  const _AddToCollectionSheet({required this.card, this.initialFinish});

  final TcgCard card;

  /// Preferred finish, when the caller has one in mind. Ignored if the card's
  /// game does not actually have that finish.
  final CardFinish? initialFinish;

  @override
  ConsumerState<_AddToCollectionSheet> createState() =>
      _AddToCollectionSheetState();
}

class _AddToCollectionSheetState extends ConsumerState<_AddToCollectionSheet> {
  final _priceController = TextEditingController();
  final _binderController = TextEditingController();

  late CardFinish _finish;
  late CardCondition _condition;
  int _quantity = 1;
  bool _saving = false;

  /// The finishes this game physically prints.
  List<CardFinish> get _finishes => widget.card.game.finishes;

  /// The grades this game's collectors use.
  List<CardCondition> get _conditions => widget.card.game.conditions;

  @override
  void initState() {
    super.initState();
    final List<CardFinish> finishes = widget.card.game.finishes;
    final CardFinish? wanted = widget.initialFinish;
    _finish = wanted != null && finishes.contains(wanted)
        ? wanted
        : (finishes.isNotEmpty ? finishes.first : CardFinish.nonfoil);

    final List<CardCondition> conditions = widget.card.game.conditions;
    _condition = conditions.contains(CardCondition.nearMint)
        ? CardCondition.nearMint
        : (conditions.isNotEmpty ? conditions.first : CardCondition.nearMint);
  }

  @override
  void dispose() {
    _priceController.dispose();
    _binderController.dispose();
    super.dispose();
  }

  /// The reference price of the selected finish, falling back to the cheapest
  /// finish the provider quotes when this game has no price for it.
  double? get _unitPrice =>
      widget.card.prices.priceFor(_finish) ?? widget.card.prices.from;

  /// How many copies of this printing the user already has, or null while the
  /// count is still being read - which is not the same answer as none.
  int? get _ownedCopies {
    final AsyncValue<Map<String, int>> owned = ref.watch(
      ownedQuantityProvider(widget.card.game),
    );
    if (!owned.hasValue) return null;
    return owned.value?[widget.card.id] ?? 0;
  }

  /// The price subtitle for a finish chip, or null when that finish is not
  /// quoted at all.
  String? _finishPrice(CardFinish finish) {
    final double? value = widget.card.prices.priceFor(finish);
    if (value == null || value <= 0) return null;
    return Fmt.money(value);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(bootstrapProvider).collectionFor(widget.card.game);
      final purchase = double.tryParse(_priceController.text.trim());
      await repo.addCard(
        cardId: widget.card.id,
        finish: _finish,
        condition: _condition,
        quantity: _quantity,
        purchasePrice: purchase,
        purchaseDate: purchase == null ? null : DateTime.now(),
        binder: _binderController.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final CardGame game = widget.card.game;
    final double? unit = _unitPrice;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border.all(color: c.hairline),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
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
              const SizedBox(height: 18),
              Text('Add to collection', style: context.t.headlineSmall),
              const SizedBox(height: 2),
              Text(
                '${widget.card.name} · '
                '${widget.card.setCode.toUpperCase()} '
                '#${widget.card.collectorNumber}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                ownershipNote(game: game, copies: _ownedCopies),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
              const SizedBox(height: 20),

              _Label('Finish'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in _finishes)
                    _Choice(
                      label: f.label,
                      selected: _finish == f,
                      onTap: () => setState(() => _finish = f),
                      subtitle: _finishPrice(f),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              _Label('Condition'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final cond in _conditions)
                    _Choice(
                      label: cond.short,
                      tooltip: cond.label,
                      selected: _condition == cond,
                      onTap: () => setState(() => _condition = cond),
                    ),
                ],
              ),
              const SizedBox(height: 20),

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Label('Quantity'),
                        const SizedBox(height: 8),
                        _QuantityStepper(
                          value: _quantity,
                          onChanged: (v) => setState(() => _quantity = v),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Label('Paid per copy'),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          decoration: const InputDecoration(
                            hintText: 'optional',
                            prefixText: r'$ ',
                            isDense: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              _Label('Binder / location'),
              const SizedBox(height: 8),
              TextField(
                controller: _binderController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  hintText: 'e.g. Binder A — Red',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 22),

              // Live value preview.
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Stack value', style: context.t.bodySmall),
                          const SizedBox(height: 2),
                          Text(
                            unit == null
                                ? 'No market price'
                                : Fmt.money(unit * _quantity),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.headlineSmall,
                          ),
                        ],
                      ),
                    ),
                    if (unit != null) ...[
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '$_quantity × ${Fmt.money(unit)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: context.t.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),

              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded, size: 20),
                label: Text(
                  _quantity == 1 ? 'Add 1 copy' : 'Add $_quantity copies',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: context.t.labelSmall?.copyWith(color: context.c.textTertiary),
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.tooltip,
  });

  final String label;
  final String? subtitle;
  final String? tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final chip = Material(
      color: selected ? c.accent.withValues(alpha: 0.22) : c.surfaceRaised,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? c.accent.withValues(alpha: 0.65) : c.hairline,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: context.t.labelLarge?.copyWith(
                  color: selected ? c.accent : c.textPrimary,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: value > 1
                ? () {
                    HapticFeedback.selectionClick();
                    onChanged(value - 1);
                  }
                : null,
            icon: const Icon(Icons.remove_rounded, size: 20),
          ),
          Expanded(
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: context.t.headlineSmall,
            ),
          ),
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              onChanged(value + 1);
            },
            icon: const Icon(Icons.add_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}
