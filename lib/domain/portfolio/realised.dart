import 'dart:convert';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/lots.dart';

/// A sale the collector recorded: what left the collection, and for how much.
///
/// A sale is the only thing in the app that realises a gain. Deleting a stack
/// takes the cards off the shelf without saying what happened to them, and the
/// app will not invent a price for that; a sale says what came in, which is the
/// half of the arithmetic a tax return is about.
///
/// The lots a sale consumed are stored with it rather than being worked out
/// again later. A cost basis that moved every time a lot was edited would make
/// last year's return change after it was filed.
class CardSale {
  /// Creates a sale. [id] is null until it has been stored once.
  const CardSale({
    this.id,
    required this.game,
    required this.cardId,
    required this.quantity,
    required this.unitPrice,
    required this.soldOn,
    this.finish = CardFinish.nonfoil,
    this.condition = CardCondition.nearMint,
    this.fees = 0,
    this.platform = '',
    this.note = '',
    this.matches = const <LotMatch>[],
    this.entryId,
    this.language = 'en',
    this.binder = '',
    this.createdAt,
  });

  /// The database row id, null before it is first stored.
  final int? id;

  /// Which game's side of the app this was sold from.
  final CardGame game;

  /// The printing that was sold.
  final String cardId;

  /// How many copies.
  final int quantity;

  /// What one copy sold for, before fees.
  final double unitPrice;

  /// When it sold, which is the tax year it belongs to.
  final DateTime soldOn;

  /// Which finish the copies were.
  final CardFinish finish;

  /// What condition they were in.
  final CardCondition condition;

  /// What the sale cost to make: postage, a marketplace's cut, a card show's
  /// table. Subtracted from the proceeds, because it is money that did not
  /// arrive.
  final double fees;

  /// Where it sold: a marketplace, a shop, a person.
  final String platform;

  /// Anything else worth remembering.
  final String note;

  /// Which lots the copies came out of, oldest first.
  final List<LotMatch> matches;

  /// The stack the copies were taken out of.
  ///
  /// Kept so that undoing a sale puts the copies back where they were rather
  /// than into a stack of their own, and so a sale can be listed by binder.
  final int? entryId;

  /// The language of the copies, which is part of what a stack is.
  final String language;

  /// The binder or box the copies were in.
  final String binder;

  /// When the record was written.
  final DateTime? createdAt;

  /// What the buyer paid, before fees.
  double get gross => unitPrice * quantity;

  /// What actually arrived.
  double get proceeds => gross - fees;

  /// What the sold copies cost, or null when no purchase price was recorded.
  double? get cost {
    if (matches.isEmpty) return null;
    var total = 0.0;
    for (final match in matches) {
      final matchCost = match.cost;
      if (matchCost == null) return null;
      total += matchCost;
    }
    return total;
  }

  /// Whether every sold copy had a recorded cost.
  bool get costKnown => cost != null;

  /// What the sale made or lost, or null when the cost is not known.
  double? get gain {
    final basis = cost;
    return basis == null ? null : proceeds - basis;
  }

  /// A copy with some fields replaced.
  CardSale copyWith({
    int? id,
    CardGame? game,
    String? cardId,
    int? quantity,
    double? unitPrice,
    DateTime? soldOn,
    CardFinish? finish,
    CardCondition? condition,
    double? fees,
    String? platform,
    String? note,
    List<LotMatch>? matches,
    int? entryId,
    String? language,
    String? binder,
    DateTime? createdAt,
  }) => CardSale(
    id: id ?? this.id,
    game: game ?? this.game,
    cardId: cardId ?? this.cardId,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    soldOn: soldOn ?? this.soldOn,
    finish: finish ?? this.finish,
    condition: condition ?? this.condition,
    fees: fees ?? this.fees,
    platform: platform ?? this.platform,
    note: note ?? this.note,
    matches: matches ?? this.matches,
    entryId: entryId ?? this.entryId,
    language: language ?? this.language,
    binder: binder ?? this.binder,
    createdAt: createdAt ?? this.createdAt,
  );

  /// The database row, with the matched lots as JSON.
  ///
  /// The lots are stored with the sale rather than being worked out again from
  /// the lots table: a cost basis that moved when a purchase was edited would
  /// change a return that has already been filed.
  Map<String, Object?> toRow() => <String, Object?>{
    if (id != null) 'id': id,
    'game': game.id,
    'card_id': cardId,
    'quantity': quantity,
    'unit_price': unitPrice,
    'fees': fees,
    'finish': finish.code,
    'condition': condition.code,
    'sold_on': soldOn.millisecondsSinceEpoch,
    'platform': platform,
    'note': note,
    'entry_id': entryId,
    'language': language,
    'binder': binder,
    'matches': jsonEncode(<Map<String, Object?>>[
      for (final match in matches)
        <String, Object?>{
          'lot': match.lotId,
          'quantity': match.quantity,
          'cost': match.unitCost,
          'acquired': match.acquiredOn?.millisecondsSinceEpoch,
        },
    ]),
  };

