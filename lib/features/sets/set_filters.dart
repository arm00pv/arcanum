import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/features/sets/printing_groups.dart';

/// A numeric window over prices, plus whether unpriced cards are wanted.
///
/// Windows are half-open: \`min\` is included and \`max\` is excluded. A card
/// worth exactly $5.00 therefore sits in "$5 - $20" and not also in
/// "$1 - $5", so the band counts on screen add up to the set rather than
/// double-counting the boundaries.
class PriceWindow {
  const PriceWindow({this.min, this.max, this.unpriced = false});

  /// Lowest price to include, or null for no floor.
  final double? min;

  /// Price the window stops at, or null for no ceiling.
  final double? max;

  /// Whether slots the provider prices at nothing are in the window.
  ///
  /// They are excluded from a numeric window by default: a card with no market
  /// data cannot be said to be worth under a dollar, and quietly listing it
  /// under one would be an invented number.
  final bool unpriced;

  /// A window holding nothing, used for "no price filter at all".
  static const PriceWindow unpricedOnly = PriceWindow(unpriced: true);

  /// Whether the window constrains anything numerically.
  bool get hasNumberBound => min != null || max != null;

  /// Whether the window would admit anything at all.
  bool get isEmpty => !hasNumberBound && !unpriced;

  /// Whether a single price falls inside the numeric window.
  ///
  /// A window with no numeric bounds contains no price at all, which is what
  /// the "no price" band is: it selects by the absence of a price, and a
  /// card worth \$3 is not in it however unbounded the window looks.
  bool contains(double price) {
    if (!hasNumberBound) return false;
    if (min != null && price < min!) return false;
    if (max != null && price >= max!) return false;
    return true;
  }

  /// Whether any version of a slot falls inside the window.
  bool matches(PrintingSlot slot) {
    if (hasNumberBound) {
      for (final printing in slot.printings) {
        final price = printing.prices.from;
        if (price != null && contains(price)) return true;
      }
    }
    return unpriced && slot.lowestPrice == null;
  }

  @override
  bool operator ==(Object other) =>
      other is PriceWindow &&
      other.min == min &&
      other.max == max &&
      other.unpriced == unpriced;

  @override
  int get hashCode => Object.hash(min, max, unpriced);
}

/// The price bands a collector actually shops in.
///
/// A free range slider is the wrong primary control on a phone: it cannot be
/// dragged precisely, and the distribution of a set's prices is so skewed that
/// a linear slider puts nine tenths of the cards in the first fifth of its
/// travel. Bands are the shape of the answer, and a custom range is offered
/// underneath for the collector who wants one.
enum PriceBand {
  under(r'Under $1', PriceWindow(max: 1)),
  low(r'$1 - $5', PriceWindow(min: 1, max: 5)),
  mid(r'$5 - $20', PriceWindow(min: 5, max: 20)),
  high(r'$20 - $100', PriceWindow(min: 20, max: 100)),
  top(r'$100+', PriceWindow(min: 100)),
  unpriced('No price', PriceWindow(unpriced: true));

  const PriceBand(this.label, this.window);

  /// What the band is called on screen.
  final String label;

  /// The window the band selects.
  final PriceWindow window;

  /// Whether the band is a price range rather than the absence of a price.
  bool get hasNumericWindow => window.hasNumberBound;

  /// The band a window corresponds to exactly, or null for a custom range.
  static PriceBand? matching(PriceWindow window) {
    for (final band in PriceBand.values) {
      if (band.window == window) return band;
    }
    return null;
  }
}

/// A short description of a price window, for a chip or a summary line.
///
/// A window that happens to equal a band is named after the band, so the chip
/// on the screen and the option in the sheet use the same words.
String describePrice(PriceWindow? window) {
  if (window == null || window.isEmpty) return 'Any price';
  final band = PriceBand.matching(window);
  if (band != null) return band.label;
  final low = window.min == null ? 'Any' : Fmt.money(window.min);
  final high = window.max == null ? 'Any' : Fmt.money(window.max);
  return '$low - $high';
}

/// How the grid is ordered once it has been filtered.
enum SetSort {
  /// Collector-number order, which is the order a binder is filed in.
  number('Binder order'),

