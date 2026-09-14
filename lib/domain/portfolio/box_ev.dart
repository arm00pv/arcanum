import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// One rarity slot in a box: how many cards of one tier come out of it.
///
/// Rarity is the app's own tier, not the provider's word for it, because two
/// providers spell the same rung differently and a box that is 24 rares is 24
/// rares whichever shop is quoting them.
class BoxSlot {
  /// Creates a slot.
  const BoxSlot(this.rarity, this.count);

  /// Which tier this slot draws from.
  final CardRarity rarity;

  /// How many cards of that tier the slot yields.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is BoxSlot && other.rarity == rarity && other.count == count;

  @override
  int get hashCode => Object.hash(rarity, count);

  @override
  String toString() => 'BoxSlot(${rarity.name} x$count)';
}

/// What a box is assumed to hold.
///
/// This is the one thing about box expected value the app cannot look up. A
/// shop publishes what a box costs, a catalogue publishes what the cards in it
/// are worth, and nobody publishes the pull rates in between: they are not in
/// any feed, they change with every print run, and a number invented for them
/// would be indistinguishable on screen from a measured one.
///
/// So the composition is stated rather than guessed. [packs] and [cardsPerPack]
/// can often be read off the shop's own description of the box - [fromDescription]
/// does exactly that and nothing more - while [slots], which is the shape of a
/// pack, is the collector's to state. Every figure derived from a composition
/// says which composition it came from.
class BoxComposition {
  /// Creates a composition.
  const BoxComposition({
    this.packs = 0,
    this.cardsPerPack = 0,
    this.slots = const <BoxSlot>[],
  });

  /// How many packs are in the box.
  final int packs;

  /// How many cards are in a pack.
  final int cardsPerPack;

  /// What each rarity slot yields, per box.
  final List<BoxSlot> slots;

  /// A box nobody has described yet.
  static const BoxComposition none = BoxComposition();

  /// The cards the slots account for.
  int get cards => slots.fold(0, (int sum, BoxSlot slot) => sum + slot.count);

  /// The cards the box promises: every pack, full.
  int get promised => packs * cardsPerPack;

  /// True when nothing is stated about the box at all.
  bool get isEmpty => packs == 0 && cardsPerPack == 0 && slots.isEmpty;

  /// True when the slots account for exactly what the box promises.
  ///
  /// A composition that does not add up is not an error - a collector may know
  /// what a box is worth without knowing how many cards are in it - but it is
  /// worth saying, because a box of 24 packs of 12 cards with 30 slots in it is
  /// describing something that does not exist.
  bool get isWhole => promised > 0 && cards == promised;

  /// How many cards of one tier the composition yields.
  int countOf(CardRarity tier) => slots
      .where((BoxSlot slot) => slot.rarity == tier)
      .fold(0, (int sum, BoxSlot slot) => sum + slot.count);

  /// The same composition with one tier's count set, dropping it at zero.
  BoxComposition withSlot(CardRarity tier, int count) {
    final next = <BoxSlot>[
      for (final BoxSlot slot in slots)
        if (slot.rarity != tier) slot,
      if (count > 0) BoxSlot(tier, count),
    ]..sort((BoxSlot a, BoxSlot b) => a.rarity.index.compareTo(b.rarity.index));
    return BoxComposition(
      packs: packs,
      cardsPerPack: cardsPerPack,
      slots: next,
    );
  }

  /// The same composition with the size of the box changed.
  BoxComposition withSize({int? packs, int? cardsPerPack}) => BoxComposition(
    packs: packs ?? this.packs,
    cardsPerPack: cardsPerPack ?? this.cardsPerPack,
    slots: slots,
  );

  /// The same composition, empty of slots.
  BoxComposition withNoSlots() =>
      BoxComposition(packs: packs, cardsPerPack: cardsPerPack);

  /// A box whose cards are dealt out in the proportions the set is printed in.
  ///
  /// The set's own rarity makeup applied to one box, with the leftovers given to
  /// the tiers that were closest to another card so the slots add up exactly.
  /// It is a model and not a measurement - a real pack is weighted towards the
  /// lower rarities rather than towards the set's makeup - which is why it is
  /// offered as one of the things a collector can choose rather than as the
  /// app's opinion.
  static BoxComposition evenAcross({
    required List<TcgCard> cards,
    required int packs,
    required int cardsPerPack,
  }) {
    final total = packs * cardsPerPack;
    if (total <= 0 || cards.isEmpty) {
      return BoxComposition(packs: packs, cardsPerPack: cardsPerPack);
    }
    final counts = <CardRarity, int>{};
    for (final TcgCard card in cards) {
      final tier = CardRarity.fromCode(card.rarity);
      counts[tier] = (counts[tier] ?? 0) + 1;
    }
    final slots = <BoxSlot>[];
    final remainder = <MapEntry<CardRarity, double>>[];
    var assigned = 0;
    for (final MapEntry<CardRarity, int> entry in counts.entries) {
      final exact = total * entry.value / cards.length;
      final whole = exact.floor();
      assigned += whole;
      if (whole > 0) slots.add(BoxSlot(entry.key, whole));
      remainder.add(MapEntry<CardRarity, double>(entry.key, exact - whole));
    }
    remainder.sort(
      (MapEntry<CardRarity, double> a, MapEntry<CardRarity, double> b) =>
          b.value.compareTo(a.value),
    );
    var left = total - assigned;
    for (final MapEntry<CardRarity, double> entry in remainder) {
      if (left <= 0) break;
      final at = slots.indexWhere((BoxSlot s) => s.rarity == entry.key);
      if (at >= 0) {
        slots[at] = BoxSlot(entry.key, slots[at].count + 1);
      } else {
        slots.add(BoxSlot(entry.key, 1));
      }
      left--;
    }
    slots.sort(
      (BoxSlot a, BoxSlot b) => a.rarity.index.compareTo(b.rarity.index),
    );
    return BoxComposition(
      packs: packs,
      cardsPerPack: cardsPerPack,
      slots: slots,
    );
  }