  /// Reads a row back.
  static CardSale fromRow(Map<String, Object?> row, {required CardGame game}) =>
      CardSale(
        id: (row['id'] as num?)?.toInt(),
        game: game,
        cardId: row['card_id'] as String? ?? '',
        quantity: (row['quantity'] as num?)?.toInt() ?? 0,
        unitPrice: (row['unit_price'] as num?)?.toDouble() ?? 0,
        fees: (row['fees'] as num?)?.toDouble() ?? 0,
        finish: CardFinish.fromCode(row['finish'] as String?),
        condition: CardCondition.fromCode(row['condition'] as String?),
        soldOn: DateTime.fromMillisecondsSinceEpoch(
          (row['sold_on'] as num?)?.toInt() ?? 0,
        ),
        platform: row['platform'] as String? ?? '',
        note: row['note'] as String? ?? '',
        entryId: (row['entry_id'] as num?)?.toInt(),
        language: row['language'] as String? ?? 'en',
        binder: row['binder'] as String? ?? '',
        matches: _matchesFrom(row['matches'] as String?),
        createdAt: switch ((row['created_at'] as num?)?.toInt()) {
          final int at => DateTime.fromMillisecondsSinceEpoch(at),
          null => null,
        },
      );

  /// Reads the stored lot breakdown.
  ///
  /// Anything unreadable reads as no breakdown at all, which the sale reports
  /// as an unknown cost rather than as a gain of nothing.
  static List<LotMatch> _matchesFrom(String? raw) {
    if (raw == null || raw.isEmpty) return const <LotMatch>[];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const <LotMatch>[];
    }
    if (decoded is! List) return const <LotMatch>[];
    final out = <LotMatch>[];
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final quantity = (entry['quantity'] as num?)?.toInt() ?? 0;
      if (quantity <= 0) continue;
      out.add(
        LotMatch(
          lotId: (entry['lot'] as num?)?.toInt(),
          quantity: quantity,
          unitCost: (entry['cost'] as num?)?.toDouble(),
          acquiredOn: switch ((entry['acquired'] as num?)?.toInt()) {
            final int at => DateTime.fromMillisecondsSinceEpoch(at),
            null => null,
          },
        ),
      );
    }
    return out;
  }

  @override
  String toString() => 'CardSale($quantity x $cardId at $unitPrice on $soldOn)';
}

/// A sale joined to what it was of, which is what a list shows and what a
/// spreadsheet needs.
class SaleRow {
  /// Creates a row.
  const SaleRow({
    required this.sale,
    required this.name,
    required this.setCode,
    required this.setName,
  });

  /// The sale itself.
  final CardSale sale;

  /// The card's name.
  final String name;

  /// The set code the card prints.
  final String setCode;

  /// The set's name.
  final String setName;

  /// When it sold.
  DateTime get soldOn => sale.soldOn;

  /// What came in.
  double get proceeds => sale.proceeds;

  /// What it cost.
  double? get cost => sale.cost;

  /// What it made.
  double? get gain => sale.gain;
}

/// One tax year's sales, added up.
class RealisedYear {
  /// Creates a year. [rows] are that year's sales, newest first.
  const RealisedYear({required this.year, required this.rows});

  /// The calendar year, which is the tax year for a collector's cards in the
  /// places this app is used. Anything else needs a person, not a phone.
  final int year;

  /// The sales in it.
  final List<SaleRow> rows;

  /// How many copies were sold.
  int get copies =>
      rows.fold<int>(0, (int a, SaleRow r) => a + r.sale.quantity);

  /// How many sales were recorded.
  int get sales => rows.length;

  /// What arrived, fees taken off.
  double get proceeds =>
      rows.fold<double>(0, (double a, SaleRow r) => a + r.proceeds);

  /// What the sold copies cost, counting only the sales whose cost is known.
  double get cost =>
      rows.fold<double>(0, (double a, SaleRow r) => a + (r.cost ?? 0));

  /// What was made, counting only the sales whose cost is known.
  double get gain =>
      rows.fold<double>(0, (double a, SaleRow r) => a + (r.gain ?? 0));

