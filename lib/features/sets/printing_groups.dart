import 'package:arcanum/domain/models/tcg_card.dart';

/// One binder slot: every printing of a card that shares a collector number.
///
/// Yu-Gi-Oh! prints a single card several times inside one set - at different
/// rarities, and for different regions, each of which the provider prices
/// separately. Blue-Eyes White Dragon in Legend of Blue Eyes White Dragon is
/// three rows (LOB-000, LOB-E000, LOB-EN000), all number 001, worth $62.15,
/// $681.50 and $0.14 respectively.
///
/// Those are genuinely different cards to own, so the collection still stores
/// them separately. But a collector looking at a set is looking for a slot in a
/// binder, and three tiles that differ only in small print is noise rather than
/// information. A slot is that binder position: one row on screen, with the
/// versions and their prices inside it.
///
/// Magic and Pokemon print a card once per set, so there a slot holds a single
/// printing and nothing about those games changes.
class PrintingSlot {
  const PrintingSlot({
    required this.name,
    required this.collectorNumber,
    required this.printings,
  });

  /// The card's name, as the provider prints it.
  final String name;

  /// The number printed on the card. Versions of one card share it.
  final String collectorNumber;

  /// Every version of this card at this number, cheapest first.
  final List<TcgCard> printings;

  /// How many versions the slot holds.
  int get versionCount => printings.length;

  /// Whether the number covers more than one version.
  bool get hasVersions => printings.length > 1;

  /// The version a tap should open by default.
  ///
  /// The cheapest priced one, because that is the version a collector is most
  /// likely to be holding and the one the headline price should describe. Rows
  /// the provider prices at nothing are passed over rather than leading.
  TcgCard get primary {
    for (final printing in printings) {
      if (printing.prices.from != null) return printing;
    }
    return printings.first;
  }

  /// The lowest price across the versions, or null when none is priced.
  double? get lowestPrice {
    double? best;
    for (final printing in printings) {
      final price = printing.prices.from;
      if (price == null) continue;
      if (best == null || price < best) best = price;
    }
    return best;
  }

  /// The highest price across the versions, or null when none is priced.
  double? get highestPrice {
    double? best;
    for (final printing in printings) {
      final price = printing.prices.from;
      if (price == null) continue;
      if (best == null || price > best) best = price;
    }
    return best;
  }

  /// Whether the versions are worth different money.
  ///
  /// True when the cheapest and dearest differ, which is exactly when a single
  /// headline price would be misleading.
  bool get hasPriceSpread {
    final low = lowestPrice;
    final high = highestPrice;
    return low != null && high != null && high > low;
  }

  /// The number of physical cards owned across every version of this slot.
  int ownedWith(Map<String, int> ownedByPrintingId) {
    var total = 0;
    for (final printing in printings) {
      total += ownedByPrintingId[printing.id] ?? 0;
    }
    return total;
  }
}

/// Collapses a set's printings into binder slots, in the order given.
///
/// Order is preserved from the input rather than recomputed, because a set
/// arrives already sorted by collector number and a slot should sit where its
/// first printing sat. Two printings share a slot when their numbers match and
/// one name is the other with a treatment on it, which is the identity a
/// collector uses when filing them.
///
/// The number alone is not the identity, because a number is not always one
/// card: Gundam's ST01-002 is 'Gundam (MA Form)' and nothing else shares it,
/// while Yu-Gi-Oh! reuses a number across regions for the same card. And the
/// name alone is not the identity either, which is the bug this key fixes:
/// TCGplayer lists Gundam's parallel treatments as separate products with the
/// treatment in brackets - 'V2 Gundam' and 'V2 Gundam (LR+)' are both GD05-001 -
/// so a set read 202 rows wide showed two tiles for one slot in the binder, at
/// two prices, and looked like a catalogue listing the same card twice.
List<PrintingSlot> groupIntoSlots(List<TcgCard> cards) {
  final slots = <String, List<TcgCard>>{};
  final order = <String>[];

  for (final card in cards) {
    final key = '${_baseName(card.name)}#${card.collectorNumber}';
    final bucket = slots.putIfAbsent(key, () {
      order.add(key);
      return <TcgCard>[];
    });
    bucket.add(card);
  }

  return <PrintingSlot>[
    for (final key in order)
      PrintingSlot(
        // The slot is named by the version leading it, which is the cheapest
        // priced one: a slot headed 'V2 Gundam (LR+)' would name the treatment
        // as though it were the card.
        name: _cheapestFirst(slots[key]!).first.name,
        collectorNumber: slots[key]!.first.collectorNumber,
        printings: _cheapestFirst(slots[key]!),
      ),
  ];
}

/// A card's name with its treatment taken off, normalised for comparison.
///
/// Providers write a treatment in brackets after the card's own name -
/// 'Gundam (LR+)', 'Trafalgar Law (002) (Parallel)', 'Solemn Judgment (Quarter
/// Century Secret Rare)'. The bracketed part is what makes two rows different
/// products; the part before it is what makes them the same card. Stripping it
/// is what lets two treatments of one number share a binder slot, and it never
/// merges two numbers, which is the boundary that keeps different cards apart.
///
/// A name that is nothing but brackets keeps them: '()' is not a card name, and
/// an empty key would file it with every other unnamed row.
String _baseName(String name) {
  final stripped = name.replaceAll(RegExp(r'\s*\([^)]*\)'), ' ').trim();
  return TcgCard.normaliseName(stripped.isEmpty ? name : stripped);
}

/// Orders a slot's versions from cheapest to dearest.
///
/// Unpriced versions sort last rather than as zero, so a version the provider
/// has no market data for never appears to be the cheapest thing in the slot.
List<TcgCard> _cheapestFirst(List<TcgCard> printings) {
  final sorted = <TcgCard>[...printings];
  sorted.sort((a, b) {
    final left = a.prices.from;
    final right = b.prices.from;
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return left.compareTo(right);
  });
  return sorted;
}