  /// Cheapest first, so the budget end of the set reads first.
  priceLow('Price \u2191'),

  /// Dearest first, which is how a "what is worth money here" pass is made.
  priceHigh('Price \u2193'),

  /// Alphabetical, for looking a card up by name.
  name('Name');

  const SetSort(this.label);

  /// What the order is called on screen.
  final String label;
}

/// What a collector has asked to see in a set, and in what order.
///
/// This is deliberately a value rather than a pile of widget state: it is what
/// the tests exercise, and it is the thing the screen keeps so that reopening
/// the sheet shows what is already on.
class SetFilter {
  const SetFilter({
    this.price,
    this.rarities = const <String>{},
    this.sort = SetSort.number,
  });

  /// The price window, or null when price is not being filtered on.
  ///
  /// A slot matches when *any* of its versions falls in the window. That is the
  /// useful reading: the versions of a binder slot are worth wildly different
  /// money - Blue-Eyes White Dragon in Legend of Blue Eyes is $0.14, $62.15
  /// and $681.50 - so a slot belongs both to "under a dollar" and to "$100+",
  /// because a collector holding either version wants to find it.
  final PriceWindow? price;

  /// Provider rarity strings to keep, empty for all of them.
  ///
  /// The provider's own string rather than the display tier, because Yu-Gi-Oh!
  /// prints Super, Ultra, Secret, Ultimate and Starlight Rare, all of which
  /// collapse onto one "Rare" tier and would be indistinguishable here.
  final Set<String> rarities;

  /// The order to show the survivors in.
  final SetSort sort;

  /// Whether anything is being filtered or reordered.
  bool get isActive =>
      price != null || rarities.isNotEmpty || sort != SetSort.number;

  /// Whether the price side of the filter is doing anything.
  bool get filtersPrice => price != null && !price!.isEmpty;

  /// How many controls are set, for the badge on the filter button.
  int get activeCount =>
      (filtersPrice ? 1 : 0) + (rarities.isEmpty ? 0 : 1) + (sort == SetSort.number ? 0 : 1);

  /// Whether a slot survives the filter.
  bool matches(PrintingSlot slot) {
    final window = price;
    if (window != null && !window.matches(slot)) return false;
    if (rarities.isNotEmpty) {
      final keep = slot.printings.any((card) => rarities.contains(card.rarity));
      if (!keep) return false;
    }
    return true;
  }

  /// The filtered and reordered slots, ready to render.
  ///
  /// Every order puts unpriced slots last, never first: a card the provider has
  /// no market data for is not the cheapest thing in the set, and listing it
  /// above a $0.14 card would say that it is.
  List<PrintingSlot> apply(List<PrintingSlot> slots) {
    final kept = slots.where(matches).toList();
    switch (sort) {
      case SetSort.number:
        return kept;
      case SetSort.priceLow:
        kept.sort((a, b) => _comparePrice(a, b, ascending: true));
      case SetSort.priceHigh:
        kept.sort((a, b) => _comparePrice(a, b, ascending: false));
      case SetSort.name:
        kept.sort((a, b) {
          final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          if (byName != 0) return byName;
          return a.collectorNumber.compareTo(b.collectorNumber);
        });
    }
    return kept;
  }

  /// The prices of a slot the collector can still see, cheapest first.
  ///
  /// Used to headline a tile: with "$100+" on, a tile reading "from $0.14"
  /// would describe a version the filter has just hidden.
  SlotPrice summarise(PrintingSlot slot) {
    final window = price;
    if (window == null || !window.hasNumberBound) {
      return SlotPrice(slot.lowestPrice, slot.highestPrice);
    }
    double? low;
    double? high;
    for (final printing in slot.printings) {
      final value = printing.prices.from;
      if (value == null || !window.contains(value)) continue;
      if (low == null || value < low) low = value;
      if (high == null || value > high) high = value;
    }
    if (low == null) return SlotPrice(slot.lowestPrice, slot.highestPrice);
    return SlotPrice(low, high);
  }

  /// The price a slot is ordered by.
  ///
  /// The price on show, not the slot's cheapest version: with "$100 and up" on,
  /// ordering Blue-Eyes by the 14-cent version the filter has hidden would put
  /// it above cards worth four times what the tile says it is worth.
  double? _sortPrice(PrintingSlot slot) {
    final window = price;
    if (window == null || !window.hasNumberBound) return slot.lowestPrice;
    return summarise(slot).low;
  }