  /// How many sales have no cost basis, and so contribute no gain.
  ///
  /// The number matters more than it looks: a year with four sales and one
  /// unknown cost has a total that is short by whatever that one cost, and a
  /// sheet that says so is worth more than one that quietly adds a zero.
  int get unknownCost => rows.where((SaleRow r) => !r.sale.costKnown).length;

  /// Whether every sale in the year has a cost basis.
  bool get everyCostKnown => unknownCost == 0;

  /// How many sales in the year have a cost basis.
  int get costedSales => rows.where((SaleRow r) => r.sale.costKnown).length;

  /// Whether any gain at all can be worked out for the year.
  ///
  /// False for a year whose every sale came out of a stack with no recorded
  /// purchase price. The money still arrived and is counted as proceeds; no
  /// gain can be worked out from it, and the screen says unknown rather than
  /// printing a zero that reads like a loss.
  bool get hasCostBasis => costedSales > 0;
}

/// Every year with sales in it, newest first.
class Realised {
  /// Creates the view.
  const Realised({required this.years});

  /// Groups rows by the year they sold in.
  factory Realised.of(List<SaleRow> rows) {
    final byYear = <int, List<SaleRow>>{};
    for (final row in rows) {
      byYear.putIfAbsent(row.soldOn.year, () => <SaleRow>[]).add(row);
    }
    final years = byYear.keys.toList()..sort((int a, int b) => b.compareTo(a));
    return Realised(
      years: <RealisedYear>[
        for (final year in years)
          RealisedYear(
            year: year,
            rows: byYear[year]!
              ..sort((SaleRow a, SaleRow b) => b.soldOn.compareTo(a.soldOn)),
          ),
      ],
    );
  }

  /// The years, newest first.
  final List<RealisedYear> years;

  /// Whether anything has been sold.
  bool get isEmpty => years.isEmpty;

  /// Every sale, newest first.
  List<SaleRow> get rows => <SaleRow>[for (final year in years) ...year.rows];

  /// The year asked for, or null.
  RealisedYear? year(int year) {
    for (final entry in years) {
      if (entry.year == year) return entry;
    }
    return null;
  }
}

/// A year's sales as a spreadsheet.
///
/// This is the tax-year export, and it is deliberately plain: one row per sale,
/// a header a person can read, dates as ISO 8601 so any locale's spreadsheet
/// parses them, and money as a bare number with two decimals. No currency
/// symbol, no thousands separator, no totals row - a total is something a
/// spreadsheet does better, and a symbol is something it does worse.
///
/// A sale whose cost basis was never recorded leaves the two cost columns
/// empty rather than zero. A zero would be a claim that the cards were free.
String salesCsv(List<SaleRow> rows) {
  const List<String> header = <String>[
    'Date',
    'Card',
    'Set',
    'Set code',
    'Finish',
    'Condition',
    'Quantity',
    'Unit price',
    'Fees',
    'Proceeds',
    'Cost basis',
    'Gain/loss',
    'Platform',
    'Note',
  ];
  final out = StringBuffer()..writeln(header.map(_cell).join(','));
  for (final row in rows) {
    final sale = row.sale;
    out.writeln(
      <String>[
        _isoDate(sale.soldOn),
        row.name,
        row.setName,
        row.setCode.toUpperCase(),
        sale.finish.label,
        sale.condition.label,
        sale.quantity.toString(),
        sale.unitPrice.toStringAsFixed(2),
        sale.fees.toStringAsFixed(2),
        sale.proceeds.toStringAsFixed(2),
        sale.cost == null ? '' : sale.cost!.toStringAsFixed(2),
        sale.gain == null ? '' : sale.gain!.toStringAsFixed(2),
        sale.platform,
        sale.note,
      ].map(_cell).join(','),
    );
  }
  return out.toString();
}

/// The date part of a timestamp, as ISO 8601.
String _isoDate(DateTime day) {
  final month = day.month.toString().padLeft(2, '0');
  final date = day.day.toString().padLeft(2, '0');
  return '${day.year}-$month-$date';
}

/// One CSV field, quoted when it has to be.
///
/// A card's name has commas in it as often as not - "Nicol Bolas, Dragon-God" -
/// and a note can have anything at all in it, so the quoting rule is applied to
/// every field rather than to the ones that look dangerous.
String _cell(String value) {
  if (!value.contains(',') &&
      !value.contains('"') &&
      !value.contains('\n') &&
      !value.contains('\r')) {
    return value;
  }
  final quoted = value.replaceAll('"', '""');
  return '"$quoted"';
}