  /// What the shop's own description says about the size of the box.
  ///
  /// Sealed product carries the shop's copy with it, and two sentences in it are
  /// exactly what a composition needs: 'Each Booster Pack contains 12 cards' and
  /// '1 Box contains 24 Booster packs'. Those two numbers are read and nothing
  /// else is: the shape of a pack is not in the description, and inferring one
  /// from the set's rarity counts would be the app inventing the one number it
  /// has no source for. A case of boxes is deliberately not read as a box - the
  /// unit has to be packs - and a description that states neither number
  /// returns null rather than an empty composition.
  static BoxComposition? fromDescription(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    final clean = text
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&');
    var packs = 0;
    var perPack = 0;
    for (final String sentence in clean.split(RegExp(r'(?<=[.!?])\s+'))) {
      final lower = sentence.toLowerCase();
      if (perPack == 0 && lower.contains('pack')) {
        final match = RegExp(r'(\d+)\s*cards?\b').firstMatch(lower);
        if (match != null) perPack = int.parse(match.group(1)!);
      }
      if (packs == 0 && lower.contains('box')) {
        final match = RegExp(
          r'(\d+)\s*(?:booster\s+|ultimate\s+advent\s+)?(?:packs?|boosters?)(?!\s*box)',
        ).firstMatch(lower);
        if (match != null) packs = int.parse(match.group(1)!);
      }
    }
    if (packs == 0 && perPack == 0) return null;
    return BoxComposition(packs: packs, cardsPerPack: perPack);
  }

  /// The composition as it is stored.
  Map<String, Object?> toJson() => <String, Object?>{
    'packs': packs,
    'cardsPerPack': cardsPerPack,
    'slots': <Map<String, Object?>>[
      for (final BoxSlot slot in slots)
        <String, Object?>{'rarity': slot.rarity.name, 'count': slot.count},
    ],
  };

  /// Reads a stored composition back.
  factory BoxComposition.fromJson(Map<String, Object?>? json) {
    if (json == null) return none;
    final rawSlots = json['slots'];
    final slots = <BoxSlot>[];
    if (rawSlots is List) {
      for (final Object? row in rawSlots) {
        if (row is! Map) continue;
        final name = row['rarity']?.toString() ?? '';
        final count = (row['count'] as num?)?.toInt() ?? 0;
        if (count <= 0) continue;
        for (final CardRarity tier in CardRarity.values) {
          if (tier.name == name) slots.add(BoxSlot(tier, count));
        }
      }
    }
    slots.sort(
      (BoxSlot a, BoxSlot b) => a.rarity.index.compareTo(b.rarity.index),
    );
    return BoxComposition(
      packs: (json['packs'] as num?)?.toInt() ?? 0,
      cardsPerPack: (json['cardsPerPack'] as num?)?.toInt() ?? 0,
      slots: slots,
    );
  }

  @override
  String toString() =>
      'BoxComposition($packs packs of $cardsPerPack, ${slots.join(', ')})';
}

/// One tier's line in the answer.
class BoxTierLine {
  /// Creates a line.
  const BoxTierLine({
    required this.rarity,
    required this.count,
    required this.inSet,
    required this.priced,
    required this.mean,
    required this.cheapest,
    required this.dearest,
  });

  /// The tier.
  final CardRarity rarity;

  /// How many cards of it the composition promises.
  final int count;

  /// How many printings of it the set holds, and how many of those are priced.
  final int inSet;
  final int priced;

  /// The mean price of the priced printings, and the cheapest and dearest of
  /// them, which is what says whether a tier is a flat tier or a lottery.
  final double? mean;
  final double? cheapest;
  final double? dearest;

  /// What this tier contributes to the box.
  double? get subtotal => mean == null ? null : mean! * count;

  /// True when this tier is promised cards but nothing prices them.
  bool get isUnpriced => count > 0 && mean == null;
}

/// A card worth opening the box for.
class BoxChase {
  /// Creates a chase entry.
  const BoxChase({
    required this.card,
    required this.price,
    required this.versusBox,
  });