  int _comparePrice(PrintingSlot a, PrintingSlot b, {required bool ascending}) {
    final left = _sortPrice(a);
    final right = _sortPrice(b);
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return ascending ? left.compareTo(right) : right.compareTo(left);
  }

  /// A copy with the price window replaced, or cleared by passing null.
  SetFilter withPrice(PriceWindow? window) => SetFilter(
        price: window,
        rarities: rarities,
        sort: sort,
      );

  /// A copy with one rarity toggled.
  SetFilter toggleRarity(String rarity) {
    final next = <String>{...rarities};
    if (!next.remove(rarity)) next.add(rarity);
    return SetFilter(price: price, rarities: next, sort: sort);
  }

  /// A copy with a different order.
  SetFilter withSort(SetSort order) =>
      SetFilter(price: price, rarities: rarities, sort: order);

  @override
  bool operator ==(Object other) =>
      other is SetFilter &&
      other.price == price &&
      other.sort == sort &&
      other.rarities.length == rarities.length &&
      other.rarities.containsAll(rarities);

  @override
  int get hashCode => Object.hash(price, sort, Object.hashAllUnordered(rarities));
}

/// What one slot's price should say once a filter has narrowed what is on show.
class SlotPrice {
  const SlotPrice(this.low, this.high);

  /// The cheapest price still on show, or null when there is none.
  final double? low;

  /// The dearest price still on show, or null when there is none.
  final double? high;

  /// Whether the versions on show are worth different money.
  bool get hasSpread => low != null && high != null && high! > low!;
}

/// The rarity strings a set actually uses, dearest tier first, with counts.
///
/// Offering every rarity the provider has ever printed would list options that
/// cannot appear; the facets are drawn from the set on screen so every chip is
/// a chip that can do something.
List<RarityFacet> rarityFacets(List<PrintingSlot> slots) {
  final counts = <String, int>{};
  for (final slot in slots) {
    for (final printing in slot.printings) {
      final key = rarityLabel(printing.rarity);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }
  final facets = <RarityFacet>[
    for (final entry in counts.entries)
      RarityFacet(rarity: entry.key, count: entry.value),
  ];
  facets.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    return a.rarity.compareTo(b.rarity);
  });
  return facets;
}

/// A rarity a set uses, and how many printings carry it.
class RarityFacet {
  const RarityFacet({required this.rarity, required this.count});

  /// The provider's rarity string, tidied for display.
  final String rarity;

  /// How many printings in the set carry it.
  final int count;
}

/// Tidies a provider rarity string for display.
///
/// Magic ships lower case (\`mythic\`) and Yu-Gi-Oh! ships it already titled
/// (\`Ultra Rare\`), so only an all-lower-case string is re-cased - running a
/// title case over the second kind would produce "Ultra Rare" intact anyway but
/// would wreck names that carry their own capitalisation.
String rarityLabel(String rarity) {
  final trimmed = rarity.trim();
  if (trimmed.isEmpty) return 'Unknown';
  if (trimmed != trimmed.toLowerCase()) return trimmed;
  return trimmed
      .split(RegExp(r'[\s_-]+'))
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .join(' ');
}

/// A round number at or above a set's dearest card, for a slider's top end.
///
/// A slider that ends at $681.50 has no useful travel; picking the next round
/// number up keeps the handle where the collector expects it to be.
double niceCeil(double value) {
  if (value <= 0) return 1;

  // The decade the value falls in, then the round numbers inside it. Rounding
  // inside a decade rather than doubling from one keeps a set topping out at
  // \$92 from being given a \$160 slider: the handles land on 1, 2, 2.5, 5 and
  // 10 times a power of ten, which is how a price is read out loud.
  var magnitude = 1.0;
  while (magnitude * 10 <= value) {
    magnitude *= 10;
  }
  for (final step in const <double>[1, 2, 2.5, 5, 10]) {
    final candidate = magnitude * step;
    if (candidate >= value) return candidate;
  }
  return magnitude * 10;
}
