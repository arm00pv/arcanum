import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/sealed/sealed_lookup.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// What a box of a set is worth opened, against what the box costs.
///
/// The one figure a box's value needs and no feed publishes is what is in the
/// box. Pull rates are not in any price list, they change with every print run,
/// and a number invented for them would look exactly like a measured one on
/// screen - so this screen asks instead of guessing. The size of the box is
/// offered from the shop's own description where the shop states it; the shape
/// of a pack is the collector's to state, once per set, and it is kept.
///
/// Everything below the editor is labelled with the assumption behind it, and
/// the set's unpriced printings are reported as unpriced rather than counted as
/// free, because a box whose mythics nobody quotes is not a box worth nothing.
class BoxEvScreen extends ConsumerStatefulWidget {
  /// Creates the box value screen.
  ///
  /// [productId], [productName] and [heldPrice] describe the box the collector
  /// actually holds, when the screen was opened from one: the box being valued
  /// is then that box, not whichever box in the set happens to be dearest.
  const BoxEvScreen({
    super.key,
    required this.game,
    required this.setCode,
    this.productId = '',
    this.productName = '',
    this.heldPrice,
  });

  /// The game the set belongs to.
  final CardGame game;

  /// The set whose boxes are being valued.
  final String setCode;

  /// The price list's id for the box held, empty when there is no holding.
  final String productId;

  /// The held box's name, used when the price list renames or renumbers it.
  final String productName;

  /// What the holding itself is worth, used when no price list answers.
  final double? heldPrice;

  @override
  ConsumerState<BoxEvScreen> createState() => _BoxEvScreenState();
}

class _BoxEvScreenState extends ConsumerState<BoxEvScreen> {
  /// What the collector has edited. Null means "whatever is stored".
  BoxComposition? _draft;

  /// Which box the collector picked out of the price list.
  ///
  /// Null means the default - the dearest single box - and -1 means they
  /// deliberately unpicked one to type a price in instead.
  int? _offerIndex;

  /// Whether the products that are not a box of this set are on show.
  bool _showAll = false;

  /// A case of boxes, which is six boxes and not one.
  ///
  /// The price list spells it out in the name, and treating a case as a box is
  /// the one mistake this screen must not make: a case costs six times as much
  /// and holds six times as much, so a composition of one box against a case's
  /// price says a box is worth a sixth of what it is worth.
  static bool _isCase(SealedOffer o) => o.name.toLowerCase().contains('case');

  /// True for the things that are one box of cards.
  static bool _isBox(SealedOffer o) =>
      !_isCase(o) &&
      (o.category == SealedCategory.boosterBox ||
          o.category == SealedCategory.bundle);

  /// The price list's products, boxes of this set first and cases last.
  ///
  /// The list arrives dearest first, and a case is always dearest, so the order
  /// is what keeps both the chip list and the default price about one box.
  List<SealedOffer> _ordered(List<SealedOffer> offers) => <SealedOffer>[
    ...offers.where(_isBox),
    ...offers.where((SealedOffer o) => !_isBox(o) && !_isCase(o)),
    ...offers.where(_isCase),
  ];

  /// The box the answer is measured against, or null when none is picked.
  SealedOffer? _chosen(List<SealedOffer> offers) {
    if (offers.isEmpty) return null;
    final index = _offerIndex;
    if (index == null) {
      // The box the collector holds, when this screen knows which one that is.
      // Opening the value of a shelf box and being shown the price of a
      // different box is the kind of wrong that looks like a working screen.
      final String id = widget.productId.trim();
      if (id.isNotEmpty) {
        final held = offers.indexWhere((SealedOffer o) => o.productId == id);
        if (held >= 0) return offers[held];
      }
      final String name = widget.productName.trim().toLowerCase();
      if (name.isNotEmpty) {
        final same = offers.indexWhere(
          (SealedOffer o) => o.name.toLowerCase() == name,
        );
        if (same >= 0) return offers[same];
      }
      // Otherwise the dearest box that is one box. A set with no box at all
      // falls back to whatever the list does have, so a collector with a bundle
      // is not made to type a price the companion already knows.
      final box = offers.indexWhere(_isBox);
      if (box >= 0) return offers[box];
      final any = offers.indexWhere((SealedOffer o) => !_isCase(o));
      return any >= 0 ? offers[any] : offers.first;
    }
    if (index < 0 || index >= offers.length) return null;
    return offers[index];
  }

