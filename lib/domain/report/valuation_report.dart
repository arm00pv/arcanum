import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/sealed_product.dart';

/// One stack, as a valuation report prints it.
///
/// A stack rather than a printing, because a report for an insurer describes
/// physical cards: a Near Mint non-foil and a Played foil of the same card are
/// two things in two boxes, and they are worth two different amounts.
class ValuationLine {
  const ValuationLine({
    required this.name,
    required this.setCode,
    required this.setName,
    required this.collectorNumber,
    required this.finish,
    required this.condition,
    required this.binder,
    required this.quantity,
    required this.unitValue,
    required this.unitCost,
  });

  final String name;

  /// Set code as printed, upper case for the games that use one.
  final String setCode;
  final String setName;
  final String collectorNumber;

  /// The finish and grade labels, already in the reader's language.
  final String finish;
  final String condition;

  /// Where the cards are kept, empty when the user has not said.
  final String binder;

  final int quantity;

  /// Market value of one copy, or null when the catalogue has no price.
  final double? unitValue;

  /// What the user paid for one copy, or null when it was not recorded.
  final double? unitCost;

  double? get totalValue => unitValue == null ? null : unitValue! * quantity;
  double? get totalCost => unitCost == null ? null : unitCost! * quantity;

  double? get profit {
    final double? value = totalValue;
    final double? cost = totalCost;
    if (value == null || cost == null) return null;
    return value - cost;
  }

  /// True when the catalogue knows what this stack is worth.
  bool get isPriced => unitValue != null;

  /// 'XLN #117', or just the number when the game prints no set code.
  String get identity =>
      setCode.isEmpty ? '#$collectorNumber' : '$setCode #$collectorNumber';

  /// 'Foil · Near Mint', and the binder after it when there is one.
  String get description {
    final parts = <String>[finish, condition, if (binder.isNotEmpty) binder];
    return parts.join(' · ');
  }
}

/// The stacks of one set, with what they come to.
class ValuationSection {
  const ValuationSection({
    required this.title,
    required this.lines,
    required this.subtotal,
    this.unit = 'card',
  });

  final String title;
  final List<ValuationLine> lines;
  final double subtotal;

  /// What one row of this section counts, singular: a card, or an item of
  /// sealed product. A table of boxes is not a table of cards, and a report that
  /// called three booster boxes three cards would be wrong in the one place a
  /// reader is least likely to check.
  final String unit;

  int get cards =>
      lines.fold(0, (int n, ValuationLine line) => n + line.quantity);
}

/// Everything a valuation report says, ready to be printed.
///
/// Built from the same valued entries the collection screen draws itself from,
/// so a report can never disagree with the app about what is owned. Nothing here
/// reaches for a database or a network: the report is a pure reading of what it
/// was handed, which is why it can be tested by handing it stacks.
class ValuationReport {
  const ValuationReport({
    required this.game,
    required this.generatedAt,
    required this.priceAsOf,
    required this.lines,
    required this.sections,
    required this.totalCards,
    required this.uniquePrintings,
    required this.pricedCards,
    required this.unpricedCards,
    required this.costedCards,
    required this.totalValue,
    required this.totalCost,
    required this.concentration,
    required this.omittedLines,
    required this.omittedValue,
    required this.sealedLines,
    required this.sealedItems,
    required this.sealedValue,
    required this.sealedUnpriced,
  });

  final CardGame game;

  /// When the report was made.
  final DateTime generatedAt;

  /// When the catalogue's prices were last refreshed, if that is known.
  final DateTime? priceAsOf;

  /// The stacks the report prints, most valuable first.
  final List<ValuationLine> lines;

  /// The same stacks, grouped by set for the printed tables.
  final List<ValuationSection> sections;

  final int totalCards;

  /// Distinct printings, which is fewer than [totalCards] when cards are doubled.
  final int uniquePrintings;

  final int pricedCards;

  /// Cards the catalogue has no market price for. They are worth something; the
  /// report simply does not know what.
  final int unpricedCards;

  /// Cards with a recorded purchase price.
  final int costedCards;

  final double totalValue;

  /// Sum of recorded purchase prices, or null when none was ever recorded.
  final double? totalCost;

  /// Herfindahl-Hirschman index over the printed lines, 0 to 1.
  final double concentration;

  /// Stacks left out by a limit, and what they were worth between them.
  final int omittedLines;
  final double omittedValue;

  /// The sealed product the collector holds, as its own table.
  final List<ValuationLine> sealedLines;

  /// How many sealed products are held, counting quantity.
  final int sealedItems;

  /// What the priced sealed product comes to.
  final double sealedValue;

  /// Sealed holdings nothing has priced.
  final int sealedUnpriced;

  double? get unrealised {
    final double? cost = totalCost;
    if (cost == null) return null;
    return totalValue - cost;
  }

  double? get unrealisedPercent {
    final double? cost = totalCost;
    final double? profit = unrealised;
    if (cost == null || profit == null || cost <= 0) return null;
    return profit / cost * 100.0;
  }

