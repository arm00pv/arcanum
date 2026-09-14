import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/sealed_product.dart';
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

  /// A number that counts cards, e.g. the 14 in '14 Magic: The Gathering
  /// cards'.
  ///
  /// The lookbehind refuses a range: '1-4 cards' is a spread and not a count,
  /// and reading it as four cards a pack is exactly the mistake this parser was
  /// rewritten to stop making.
  static final RegExp _cardCount = RegExp(
    r'(?<![\d-])(\d+)[^0-9\n]{0,60}?\bcards?\b',
  );

  /// A number that counts packs, e.g. the 36 in '36 Play Booster Packs'. A box
  /// of boxes is not a box of packs, so the unit may not be 'boxes'.
  static final RegExp _packCount = RegExp(
    r'(?<![\d-])(\d+)[^0-9\n]{0,60}?\b(?:packs?|boosters?)(?!\s*box)',
  );

  /// Whether a line says what a container holds.
  static bool _statesContents(String line, String noun) =>
      RegExp('(?:$noun)[a-z ]{0,16}\\b(?:contains?|includes?|holds?)\\b')
          .hasMatch(line);

  /// What the shop's own description says about the size of the box.
  ///
  /// Sealed product carries the shop's copy with it, and two things in it are
  /// exactly what a composition needs: 'Each Booster Pack contains 12 cards' and
  /// 'Box contains: 36 Play Booster Packs'. Those two numbers are read and
  /// nothing else is: the shape of a pack is not in the description, and
  /// inferring one from the set's rarity counts would be the app inventing the
  /// one number it has no source for.
  ///
  /// Read as lines rather than as one blob, because that is what the copy is -
  /// a heading and a bullet list under it - and a blob puts the first number it
  /// finds against the wrong noun. The real Bloomburrow listing says the box
  /// holds 36 packs of 14 cards and then lists '1-4 cards of rarity Rare', and
  /// the version of this parser that read sentences offered '4 cards a pack' on
  /// a collector's own box. So: the noun has to be followed by a containing
  /// verb, the number has to be a count and not a range, and the number may sit
  /// on the line below its heading, which is where a bullet list puts it.
  static BoxComposition? fromDescription(String? text) {
    if (text == null || text.trim().isEmpty) return null;

    // Markup that means 'a new line' becomes one before the rest is stripped:
    // stripping first welds a heading to its list, which is the whole bug.
    final lines = <String>[];
    final marked = text
        .replaceAll(
          RegExp(r'<(br|/p|/li|/div|/tr|/h[1-6])[^>]*>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'[•·▪]'), '\n');
    for (final String chunk in marked.split(RegExp(r'[\n\r]+'))) {
      // Full stops only: a colon or a semicolon is a list being
      // introduced, and splitting on one separates a number from the noun it
      // counts - which is how 'Box contains: 36 packs' becomes 36 orphans.
      for (final String piece in chunk.split(RegExp(r'(?<=[.!?])\s+'))) {
        final line = piece.trim();
        if (line.isNotEmpty) lines.add(line.toLowerCase());
      }
    }
    if (lines.isEmpty) return null;

    var packs = 0;
    var perPack = 0;
    for (int i = 0; i < lines.length; i++) {
      if (perPack == 0 && _statesContents(lines[i], 'packs?')) {
        perPack = _countUnder(lines, i, _cardCount);
      }
      if (packs == 0 && _statesContents(lines[i], 'box(?:es)?|display')) {
        packs = _countUnder(lines, i, _packCount);
      }
    }
    if (packs == 0 && perPack == 0) return null;
    return BoxComposition(packs: packs, cardsPerPack: perPack);
  }

  /// The first count in a line, or in the two lines under it.
  ///
  /// A heading is followed by the list it introduces, so the number that
  /// belongs to the noun in the heading is usually one line down. Two lines is
  /// as far as this looks: further than that and it is reading someone else's
  /// bullet.
  static int _countUnder(List<String> lines, int at, RegExp pattern) {
    for (int i = at; i < at + 3 && i < lines.length; i++) {
      final match = pattern.firstMatch(lines[i]);
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!);
      if (value != null && value > 0) return value;
    }
    return 0;
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

/// What stops a box being valued as cards.
///
/// Four different things, and they call for four different actions: stating
/// what the box holds, saying which set it is, downloading the set, or waiting
/// for a price list to quote a set nobody has quoted yet. One is the
/// collector's to fix, two are a tap, and one is nobody's fault - so they are
/// not one message.
enum BoxBlocker {
  /// Nobody has said what the box holds.
  noComposition('No composition stated'),

  /// The holding does not say which set it belongs to.
  noSet('No set recorded'),

  /// The set the box belongs to is not on the phone.
  setNotDownloaded('Set not downloaded'),

  /// The set is here and holds nothing anything has priced.
  nothingPriced('Nothing in the set is priced');

  const BoxBlocker(this.label);

  /// How it reads on screen.
  final String label;
}

/// One sealed holding valued both ways: kept shut, and opened.
class BoxOpening {
  /// Creates a valued holding.
  const BoxOpening({
    required this.name,
    required this.setCode,
    required this.quantity,
    this.holdingId,
    this.productId = '',
    this.price,
    this.composition,
    this.ev,
    this.blocker,
  });

  /// The shelf row this is about, so a screen can find it again.
  ///
  /// Two boxes of the same set and product are two holdings with one
  /// composition, and their values differ by quantity - so a name is not
  /// enough to hang a figure on.
  final int? holdingId;

  /// The price list's own id for the product, so a screen opened from this
  /// row can pick the same box out of the price list again.
  final String productId;

  /// What the holding is worth kept shut, or null when nothing has priced it.
  final double? price;

  /// The product's name, as the shelf has it.
  final String name;

  /// The set it belongs to, which is what a composition is filed under.
  final String setCode;

  /// How many are held.
  final int quantity;

  /// What the collector said the box holds, when they have said it.
  final BoxComposition? composition;

  /// What one box is worth opened, when it could be worked out.
  final BoxEv? ev;

  /// Why it could not be, when it could not.
  final BoxBlocker? blocker;

  /// What all the copies are worth opened, or null when the answer is unknown.
  ///
  /// Null and not zero: a box whose contents nobody can price is not a box
  /// holding nothing, and a shelf that counted it as one would report a total
  /// its own detail contradicts.
  double? get opened {
    final one = ev;
    if (one == null || !one.isComputable) return null;
    return one.expected * quantity;
  }

  /// What one box is worth opened, or null when it is unknown.
  double? get openedEach => opened == null ? null : opened! / quantity;
}

/// A game's boxes, valued both ways.
///
/// The point of the whole feature in one line: a shelf has a price and a
/// contents, and they are not the same number. Two things keep this honest.
/// Every total is over the boxes it is actually known for, and says how many
/// that was - an unpriced box is not a box worth nothing. And the comparison is
/// taken only over the boxes where both sides are known, because subtracting a
/// total from a different total is how a valuation ends up quietly wrong.
class BoxShelf {
  const BoxShelf._({
    required this.openings,
    required this.opened,
    required this.openedCount,
    required this.sealed,
    required this.sealedCount,
    required this.sealedBoth,
    required this.openedBoth,
    required this.bothCount,
    required this.cost,
    required this.costCount,
  });

  /// An empty shelf.
  static const BoxShelf empty = BoxShelf._(
    openings: <BoxOpening>[],
    opened: 0,
    openedCount: 0,
    sealed: 0,
    sealedCount: 0,
    sealedBoth: 0,
    openedBoth: 0,
    bothCount: 0,
    cost: null,
    costCount: 0,
  );

  /// Values a shelf from what the app knows about each of its boxes.
  ///
  /// [compositions] and [cards] are keyed by set code. A set missing from
  /// [cards] is a set that is not on the phone, which is a different problem
  /// from a set nothing has priced, and [BoxBlocker] keeps the two apart.
  factory BoxShelf.of({
    required List<SealedHolding> holdings,
    required Map<String, BoxComposition> compositions,
    required Map<String, List<TcgCard>> cards,
  }) {
    final openings = <BoxOpening>[];
    var opened = 0.0;
    var openedCount = 0;
    var sealed = 0.0;
    var sealedCount = 0;
    var sealedBoth = 0.0;
    var openedBoth = 0.0;
    var bothCount = 0;
    var cost = 0.0;
    var costCount = 0;

    for (final SealedHolding holding in holdings) {
      final BoxComposition? composition = compositions[holding.setCode];
      final List<TcgCard>? setCards = cards[holding.setCode];
      BoxEv? ev;
      BoxBlocker? blocker;
      if (holding.setCode.isEmpty) {
        blocker = BoxBlocker.noSet;
      } else if (composition == null || composition.isEmpty) {
        blocker = BoxBlocker.noComposition;
      } else if (setCards == null) {
        blocker = BoxBlocker.setNotDownloaded;
      } else {
        final worked = BoxEv.of(
          cards: setCards,
          composition: composition,
          boxPrice: holding.unitValue,
        );
        if (worked.isComputable) {
          ev = worked;
        } else {
          blocker = BoxBlocker.nothingPriced;
        }
      }

      final opening = BoxOpening(
        holdingId: holding.id,
        productId: holding.productId,
        price: holding.unitValue,
        name: holding.name,
        setCode: holding.setCode,
        quantity: holding.quantity,
        composition: composition,
        ev: ev,
        blocker: blocker,
      );
      openings.add(opening);

      final openEach = opening.openedEach;
      final shutEach = holding.unitValue;
      if (openEach != null) {
        opened += openEach * holding.quantity;
        openedCount++;
      }
      if (shutEach != null) {
        sealed += shutEach * holding.quantity;
        sealedCount++;
      }
      if (openEach != null && shutEach != null) {
        openedBoth += openEach * holding.quantity;
        sealedBoth += shutEach * holding.quantity;
        bothCount++;
      }
      final paidEach = holding.unitCost;
      if (openEach != null && paidEach != null) {
        cost += paidEach * holding.quantity;
        costCount++;
      }
    }

    return BoxShelf._(
      openings: openings,
      opened: opened,
      openedCount: openedCount,
      sealed: sealed,
      sealedCount: sealedCount,
      sealedBoth: sealedBoth,
      openedBoth: openedBoth,
      bothCount: bothCount,
      cost: costCount == 0 ? null : cost,
      costCount: costCount,
    );
  }

  /// Every box held, in shelf order.
  final List<BoxOpening> openings;

  /// What every box whose contents could be valued is worth opened, and how
  /// many boxes that covers.
  final double opened;
  final int openedCount;

  /// What every box a price list has priced is worth kept shut, and how many
  /// boxes that covers.
  final double sealed;
  final int sealedCount;

  /// The two sides added up over the boxes where both are known, which is the
  /// only pair of numbers that may be subtracted from each other.
  final double sealedBoth;
  final double openedBoth;
  final int bothCount;

  /// What the boxes with both a contents value and a recorded cost cost, and
  /// how many that covers.
  final double? cost;
  final int costCount;

  /// The boxes that could not be valued as cards.
  List<BoxOpening> get unvalued => <BoxOpening>[
    for (final BoxOpening o in openings)
      if (o.opened == null) o,
  ];

  /// How many physical boxes are held, counting quantity.
  int get boxes {
    var n = 0;
    for (final BoxOpening o in openings) {
      n += o.quantity;
    }
    return n;
  }

  /// Whether there is anything to say.
  bool get isEmpty => openings.isEmpty;

  /// Whether at least one box can be compared both ways.
  bool get hasAnswer => bothCount > 0;

  /// What opening the comparable boxes is worth against keeping them shut.
  double get difference => openedBoth - sealedBoth;

  /// Whether, on the boxes that can be compared, opening pays better.
  bool get openingPays => difference > 0;

  /// What the boxes with a recorded cost have made against what they cost.
  double? get againstCost => cost == null ? null : opened - cost!;

  /// The boxes held with no composition stated, which is the one blocker the
  /// collector can clear.
  List<BoxOpening> get unstated => <BoxOpening>[
    for (final BoxOpening o in openings)
      if (o.blocker == BoxBlocker.noComposition) o,
  ];
}
