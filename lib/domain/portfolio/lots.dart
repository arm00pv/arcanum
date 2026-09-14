import 'package:arcanum/domain/models/card_game.dart';

/// A purchase of cards, kept as the purchase rather than as an average.
///
/// The collection has always stored what a stack cost, which answers "what is
/// this worth against what I paid" and cannot answer the other half of the
/// question: what a *part* of that stack cost when part of it is sold. A stack
/// of four bought at two dollars and four more bought at five is an average of
/// three and a half until two of them are sold, at which point the average is
/// the wrong number for both the money that came in and the money that is still
/// sitting in the binder.
///
/// A lot is one purchase: [quantity] copies at [unitCost] each on [acquiredOn].
/// Copies leave a lot in the order they were bought, and what they cost is what
/// they realised against.
class CardLot {
  /// Creates a lot. [id] is null until it has been stored once.
  const CardLot({
    this.id,
    required this.game,
    required this.cardId,
    required this.quantity,
    this.entryId,
    this.unitCost,
    this.acquiredOn,
    this.note = '',
  });

  /// The database row id, null before it is first stored.
  final int? id;

  /// Which game's collection the lot is in.
  final CardGame game;

  /// The stack the copies are in, when they are in one.
  final int? entryId;

  /// The printing this lot bought.
  final String cardId;

  /// How many copies of the lot are still in the collection.
  final int quantity;

  /// What one copy cost, or null when the collector did not record it.
  final double? unitCost;

  /// When the copies were bought, or null when it was not recorded.
  final DateTime? acquiredOn;

  /// Anything worth remembering about the purchase: the shop, the lot number.
  final String note;

  /// What the remaining copies cost, or null when the price was not recorded.
  double? get cost => unitCost == null ? null : unitCost! * quantity;

  /// A copy with some fields replaced.
  CardLot copyWith({
    int? id,
    CardGame? game,
    String? cardId,
    int? entryId,
    int? quantity,
    double? unitCost,
    DateTime? acquiredOn,
    String? note,
  }) => CardLot(
    id: id ?? this.id,
    game: game ?? this.game,
    cardId: cardId ?? this.cardId,
    entryId: entryId ?? this.entryId,
    quantity: quantity ?? this.quantity,
    unitCost: unitCost ?? this.unitCost,
    acquiredOn: acquiredOn ?? this.acquiredOn,
    note: note ?? this.note,
  );

  /// The database row.
  Map<String, Object?> toRow() => <String, Object?>{
    if (id != null) 'id': id,
    'game': game.id,
    'card_id': cardId,
    'entry_id': entryId,
    'quantity': quantity,
    'unit_cost': unitCost,
    'acquired_on': acquiredOn?.millisecondsSinceEpoch,
    'note': note,
  };

  /// Reads a row back.
  static CardLot fromRow(Map<String, Object?> row, {required CardGame game}) =>
      CardLot(
        id: (row['id'] as num?)?.toInt(),
        game: game,
        cardId: row['card_id'] as String? ?? '',
        entryId: (row['entry_id'] as num?)?.toInt(),
        quantity: (row['quantity'] as num?)?.toInt() ?? 0,
        unitCost: (row['unit_cost'] as num?)?.toDouble(),
        acquiredOn: switch ((row['acquired_on'] as num?)?.toInt()) {
          final int at => DateTime.fromMillisecondsSinceEpoch(at),
          null => null,
        },
        note: row['note'] as String? ?? '',
      );

  @override
  String toString() =>
      'CardLot($quantity x $cardId at ${unitCost ?? '-'}, $acquiredOn)';
}

/// One lot's share of a disposal.
class LotMatch {
  /// Creates a match.
  const LotMatch({
    required this.lotId,
    required this.quantity,
    required this.unitCost,
    this.acquiredOn,
  });

  /// The lot the copies came out of, or null for a lot that was never stored.
  final int? lotId;

  /// How many copies came out of it.
  final int quantity;

  /// What one of them cost, or null when the purchase price was not recorded.
  final double? unitCost;

  /// When that lot was bought, kept so a sale can say which purchases it came
  /// out of and so undoing the sale can put the purchases back as they were.
  final DateTime? acquiredOn;

  /// What those copies cost, or null when the price was not recorded.
  double? get cost => unitCost == null ? null : unitCost! * quantity;
}

/// The lots a disposal came out of, and the lots that are left.
class FifoMatch {
  /// Creates a match result.
  const FifoMatch({
    required this.matches,
    required this.remaining,
    required this.unmatched,
  });

  /// Which lots the copies came out of, oldest first.
  final List<LotMatch> matches;

  /// Every lot after the disposal, including the emptied ones.
  final List<CardLot> remaining;

  /// Copies the collection held but no lot could account for: a stack that was
  /// recorded without a purchase, or one whose lots were never migrated.
  final int unmatched;

  /// What the disposed copies cost, or null when it is not fully known.
  ///
  /// A cost that is a mixture of known and unknown prices is not a cost: the
  /// gain it would produce would be part real and part invented, and the tax
  /// sheet says so rather than quietly reporting the part it does know.
  double? get cost {
    if (matches.isEmpty || unmatched > 0) return null;
    var total = 0.0;
    for (final match in matches) {
      final matchCost = match.cost;
      if (matchCost == null) return null;
      total += matchCost;
    }
    return total;
  }

  /// Whether every disposed copy had a recorded cost.
  bool get costKnown => cost != null;

  /// How many copies the disposal asked for.
  int get disposed =>
      matches.fold<int>(0, (int a, LotMatch m) => a + m.quantity);
}

/// Takes [quantity] copies out of [lots], oldest purchase first.
///
/// This is the first-in-first-out rule, and it is the default because it is the
/// one an accountant assumes when nothing else is said. A lot with no purchase
/// date sorts last rather than first: an undated purchase is not evidence that
/// it was the oldest one.
///
/// The lots are not modified: the answer carries the lots that are left so a
/// caller can store them, which keeps the arithmetic in one place and testable
/// without a database.
FifoMatch matchFifo(List<CardLot> lots, int quantity) {
  final ordered = <CardLot>[...lots]
    ..sort((CardLot a, CardLot b) {
      final left = a.acquiredOn;
      final right = b.acquiredOn;
      if (left != right) {
        if (left == null) return 1;
        if (right == null) return -1;
        final byDate = left.compareTo(right);
        if (byDate != 0) return byDate;
      }
      return (a.id ?? 0).compareTo(b.id ?? 0);
    });

  final matches = <LotMatch>[];
  final remaining = <CardLot>[];
  var left = quantity < 0 ? 0 : quantity;
  var unmatched = 0;

  for (final lot in ordered) {
    if (left <= 0) {
      remaining.add(lot);
      continue;
    }
    if (lot.quantity <= 0) {
      remaining.add(lot);
      continue;
    }
    final taken = lot.quantity < left ? lot.quantity : left;
    matches.add(
      LotMatch(
        lotId: lot.id,
        quantity: taken,
        unitCost: lot.unitCost,
        acquiredOn: lot.acquiredOn,
      ),
    );
    left -= taken;
    remaining.add(lot.copyWith(quantity: lot.quantity - taken));
  }

  if (left > 0) unmatched = left;
  return FifoMatch(
    matches: matches,
    remaining: remaining,
    unmatched: unmatched,
  );
}