  /// What the report says it cannot see, in the order a reader needs it.
  ///
  /// A valuation that hides its own gaps is worse than no valuation: an insurer
  /// reading a total that quietly left out two hundred unpriced cards would be
  /// reading a number that is not true.
  List<String> get caveats {
    final List<String> notes = <String>[];
    if (omittedLines > 0) {
      notes.add(
        'The ${Fmt.count(omittedLines)} least valuable '
        '${omittedLines == 1 ? 'stack is' : 'stacks are'} not listed here; '
        'they come to ${Fmt.money(omittedValue)} between them and are '
        'included in the totals.',
      );
    }
    if (unpricedCards > 0) {
      notes.add(
        '${Fmt.count(unpricedCards)} of ${Fmt.count(totalCards)} cards have '
        'no market price in the catalogue. They are listed at '
        '${Fmt.money(0)}, so the total below is lower than the collection is '
        'worth by whatever they would fetch.',
      );
    }
    if (costedCards == 0) {
      notes.add(
        'No purchase prices are recorded, so this report says nothing about '
        'what the collection has made or lost since it was bought.',
      );
    } else if (costedCards < totalCards) {
      notes.add(
        'What was paid is recorded for ${Fmt.count(costedCards)} of '
        '${Fmt.count(totalCards)} cards, so the return shown covers only '
        'those.',
      );
    }
    if (sealedLines.isNotEmpty) {
      final String unpricedNote = sealedUnpriced == 0
          ? ''
          : ' ${Fmt.count(sealedUnpriced)} of those holdings have never been '
                'priced and are left out of the total rather than guessed at.';
      notes.add(
        'Sealed product is valued at the last figure the app saw for it, from '
        'the price list your own companion keeps, rather than at a live '
        'price.$unpricedNote',
      );
    }
    notes.add(
      'These are market prices - what a card is selling for - rather than '
      'offers. A dealer buying a collection pays less, and a whole collection '
      'sold at once usually less still.',
    );
    notes.add(
      'This is a statement of what is held and what the market asks, not an '
      'appraisal, and a valuer or an insurer is not obliged to accept it.',
    );
    return notes;
  }

  /// The headline lines the printed summary shows, in order.
  List<(String, String)> get summary {
    final List<(String, String)> rows = <(String, String)>[
      ('Cards', Fmt.count(totalCards)),
      ('Distinct printings', Fmt.count(uniquePrintings)),
      ('Market value', Fmt.money(totalValue)),
      if (sealedLines.isNotEmpty)
        (
          'Sealed product',
          '${Fmt.count(sealedItems)} '
              '${sealedItems == 1 ? "item" : "items"} · '
              '${Fmt.money(sealedValue)}',
        ),
      if (sealedLines.isNotEmpty)
        ('Everything together', Fmt.money(totalValue + sealedValue)),
    ];
    if (totalCost != null) {
      rows.add(('Paid', Fmt.money(totalCost)));
      rows.add(('Unrealised', Fmt.moneySigned(unrealised)));
      final double? percent = unrealisedPercent;
      if (percent != null) {
        rows.add(('Return', Fmt.percent(percent)));
      }
    }
    rows.add((
      'Largest holding',
      Fmt.percent(concentration * 100, signed: false),
    ));
    return rows;
  }
}

