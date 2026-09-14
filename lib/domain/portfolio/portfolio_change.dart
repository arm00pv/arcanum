import 'package:arcanum/core/utils/formatters.dart';

/// One day of the portfolio: what it was worth, and what it held.
///
/// The card count travels with the value because a portfolio curve without it
/// cannot tell a market move from a change in what is owned, and the difference
/// matters: a collection that went from seven cards to seven hundred and fifty
/// shows as a collapse in value when nothing fell at all.
class PortfolioPoint {
  /// Creates a point.
  const PortfolioPoint({
    required this.date,
    required this.value,
    required this.cards,
  });

  /// The day this was recorded.
  final DateTime date;

  /// What the whole collection was worth that day.
  final double value;

  /// How many physical cards it held.
  final int cards;
}

/// How a portfolio changed, and whether the change means what it looks like.
class PortfolioChange {
  /// Creates a change.
  const PortfolioChange({
    required this.percent,
    required this.first,
    required this.last,
  });

  /// The change from the first recorded day to the last, in percent.
  final double percent;

  /// The earliest point in the window.
  final PortfolioPoint first;

  /// The latest point in the window.
  final PortfolioPoint last;

  /// Whether the collection held a different number of cards at the two ends.
  ///
  /// When it did, the percentage is a change in what is owned as much as in
  /// what it is worth, and a collector reading it as a market move would be
  /// reading it wrong.
  bool get collectionChanged => first.cards != last.cards;

  /// The caption under the curve.
  String get label =>
      'Since ${Fmt.dateShort(first.date)}  ·  ${Fmt.percent(percent)}';

  /// What the caption has to add, or null when the two ends are the same
  /// collection and the percentage means what it says.
  String? get caveat {
    if (!collectionChanged) return null;
    return 'The collection itself changed over this stretch: '
        '${Fmt.count(first.cards)} '
        '${first.cards == 1 ? 'card' : 'cards'} then, '
        '${Fmt.count(last.cards)} now. The change below is what is owned as '
        'much as what it is worth.';
  }
}

/// Reads the change out of a portfolio series, or null when there is nothing to
/// compare.
PortfolioChange? portfolioChange(List<PortfolioPoint> series) {
  if (series.length < 2) return null;
  final PortfolioPoint first = series.first;
  final PortfolioPoint last = series.last;
  if (first.value <= 0) return null;
  return PortfolioChange(
    percent: (last.value / first.value - 1) * 100,
    first: first,
    last: last,
  );
}