  /// A price typed in by hand, used when no price list answered.
  double? _typed;

  final _priceController = TextEditingController();

  SetRef get _ref => (game: widget.game, code: widget.setCode);

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  /// The composition the screen is working with.
  BoxComposition _composition(BoxComposition? stored) =>
      _draft ?? stored ?? BoxComposition.none;

  /// Stores what the collector has just stated.
  Future<void> _save(BoxComposition composition) async {
    await ref
        .read(boxDaoProvider)
        .save(widget.game, widget.setCode, composition);
    ref.read(boxRevisionProvider.notifier).bump();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Box composition saved for this set')),
    );
  }

  Future<void> _clear() async {
    await ref.read(boxDaoProvider).clear(widget.game, widget.setCode);
    ref.read(boxRevisionProvider.notifier).bump();
    if (!mounted) return;
    setState(() => _draft = BoxComposition.none);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<BoxComposition?> stored = ref.watch(
      boxCompositionProvider(_ref),
    );
    final AsyncValue<List<TcgCard>> cardsAsync = ref.watch(
      setCardsProvider(_ref),
    );
    final AsyncValue<List<SealedOffer>> offersAsync = ref.watch(
      sealedOffersProvider(_ref),
    );
    final TcgSet? set = ref.watch(setProvider(_ref)).value;

    final List<TcgCard> cards = cardsAsync.value ?? const <TcgCard>[];
    final List<SealedOffer> offers = _ordered(
      offersAsync.value ?? const <SealedOffer>[],
    );
    final SealedOffer? chosen = _chosen(offers);
    final composition = _composition(stored.value);
    // The holding's own recorded value is the last resort rather than zero: it
    // is what the shelf already says the box is worth.
    final double? boxPrice = _typed ?? chosen?.market ?? widget.heldPrice;
    final BoxEv ev = BoxEv.of(
      cards: cards,
      composition: composition,
      boxPrice: boxPrice,
    );
    // The set's name rather than its code, because the code is on the screen
    // that opened this and the name is what a collector calls the box.
    final String setName = set?.name ?? widget.setCode.toUpperCase();

    return Scaffold(
      appBar: AppBar(
        title: Text('Box value', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: <Widget>[
          SectionHeader(
            title: 'What a box of $setName is worth',
            subtitle:
                'Opened, at the prices this set carries today - '
                'against what the box costs',
          ),
          if (cardsAsync.isLoading && cards.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (cards.isEmpty && !cardsAsync.isLoading) _noCards(),
          if (cards.isNotEmpty) ...<Widget>[
            _pricePicker(offers, chosen),
            _editor(cards, composition, chosen),
            _answer(ev),
            _tiers(ev),
            if (ev.chase.isNotEmpty) _chase(ev),
            _caveat(ev),
          ],
        ],
      ),
    );
  }

  Widget _noCards() => _card(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('The set is not downloaded', style: context.t.titleSmall),
        const SizedBox(height: 6),
        Text(
          "Box value is worked out from the set's own prices, so the set has "
          'to be on the phone first. Download it from the set screen and come '
          'back.',
          style: context.t.bodySmall?.copyWith(color: context.c.textSecondary),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------- box price

  Widget _pricePicker(List<SealedOffer> offers, SealedOffer? chosen) {
    final c = context.c;
    final boxes = <SealedOffer>[
      for (final SealedOffer offer in offers)
        if (_isBox(offer)) offer,
    ];
    // Cases, packs, decks and toolkits are real products with real prices, and
    // one of them is what somebody opening a case wants - but they are not a box
    // of this set, so they are offered rather than shown.
    final rest = offers.length - boxes.length;

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('THE BOX', style: _labelStyle),
          const SizedBox(height: 4),
          Text(
            boxes.isEmpty
                ? "No price list answered for this set's boxes. Type what the "
                      'box costs and the rest still works.'
                : 'Which box is being opened?',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (boxes.isNotEmpty || _showAll) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (int i = 0; i < offers.length; i++)
                  if (_showAll || _isBox(offers[i]))
                    _offerChip(offers[i], i, identical(chosen, offers[i])),
              ],
            ),
          ],
          if (rest > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _showAll = !_showAll),
                child: Text(
                  _showAll
                      ? 'Show fewer products'
                      : rest == 1
                      ? 'Show one more, a case or a deck'
                      : 'Show $rest more, cases and decks included',
                ),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Box price',
              hintText: 'What you paid, or what it sells for',
              prefixText: r'$ ',
              border: OutlineInputBorder(),
            ),
            onChanged: (String value) => setState(() {
              final typed = double.tryParse(value.trim());
              _typed = (typed != null && typed > 0) ? typed : null;
            }),
          ),
        ],
      ),
    );
  }

  Widget _offerChip(SealedOffer offer, int index, bool selected) {
    final c = context.c;
    return GestureDetector(
      onTap: () => setState(() {
        // Tapping the chosen box unpicks it, which is how a collector says
        // "none of these - I typed the price in myself".
        _offerIndex = selected ? -1 : index;
        _priceController.clear();
        _typed = null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? c.accentSoft : c.surfaceRaised,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? c.accent : c.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                offer.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.t.bodySmall,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              offer.isPriced ? Fmt.money(offer.market) : 'No price yet',
              style: context.t.titleSmall?.copyWith(
                color: offer.isPriced ? c.textPrimary : c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- editor

  Widget _editor(
    List<TcgCard> cards,
    BoxComposition composition,
    SealedOffer? offered,
  ) {
    final c = context.c;
    // What the shop itself says the chosen box holds, offered rather than
    // applied: the app reading a number out of marketing copy is a suggestion,
    // and the collector is the one who knows whether it is the right box.
    // Only the chosen box's own description is read: another product's copy is
    // another product's box.
    final stated = offered?.statedComposition;

    // What the shop's description says, in the collector's words rather than
    // the shop's - a product page writes "1 Box contains 24 Booster".
    final said = stated == null
        ? ''
        : <String>[
            if (stated.packs > 0) '${stated.packs} packs',
            if (stated.cardsPerPack > 0) '${stated.cardsPerPack} cards a pack',
          ].join(', ');

    final tiers = <CardRarity>[
      for (final CardRarity tier in CardRarity.values)
        if (tier != CardRarity.unknown &&
            (composition.countOf(tier) > 0 ||
                cards.any(
                  (TcgCard card) => CardRarity.fromCode(card.rarity) == tier,
                )))
          tier,
    ];

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('WHAT THE BOX HOLDS', style: _labelStyle),
          const SizedBox(height: 4),
          Text(
            "Nobody publishes this. A box's pull rates are not in any feed, so "
            'the app asks you rather than making them up - and remembers the '
            'answer for every box of this set.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 12),
          _stepper(
            'Packs in the box',
            composition.packs,
            (int v) => setState(() {
              _draft = composition.withSize(packs: v);
            }),
          ),
          _stepper(
            'Cards in a pack',
            composition.cardsPerPack,
            (int v) => setState(() {
              _draft = composition.withSize(cardsPerPack: v);
            }),
          ),
          if (said.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    final shape = stated;
                    if (shape == null) return;
                    setState(() {
                      _draft = composition.withSize(
                        packs: shape.packs > 0 ? shape.packs : null,
                        cardsPerPack: shape.cardsPerPack > 0
                            ? shape.cardsPerPack
                            : null,
                      );
                    });
                  },
                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: Text('The shop says $said - use it'),
                ),
              ),
            ),
          const Divider(height: 26),
          Text('How the cards come out', style: context.t.titleSmall),
          const SizedBox(height: 4),
          // The app does not fill these in, and an earlier version did: it dealt
          // the box out in the proportions of the set's own printings, which is
          // a uniform draw across the whole set - so a 36-pack box came out at
          // twenty-six times what the box sells for, in green, under a heading
          // that said it was a model. A pack is not dealt like the set, the
          // shop's copy gives ranges rather than a rule, and an average that is
          // wrong by a factor of twenty-six is worse than no average. Typing the
          // numbers is the honest version.
          Text(
            'A pack is not dealt like the set, so these are yours to state: '
            'tap a count to type it. What one pack holds is not published as a '
            'rule, only as the ranges a shop prints - and a range is not a '
            'distribution.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 10),
          for (final CardRarity tier in tiers)
            _stepper(
              tier.label,
              composition.countOf(tier),
              (int v) => setState(() {
                _draft = composition.withSlot(tier, v);
              }),
              colour: tier.color,
            ),
          const SizedBox(height: 6),
          Text(
            composition.promised <= 0
                ? 'The slots account for ${Fmt.count(composition.cards)} cards'
                : 'The slots account for ${Fmt.count(composition.cards)} of '
                      '${Fmt.count(composition.promised)} cards',
            style: context.t.bodySmall?.copyWith(
              color: composition.isWhole || composition.promised <= 0
                  ? c.textTertiary
                  : c.warning,
            ),
          ),
          const SizedBox(height: 10),
          // Wrapped rather than in a Row: a phone in a large-text setting makes
          // two buttons wider than the card, and a truncated Save button is a
          // button nobody can find.
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FilledButton.icon(
                onPressed: composition.isEmpty
                    ? null
                    : () => _save(composition),
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Save for this set'),
              ),
              if (!composition.isEmpty)
                TextButton(onPressed: _clear, child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }

  /// Asks for a count, because a slot can hold 252 cards and no one is going
  /// to tap a plus sign two hundred and fifty-two times.
  Future<void> _typeCount(
    String label,
    int current,
    ValueChanged<int> onSet,
  ) async {
    // Typed into a field that keeps its own value rather than through a
    // controller: a controller outlives the route by a frame or two, and
    // disposing one while its field is still on screen is an assertion.
    var typed = current;
    final int? answer = await showDialog<int>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(label),
        content: TextFormField(
          initialValue: current == 0 ? '' : '$current',
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          decoration: const InputDecoration(labelText: 'Cards', hintText: '0'),
          onChanged: (String value) => typed = int.tryParse(value.trim()) ?? 0,
          onFieldSubmitted: (String value) =>
              Navigator.of(dialog).pop(int.tryParse(value.trim()) ?? 0),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(typed),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (answer == null || answer == current) return;
    onSet(answer);
  }

  Widget _stepper(
    String label,
    int value,
    ValueChanged<int> onChanged, {
    Color? colour,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          if (colour != null) ...<Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: colour,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(child: Text(label, style: context.t.bodyMedium)),
          _round(
            Icons.remove_rounded,
            value <= 0 ? null : () => onChanged(value - 1),
          ),
          // The count is the button as well as the readout: a slot can hold a
          // few hundred cards, and the way to say so is to type it.
          Tooltip(
            message: 'Type a count',
            child: InkWell(
              onTap: () => _typeCount(label, value, onChanged),
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 62,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    Fmt.count(value),
                    textAlign: TextAlign.center,
                    style: context.t.titleMedium,
                  ),
                ),
              ),
            ),
          ),
          _round(Icons.add_rounded, () => onChanged(value + 1)),
        ],
      ),
    );
  }

  Widget _round(IconData icon, VoidCallback? onPressed) {
    final c = context.c;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        backgroundColor: c.surfaceRaised,
        foregroundColor: onPressed == null ? c.textTertiary : c.textPrimary,
      ),
    );
  }

  // ------------------------------------------------------------- answer

  Widget _answer(BoxEv ev) {
    final c = context.c;
    if (!ev.isComputable) {
      return _card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('WHAT IT COMES TO', style: _labelStyle),
            const SizedBox(height: 6),
            Text(
              ev.composition.cards <= 0
                  ? 'State what the box holds and the answer appears here.'
                  : 'Nothing in this set carries a price yet, so there is '
                        'nothing to value the box against. A brand-new set has '
                        'no quotes for a few days.',
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      );
    }

    final ratio = ev.ratio;
    final unpriced = _unpricedTiers(ev);
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('WHAT IT COMES TO', style: _labelStyle),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Expected value',
                  value: Fmt.money(ev.expected),
                  icon: Icons.calculate_outlined,
                  caption: ev.complete
                      ? 'Every slot priced'
                      : unpriced == 1
                      ? 'One slot has no price, so this is a floor'
                      : '${Fmt.count(unpriced)} slots have no price, so this '
                            'is a floor',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: 'Per pack',
                  value: Fmt.money(ev.perPack),
                  icon: Icons.inventory_2_outlined,
                  caption: ev.composition.packs > 0
                      ? 'Across ${Fmt.count(ev.composition.packs)} packs'
                      : 'No pack count stated',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: StatTile(
                  label: 'Against the box',
                  value: ratio == null ? '--' : Fmt.moneySigned(ev.surplus),
                  icon: Icons.balance_rounded,
                  valueColor: ratio == null
                      ? c.textPrimary
                      : c.forDelta(ev.surplus ?? 0),
                  caption: ratio == null
                      ? 'No box price yet'
                      : 'The box is ${Fmt.money(ev.boxPrice)}, so opening pays '
                            'back ${Fmt.percentPlain(ratio * 100)} of it',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatTile(
                  label: 'Ceiling',
                  value: Fmt.money(ev.ceiling),
                  icon: Icons.vertical_align_top_rounded,
                  caption: 'The same cards drawn evenly across the set',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Expected value is each slot valued at the mean price of the cards '
            'that slot can draw from. It assumes every card of a tier is as '
            'likely as the next, which is the only assumption the prices '
            'support.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (ev.unpricedCards > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '${Fmt.count(ev.unpricedCards)} of ${Fmt.count(ev.cards)} printings '
              'a slot can draw from carry no price at all. They are left out of '
              'the means rather than counted as nothing.',
              style: context.t.bodySmall?.copyWith(color: c.warning),
            ),
          ],
        ],
      ),
    );
  }

  int _unpricedTiers(BoxEv ev) =>
      ev.tiers.where((BoxTierLine line) => line.isUnpriced).length;

  /// What the means were averaged over, said in one line.
  ///
  /// A valuation is only as good as the pool it averaged, and the pool is
  /// narrower than the set whenever the set prints cards a slot cannot hand out.
  /// Both cases are worth stating: "every printing in the set" and "60 of 398"
  /// are different claims about the same figure, and a collector reading a
  /// number is entitled to know which one it is.
  String _basisLine(BoxEv ev) {
    if (ev.cards == ev.setPrintings) {
      return 'Averaged over every one of the set\'s '
          '${Fmt.count(ev.setPrintings)} printings - a slot can draw any of '
          'them.';
    }
    return 'Averaged over ${ev.basis.label}: ${Fmt.count(ev.cards)} of the '
        'set\'s ${Fmt.count(ev.setPrintings)} printings. The rest are '
        'treatments a slot cannot hand out, and averaging those in makes a box '
        'look several times more valuable than it is.';
  }

  // ------------------------------------------------------------- tiers

  Widget _tiers(BoxEv ev) {
    final c = context.c;
    final shown = ev.tiers
        .where((BoxTierLine line) => line.count > 0 || line.printings > 0)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();

    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('WHERE IT COMES FROM', style: _labelStyle),
          const SizedBox(height: 4),
          Text(
            _basisLine(ev),
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (ev.cards < ev.setPrintings) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'A box that promises the treatments this set prints - a Collector '
              'Booster Display, a premium box - holds cards left out here, so '
              'its contents are worth more than this figure.',
              style: context.t.bodySmall?.copyWith(color: c.warning),
            ),
          ],
          const SizedBox(height: 10),
          for (final BoxTierLine line in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: line.rarity.color,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '${Fmt.count(line.count)} × ${line.rarity.label}',
                          style: context.t.bodyMedium,
                        ),
                        Text(
                          line.mean == null
                              ? '${Fmt.count(line.printings)} printings, '
                                    'none priced'
                              : '${Fmt.count(line.priced)} of '
                                    '${Fmt.count(line.printings)} printings '
                                    'priced, ${Fmt.money(line.cheapest)} to '
                                    '${Fmt.money(line.dearest)}, mean '
                                    '${Fmt.money(line.mean)}',
                          style: context.t.labelSmall?.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    line.subtotal == null
                        ? 'unpriced'
                        : Fmt.money(line.subtotal),
                    style: context.t.titleSmall?.copyWith(
                      color: line.subtotal == null
                          ? c.textTertiary
                          : c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- chase

  Widget _chase(BoxEv ev) {
    final c = context.c;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('WHAT THE BOX IS OPENED FOR', style: _labelStyle),
          const SizedBox(height: 4),
          Text(
            'The dearest cards a slot can hand you. One of them does not pay for '
            'a box - that is what the figure above is for.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: 8),
          for (final BoxChase chase in ev.chase)
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CardDetailScreen(
                    game: widget.game,
                    cardId: chase.card.id,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            chase.card.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.t.bodyMedium,
                          ),
                          Text(
                            '#${chase.card.collectorNumber} · '
                            '${CardRarity.fromCode(chase.card.rarity).label}',
                            style: context.t.labelSmall?.copyWith(
                              color: c.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          Fmt.money(chase.price),
                          style: context.t.titleSmall,
                        ),
                        if (chase.versusBox != null)
                          Text(
                            '${chase.versusBox!.toStringAsFixed(2)}× the box',
                            style: context.t.labelSmall?.copyWith(
                              color: chase.versusBox! >= 1
                                  ? c.positive
                                  : c.textTertiary,
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
  }

  // ------------------------------------------------------------- caveat

  Widget _caveat(BoxEv ev) {
    final c = context.c;
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, size: 16, color: c.textTertiary),
              const SizedBox(width: 8),
              Text('WHAT THIS IS NOT', style: _labelStyle),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'A box opened card by card is a lottery, and this is its average. '
            'The composition above is what you said the box holds, not what the '
            "printer guaranteed; the ceiling is every card at the set's mean, "
            "which no pack does; and the prices are what the set's cards were "
            'quoted at the last time anything looked. It is a way to compare a '
            'box against the cards in it, which is a question with an answer, '
            'rather than a forecast of your pulls, which is not.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          if (ev.composition.packs > 0 && ev.composition.cardsPerPack > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Valued as ${Fmt.count(ev.composition.packs)} packs of '
                '${Fmt.count(ev.composition.cardsPerPack)}, '
                '${Fmt.count(ev.composition.cards)} cards in all.',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- chrome

  TextStyle? get _labelStyle => context.t.labelSmall?.copyWith(
    color: context.c.textTertiary,
    letterSpacing: 1.2,
  );

  Widget _card(Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: child,
    ),
  );
}