  /// The printing.
  final TcgCard card;

  /// What it is worth today.
  final double price;

  /// Its price as a multiple of the box's own price, when the box is priced.
  final double? versusBox;
}

/// What one box is worth, opened, at today's prices.
class BoxEv {
  const BoxEv._({
    required this.cards,
    required this.composition,
    required this.tiers,
    required this.expected,
    required this.complete,
    required this.ceiling,
    required this.boxPrice,
    required this.chase,
    required this.pricedCards,
    required this.unpricedCards,
  });

  /// Works out what a box is worth from a composition and the set's prices.
  ///
  /// Each slot is valued at the mean price of the set's printings at that tier,
  /// which is the honest way to price a card you do not know the identity of.
  /// Anything unpriced is left out of the mean rather than counted as zero: a
  /// printing nobody quotes is not a printing worth nothing, and a box whose
  /// rares are unpriced reports an incomplete figure rather than a cheap one.
  factory BoxEv.of({
    required List<TcgCard> cards,
    required BoxComposition composition,
    double? boxPrice,
  }) {
    final pricedByTier = <CardRarity, List<double>>{};
    final everyPrice = <double>[];
    var pricedCards = 0;
    for (final TcgCard card in cards) {
      final price = card.prices.from;
      if (price == null || price <= 0) continue;
      pricedCards++;
      everyPrice.add(price);
      pricedByTier
          .putIfAbsent(CardRarity.fromCode(card.rarity), () => <double>[])
          .add(price);
    }

    final tiers = <BoxTierLine>[];
    var expected = 0.0;
    var complete = true;
    for (final CardRarity tier in CardRarity.values) {
      final inSet = cards
          .where((TcgCard card) => CardRarity.fromCode(card.rarity) == tier)
          .length;
      final prices = pricedByTier[tier] ?? const <double>[];
      final count = composition.countOf(tier);
      double? mean;
      if (prices.isNotEmpty) {
        mean = prices.reduce((double a, double b) => a + b) / prices.length;
        expected += mean * count;
      } else if (count > 0) {
        complete = false;
      }
      final sorted = <double>[...prices]..sort();
      tiers.add(
        BoxTierLine(
          rarity: tier,
          count: count,
          inSet: inSet,
          priced: prices.length,
          mean: mean,
          cheapest: sorted.isEmpty ? null : sorted.first,
          dearest: sorted.isEmpty ? null : sorted.last,
        ),
      );
    }

    // The ceiling: the same number of cards drawn evenly across the set. No
    // pack is dealt that way - packs are weighted to the cheap end - so this is
    // the most a box of that many cards could be worth, not what one is worth.
    double? ceiling;
    if (everyPrice.isNotEmpty && composition.cards > 0) {
      final mean =
          everyPrice.reduce((double a, double b) => a + b) / everyPrice.length;
      ceiling = mean * composition.cards;
    }

    final dearest = <TcgCard>[...cards]
      ..sort(
        (TcgCard a, TcgCard b) =>
            (b.prices.from ?? -1).compareTo(a.prices.from ?? -1),
      );
    final chase = <BoxChase>[
      for (final TcgCard card in dearest.take(5))
        if ((card.prices.from ?? 0) > 0)
          BoxChase(
            card: card,
            price: card.prices.from!,
            versusBox: (boxPrice ?? 0) > 0
                ? card.prices.from! / boxPrice!
                : null,
          ),
    ];

    return BoxEv._(
      cards: cards.length,
      composition: composition,
      tiers: tiers,
      expected: expected,
      complete: complete,
      ceiling: ceiling,
      boxPrice: boxPrice,
      chase: chase,
      pricedCards: pricedCards,
      unpricedCards: cards.length - pricedCards,
    );
  }

  /// Every printing the set holds, which is what the means were taken over.
  final int cards;

  /// The composition the figure came from.
  final BoxComposition composition;

  /// One line per tier, in tier order.
  final List<BoxTierLine> tiers;

  /// What the box is worth opened, for the tiers that could be priced.
  final double expected;

  /// True when every promised tier had something to price it with.
  final bool complete;

  /// The value of the same number of cards drawn evenly across the set.
  final double? ceiling;

  /// What the box itself costs, when a price list quotes one.
  final double? boxPrice;

  /// The dearest cards in the set, which is why a box gets opened.
  final List<BoxChase> chase;

  /// How many printings carry a price, and how many do not.
  final int pricedCards;
  final int unpricedCards;

  /// What one pack is worth, when the box says how many it holds.
  double? get perPack =>
      composition.packs <= 0 ? null : expected / composition.packs;

  /// The expected value as a share of the box's price.
  double? get ratio => (boxPrice ?? 0) <= 0 ? null : expected / boxPrice!;

  /// What opening the box is worth against buying it, in money.
  double? get surplus => (boxPrice ?? 0) <= 0 ? null : expected - boxPrice!;

  /// True when the answer is worth showing at all.
  bool get isComputable => composition.cards > 0 && pricedCards > 0;
}
