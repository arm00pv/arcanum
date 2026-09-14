// What the portfolio caption means.
//
//   flutter test test/portfolio/portfolio_change_test.dart
//
// The dashboard said "-75.5% since 11 Sep" about a collection that had simply
// become a different collection: seven cards worth $1,267 had turned into 751
// cards worth $311. The percentage was arithmetic; reading it as a market move
// was the mistake, and this is the file that stops the app inviting it.

import 'package:arcanum/domain/portfolio/portfolio_change.dart';
import 'package:flutter_test/flutter_test.dart';

PortfolioPoint point(String date, double value, int cards) =>
    PortfolioPoint(date: DateTime.parse(date), value: value, cards: cards);

void main() {
  test('a curve with fewer than two days has nothing to say', () {
    expect(portfolioChange(const <PortfolioPoint>[]), isNull);
    expect(
      portfolioChange(<PortfolioPoint>[point('2026-09-13', 311.03, 751)]),
      isNull,
    );
  });

  test('a series that starts at nothing is not a percentage', () {
    expect(
      portfolioChange(<PortfolioPoint>[
        point('2026-09-12', 0, 0),
        point('2026-09-13', 311.03, 751),
      ]),
      isNull,
    );
  });

  test('a real fall over an unchanged collection is just a fall', () {
    final change = portfolioChange(<PortfolioPoint>[
      point('2026-09-12', 400, 751),
      point('2026-09-13', 311.03, 751),
    ])!;

    expect(change.percent, closeTo(-22.24, 0.01));
    expect(change.collectionChanged, isFalse);
    expect(change.caveat, isNull, reason: 'nothing else needs saying');
    expect(change.label, contains('12 Sep'));
    expect(change.label, contains('%'));
    expect(change.label, startsWith('Since '));
  });

  test('a fall across a change in what is owned says so', () {
    final change = portfolioChange(<PortfolioPoint>[
      point('2026-09-11', 1267.22, 7),
      point('2026-09-13', 311.03, 751),
    ])!;

    expect(change.percent, closeTo(-75.46, 0.01));
    expect(change.collectionChanged, isTrue);
    expect(change.caveat, isNotNull);
    expect(change.caveat, contains('7 cards then'));
    expect(change.caveat, contains('751 now'));
    expect(
      change.caveat,
      contains('what is owned as much as what it is worth'),
      reason: 'the sentence has to say which way to read the number',
    );
  });

  test('one card reads as one card', () {
    final change = portfolioChange(<PortfolioPoint>[
      point('2026-09-11', 10, 1),
      point('2026-09-13', 11, 3),
    ])!;
    expect(change.caveat, contains('1 card then'));
  });

  test(
    'a collection that only grew is flagged the same way as one that fell',
    () {
      // An import on a second device looks like a jump in value. It is not a
      // market move either, and the caption says the same thing about it.
      final change = portfolioChange(<PortfolioPoint>[
        point('2026-09-11', 100, 20),
        point('2026-09-13', 311.03, 751),
      ])!;
      expect(change.percent, greaterThan(0));
      expect(change.collectionChanged, isTrue);
      expect(change.caveat, contains('20 cards then'));
      expect(change.caveat, contains('751 now'));
    },
  );
}