/// Reads a report out of the stacks the collection is holding.
///
/// [maxLines] keeps only the most valuable stacks, which is what a short
/// certificate wants; the totals still describe the whole collection, and the
/// report says so. Nothing else is thrown away.
ValuationReport buildValuationReport({
  required CardGame game,
  required List<ValuedEntry> entries,
  DateTime? generatedAt,
  DateTime? priceAsOf,
  int? maxLines,
  Map<String, String> setNames = const <String, String>{},
  List<SealedHolding> sealed = const <SealedHolding>[],
}) {
  final List<ValuationLine> all = <ValuationLine>[
    for (final ValuedEntry entry in entries) _lineOf(entry, setNames),
  ]..sort(_byValueDesc);

  final int totalCards = all.fold(
    0,
    (int n, ValuationLine line) => n + line.quantity,
  );
  final double totalValue = all.fold(
    0.0,
    (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
  );
  final int pricedCards = all.fold(
    0,
    (int n, ValuationLine line) => n + (line.isPriced ? line.quantity : 0),
  );
  final int costedCards = all.fold(
    0,
    (int n, ValuationLine line) =>
        n + (line.unitCost == null ? 0 : line.quantity),
  );
  final List<double> costs = <double>[
    for (final ValuationLine line in all)
      if (line.totalCost != null) line.totalCost!,
  ];
  final double? totalCost = costs.isEmpty
      ? null
      : costs.fold<double>(0.0, (double a, double b) => a + b);

  // Sealed product is not part of the card total and never has been: a box is
  // not a card, and an insurer reading '751 cards' must not find thirty-six
  // packs folded into it. It is its own table, its own count and its own value,
  // and the summary adds the two together in one line for the reader who wants
  // the whole shelf in a figure.
  final List<ValuationLine> sealedLines = <ValuationLine>[
    for (final SealedHolding holding in sealed) _sealedLineOf(holding),
  ]..sort(_byValueDesc);
  final int sealedItems = sealedLines.fold(
    0,
    (int n, ValuationLine line) => n + line.quantity,
  );
  final double sealedValue = sealedLines.fold(
    0.0,
    (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
  );
  // Holdings, not items: the caveat says how many rows nothing has priced.
  final int sealedUnpriced = sealedLines.fold(
    0,
    (int n, ValuationLine line) => n + (line.isPriced ? 0 : 1),
  );

  final bool cut = maxLines != null && all.length > maxLines;
  final List<ValuationLine> printed = cut ? all.sublist(0, maxLines) : all;
  final List<ValuationLine> dropped = cut ? all.sublist(maxLines) : const [];

  return ValuationReport(
    game: game,
    generatedAt: generatedAt ?? DateTime.now(),
    priceAsOf: priceAsOf,
    lines: printed,
    sections: <ValuationSection>[
      ..._sectionsOf(printed),
      if (sealedLines.isNotEmpty)
        ValuationSection(
          title: 'Sealed product',
          lines: sealedLines,
          subtotal: sealedValue,
          unit: 'item',
        ),
    ],
    totalCards: totalCards,
    uniquePrintings: <String>{
      for (final ValuedEntry entry in entries) entry.entry.cardId,
    }.length,
    pricedCards: pricedCards,
    unpricedCards: totalCards - pricedCards,
    costedCards: costedCards,
    totalValue: totalValue,
    totalCost: totalCost,
    concentration: _concentration(printed),
    omittedLines: dropped.length,
    omittedValue: dropped.fold(
      0.0,
      (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
    ),
    sealedLines: sealedLines,
    sealedItems: sealedItems,
    sealedValue: sealedValue,
    sealedUnpriced: sealedUnpriced,
  );
}

/// One sealed holding as a printable line.
///
/// The category takes the place the collector number has on a card, because that
/// is the same question in a different shape: which printing of the thing is
/// this. The finish and condition columns are left empty, because a box has
/// neither and inventing "Near Mint" for shrink wrap would be a lie a valuer
/// could rely on.
ValuationLine _sealedLineOf(SealedHolding holding) => ValuationLine(
  name: holding.name,
  setCode: holding.setCode.toUpperCase(),
  setName: holding.setName.isEmpty ? 'Sealed product' : holding.setName,
  collectorNumber: holding.category.label,
  finish: '',
  condition: '',
  binder: holding.location,
  quantity: holding.quantity,
  unitValue: holding.unitValue,
  unitCost: holding.unitCost,
);

ValuationLine _lineOf(ValuedEntry entry, Map<String, String> setNames) {
  final cardId = entry.entry.cardId;
  final setCode = entry.card?.setCode ?? '';
  return ValuationLine(
    name: entry.card?.name ?? 'Printing $cardId',
    setCode: setCode.isEmpty ? '' : setCode.toUpperCase(),
    setName:
        setNames[setCode.toUpperCase()] ?? entry.card?.setName ?? 'Unknown set',
    collectorNumber: entry.card?.collectorNumber ?? '',
    finish: entry.entry.finish.label,
    condition: entry.entry.condition.label,
    binder: entry.entry.binder,
    quantity: entry.entry.quantity,
    unitValue: entry.unitValue,
    unitCost: entry.entry.purchasePrice,
  );
}

int _byValueDesc(ValuationLine a, ValuationLine b) {
  final double av = a.totalValue ?? -1;
  final double bv = b.totalValue ?? -1;
  final int byValue = bv.compareTo(av);
  if (byValue != 0) return byValue;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// The printed tables: one per set, richest set first.
List<ValuationSection> _sectionsOf(List<ValuationLine> lines) {
  final Map<String, List<ValuationLine>> grouped =
      <String, List<ValuationLine>>{};
  for (final ValuationLine line in lines) {
    final String key = line.setName.isEmpty
        ? 'Unknown set'
        : '${line.setName}${line.setCode.isEmpty ? '' : ' (${line.setCode})'}';
    grouped.putIfAbsent(key, () => <ValuationLine>[]).add(line);
  }
  final List<ValuationSection> sections =
      <ValuationSection>[
        for (final MapEntry<String, List<ValuationLine>> group
            in grouped.entries)
          ValuationSection(
            title: group.key,
            lines: group.value,
            subtotal: group.value.fold(
              0.0,
              (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
            ),
          ),
      ]..sort((ValuationSection a, ValuationSection b) {
        final int byValue = b.subtotal.compareTo(a.subtotal);
        return byValue != 0 ? byValue : a.title.compareTo(b.title);
      });
  return sections;
}

/// How much of the collection one card accounts for, as a single number.
///
/// The Herfindahl-Hirschman index: the sum of the squared shares. One card that
/// is the whole collection scores 1; ten equal cards score 0.1. It is the honest
/// way to say 'this vault is one card with some others around it'.
double _concentration(List<ValuationLine> lines) {
  final double total = lines.fold(
    0.0,
    (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
  );
  if (total <= 0) return 0;
  double sum = 0;
  for (final ValuationLine line in lines) {
    final double share = (line.totalValue ?? 0) / total;
    sum += share * share;
  }
  return sum > 1 ? 1 : sum;
}
