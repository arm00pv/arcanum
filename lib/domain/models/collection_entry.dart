import 'package:arcanum/core/theme/mana.dart';

/// One physical stack of identical cards in the user's collection.
///
/// An entry is keyed by the physical identity of the cards it holds
/// (printing + finish + condition + language + binder), so a Near Mint foil and
/// a Played non-foil of the same printing are two separate entries. This is how
/// collectors actually store and value cards, and it is what makes per-entry
/// valuation meaningful.
class CollectionEntry {
  const CollectionEntry({
    this.id,
    required this.cardId,
    this.finish = CardFinish.nonfoil,
    this.condition = CardCondition.nearMint,
    this.language = 'en',
    this.quantity = 1,
    this.purchasePrice,
    this.purchaseDate,
    this.binder = '',
    this.notes,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Row id, null until persisted.
  final int? id;

  /// Scryfall printing id (`cards.id`).
  final String cardId;

  final CardFinish finish;
  final CardCondition condition;

  /// ISO 639-1 language code of the physical card.
  final String language;

  final int quantity;

  /// What the user paid per copy, if they recorded it. Used for P/L.
  final double? purchasePrice;
  final DateTime? purchaseDate;

  /// Free-form storage location, e.g. "Binder A - Red".
  final String binder;

  final String? notes;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isFoil => finish != CardFinish.nonfoil;

  /// Cost basis for this whole stack, or null when no purchase price is known.
  double? get totalCost =>
      purchasePrice == null ? null : purchasePrice! * quantity;

  CollectionEntry copyWith({
    int? id,
    String? cardId,
    CardFinish? finish,
    CardCondition? condition,
    String? language,
    int? quantity,
    Object? purchasePrice = _unset,
    Object? purchaseDate = _unset,
    String? binder,
    Object? notes = _unset,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CollectionEntry(
      id: id ?? this.id,
      cardId: cardId ?? this.cardId,
      finish: finish ?? this.finish,
      condition: condition ?? this.condition,
      language: language ?? this.language,
      quantity: quantity ?? this.quantity,
      purchasePrice: purchasePrice == _unset
          ? this.purchasePrice
          : purchasePrice as double?,
      purchaseDate: purchaseDate == _unset
          ? this.purchaseDate
          : purchaseDate as DateTime?,
      binder: binder ?? this.binder,
      notes: notes == _unset ? this.notes : notes as String?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const _unset = Object();

  Map<String, Object?> toRow() => {
    if (id != null) 'id': id,
    'card_id': cardId,
    'finish': finish.code,
    'condition': condition.code,
    'language': language,
    'quantity': quantity,
    'purchase_price': purchasePrice,
    'purchase_date': purchaseDate?.millisecondsSinceEpoch,
    'binder': binder,
    'notes': notes,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory CollectionEntry.fromRow(Map<String, Object?> r) => CollectionEntry(
    id: r['id'] as int?,
    cardId: r['card_id'] as String,
    finish: CardFinish.fromCode(r['finish'] as String?),
    condition: CardCondition.fromCode(r['condition'] as String?),
    language: (r['language'] as String?) ?? 'en',
    quantity: (r['quantity'] as int?) ?? 1,
    purchasePrice: (r['purchase_price'] as num?)?.toDouble(),
    purchaseDate: r['purchase_date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['purchase_date'] as int),
    binder: (r['binder'] as String?) ?? '',
    notes: r['notes'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (r['created_at'] as int?) ?? 0,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      (r['updated_at'] as int?) ?? 0,
    ),
  );

  @override
  bool operator ==(Object other) =>
      other is CollectionEntry &&
      other.id == id &&
      other.cardId == cardId &&
      other.finish == finish &&
      other.condition == condition &&
      other.language == language &&
      other.binder == binder;

  @override
  int get hashCode =>
      Object.hash(id, cardId, finish, condition, language, binder);
}

/// A collection entry joined with the live market value of one copy.
class ValuedEntry {
  const ValuedEntry({
    required this.entry,
    required this.unitValue,
    this.dayChangePercent,
    this.trendScore,
  });

  final CollectionEntry entry;

  /// Market value of a single copy, already adjusted for finish and condition.
  final double? unitValue;

  /// Percentage change of the underlying price over the last day, if known.
  final double? dayChangePercent;

  /// Composite 0-100 trend score for this printing, if computed.
  final double? trendScore;

  /// Total value of the stack.
  double? get totalValue =>
      unitValue == null ? null : unitValue! * entry.quantity;

  /// Unrealised profit/loss for the stack, or null without a cost basis.
  double? get profit {
    final cost = entry.totalCost;
    final value = totalValue;
    if (cost == null || value == null) return null;
    return value - cost;
  }

  /// Unrealised return as a percentage, or null without a cost basis.
  double? get profitPercent {
    final cost = entry.totalCost;
    final p = profit;
    if (cost == null || p == null || cost <= 0) return null;
    return p / cost * 100.0;
  }
}
