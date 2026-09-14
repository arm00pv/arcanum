import 'package:arcanum/domain/models/card_game.dart';

/// What kind of sealed product a holding is.
///
/// The categories are the ones a collector actually separates: a box and a pack
/// are the same set at wildly different prices, and a bundle or a precon is
/// neither. [other] exists because no list of product names is ever complete.
enum SealedCategory {
  /// A booster box: thirty-six packs, or thirty for the play boosters.
  boosterBox('box', 'Booster box'),

  /// A single booster pack.
  boosterPack('pack', 'Booster pack'),

  /// A bundle: a handful of packs with land and a die.
  bundle('bundle', 'Bundle'),

  /// A ready-made deck, commander or otherwise.
  deck('deck', 'Preconstructed deck'),

  /// A gift box, a secret lair, a collector's edition: sealed, and none of the
  /// above.
  other('other', 'Other sealed');

  const SealedCategory(this.id, this.label);

  /// The stable id stored in the database.
  final String id;

  /// How it reads on screen.
  final String label;

  /// Reads an id back, defaulting to [other] for anything unrecognised.
  static SealedCategory fromId(String? id) {
    for (final category in SealedCategory.values) {
      if (category.id == id) return category;
    }
    return SealedCategory.other;
  }

  /// Guesses the category from a product's name.
  ///
  /// Used when a product arrives from a price list rather than from the user,
  /// and it is only ever a first guess: the sheet that shows it lets the guess
  /// be corrected before anything is saved.
  static SealedCategory guess(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('booster box') || lower.contains('display')) {
      return SealedCategory.boosterBox;
    }
    if (lower.contains('bundle')) return SealedCategory.bundle;
    if (lower.contains('booster pack') || lower.contains('booster')) {
      return SealedCategory.boosterPack;
    }
    if (lower.contains('deck') ||
        lower.contains('commander') ||
        lower.contains('starter') ||
        lower.contains('precon')) {
      return SealedCategory.deck;
    }
    return SealedCategory.other;
  }
}

/// One sealed product the collector holds.
///
/// Sealed product is not a card: it has no finish, no condition and no binder
/// number, and a box is not interchangeable with its thirty-six packs. It is
/// therefore its own table and its own kind of holding, with quantity and a
/// price like everything else so that a valuation can add it up.
class SealedHolding {
  /// Creates a holding. [id] is null until it has been stored once.
  const SealedHolding({
    this.id,
    required this.game,
    required this.setCode,
    required this.setName,
    required this.name,
    required this.category,
    required this.quantity,
    this.unitCost,
    this.unitValue,
    this.valueAsOf,
    this.location = '',
    this.note = '',
    this.productId = '',
  });

  /// The database row id, null before it is first stored.
  final int? id;

  /// Which game's side of the app this belongs to.
  final CardGame game;

  /// The set code, which is how a sealed product is filed and searched.
  final String setCode;

  /// The set's name, kept beside the code so a holding is readable offline.
  final String setName;

  /// The product's name, as printed on the box or as the price list has it.
  final String name;

  /// What kind of product it is.
  final SealedCategory category;

  /// How many are held.
  final int quantity;

  /// What one cost, or null when the collector did not record it.
  final double? unitCost;

  /// What one is worth now, or null when nothing has priced it.
  final double? unitValue;

  /// When [unitValue] was last seen, so a stale figure is visibly stale.
  final DateTime? valueAsOf;

  /// Where it is kept: a shelf, a cupboard, a storage box.
  final String location;

  /// Anything else worth remembering.
  final String note;

  /// The price list's own id for this product, empty when it was typed by hand.
  final String productId;

  /// What all the copies are worth, or null when nothing has priced them.
  double? get totalValue => unitValue == null ? null : unitValue! * quantity;

  /// What all the copies cost, or null when nothing was recorded.
  double? get totalCost => unitCost == null ? null : unitCost! * quantity;

  /// What the holding has made or lost, or null when either side is missing.
  double? get profit {
    final value = totalValue;
    final cost = totalCost;
    if (value == null || cost == null) return null;
    return value - cost;
  }

  /// Whether anything has priced this holding.
  bool get isPriced => unitValue != null;

  /// A copy with some fields replaced.
  SealedHolding copyWith({
    int? id,
    String? setCode,
    String? setName,
    String? name,
    SealedCategory? category,
    int? quantity,
    double? unitCost,
    bool clearUnitCost = false,
    double? unitValue,
    bool clearUnitValue = false,
    DateTime? valueAsOf,
    String? location,
    String? note,
    String? productId,
  }) => SealedHolding(
    id: id ?? this.id,
    game: game,
    setCode: setCode ?? this.setCode,
    setName: setName ?? this.setName,
    name: name ?? this.name,
    category: category ?? this.category,
    quantity: quantity ?? this.quantity,
    unitCost: clearUnitCost ? null : (unitCost ?? this.unitCost),
    unitValue: clearUnitValue ? null : (unitValue ?? this.unitValue),
    valueAsOf: valueAsOf ?? this.valueAsOf,
    location: location ?? this.location,
    note: note ?? this.note,
    productId: productId ?? this.productId,
  );

  @override
  String toString() =>
      'SealedHolding($quantity x $name [$setCode], value=$unitValue)';
}

/// Sealed holdings for one game, added up.
class SealedPortfolio {
  /// Creates a portfolio view.
  const SealedPortfolio({
    required this.holdings,
    required this.totalValue,
    required this.totalCost,
    required this.unpriced,
  });

  /// Builds the totals from a list of holdings.
  factory SealedPortfolio.of(List<SealedHolding> holdings) {
    var value = 0.0;
    var cost = 0.0;
    var costed = 0;
    var unpriced = 0;
    for (final h in holdings) {
      final v = h.totalValue;
      final c = h.totalCost;
      if (v == null) {
        unpriced++;
      } else {
        value += v;
      }
      if (c != null) {
        cost += c;
        costed++;
      }
    }
    return SealedPortfolio(
      holdings: holdings,
      totalValue: value,
      totalCost: costed == 0 ? null : cost,
      unpriced: unpriced,
    );
  }

  /// The holdings, dearest first.
  final List<SealedHolding> holdings;

  /// What the priced holdings are worth.
  final double totalValue;

  /// What the recorded ones cost, or null when none has a cost.
  final double? totalCost;

  /// How many holdings nothing has priced.
  final int unpriced;

  /// How many physical products are held, counting quantity.
  int get totalItems {
    var n = 0;
    for (final h in holdings) {
      n += h.quantity;
    }
    return n;
  }

  /// What the sealed shelf has made or lost, or null when either side is
  /// missing.
  double? get profit {
    final cost = totalCost;
    if (cost == null) return null;
    return totalValue - cost;
  }

  /// Whether there is anything to show.
  bool get isEmpty => holdings.isEmpty;
}
