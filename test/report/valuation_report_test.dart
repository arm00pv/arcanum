// Reading a valuation report out of the stacks the collection holds.
//
//   flutter test test/report/valuation_report_test.dart
//
// The report is what an insurer reads, so the parts that matter most are the
// ones about what it cannot see: cards with no price, cards with no recorded
// cost, and the lines a limit left out.

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/report/valuation_report.dart';
import 'package:flutter_test/flutter_test.dart';

/// One stack, priced and named the way the real ones are.
ValuedEntry stack({
  required String id,
  String name = 'Revel in Riches',
  String setCode = 'XLN',
  String setName = 'Ixalan',
  int quantity = 1,
  double? unitValue = 20.99,
  double? unitCost,
  bool withCard = true,
  String binder = '',
}) => ValuedEntry(
  entry: CollectionEntry(
    cardId: id,
    quantity: quantity,
    purchasePrice: unitCost,
    binder: binder,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  ),
  unitValue: unitValue,
  card: withCard
      ? TcgCard(
          game: CardGame.mtg,
          id: id,
          setCode: setCode,
          setName: setName,
          name: name,
          collectorNumber: '117',
          rarity: 'rare',
        )
      : null,
);

ValuationReport reportOf(List<ValuedEntry> entries, {int? maxLines}) =>
    buildValuationReport(
      game: CardGame.mtg,
      entries: entries,
      generatedAt: DateTime(2026, 9, 14),
      priceAsOf: DateTime(2026, 9, 11),
      maxLines: maxLines,
    );

void main() {
  group('the totals', () {
    test('count cards, printings and value from the stacks themselves', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', quantity: 2, unitValue: 20.0),
        stack(
          id: 'b',
          name: 'Razaketh',
          setCode: 'HOU',
          setName:
              'Hour of '
              'Devastation',
          unitValue: 13.57,
        ),
      ]);
      expect(report.totalCards, 3);
      expect(report.uniquePrintings, 2);
      expect(report.totalValue, closeTo(53.57, 0.001));
      expect(report.pricedCards, 3);
      expect(report.unpricedCards, 0);
      expect(report.game, CardGame.mtg);
    });

    test('a stack with no price is counted and not valued', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', unitValue: 20.0, quantity: 2),
        stack(id: 'b', name: 'Swan Song', unitValue: null),
      ]);
      expect(report.totalCards, 3);
      expect(report.pricedCards, 2);
      expect(report.unpricedCards, 1);
      expect(report.totalValue, closeTo(40.0, 0.001));
      expect(
        report.caveats.any((String note) => note.contains('no market price')),
        isTrue,
      );
    });

    test('profit is only claimed for the cards whose cost is known', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', unitValue: 20.0, unitCost: 10.0, quantity: 2),
        stack(id: 'b', name: 'Swan Song', unitValue: 10.0),
      ]);
      expect(report.costedCards, 2);
      expect(report.totalCost, closeTo(20.0, 0.001));
      expect(report.unrealised, closeTo(30.0, 0.001));
      expect(report.unrealisedPercent, closeTo(150.0, 0.001));
      expect(
        report.caveats.any((String note) => note.contains('What was paid')),
        isTrue,
      );
    });

    test('a collection with no cost basis reports no return at all', () {
      final report = reportOf(<ValuedEntry>[stack(id: 'a')]);
      expect(report.totalCost, isNull);
      expect(report.unrealised, isNull);
      expect(report.unrealisedPercent, isNull);
      expect(
        report.summary.any(((String, String) row) => row.$1 == 'Unrealised'),
        isFalse,
      );
      // With nothing recorded, the report says so outright rather than
      // describing a return that does not exist.
      expect(
        report.caveats.any((String n) => n.contains('No purchase prices')),
        isTrue,
      );
      expect(
        report.caveats.any((String n) => n.contains('recorded for 0 of')),
        isFalse,
      );
    });
  });

  group('the lines', () {
    test('come out richest first', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', name: 'Cheap', unitValue: 1.0),
        stack(id: 'b', name: 'Dear', unitValue: 90.0),
      ]);
      expect(report.lines.first.name, 'Dear');
      expect(report.lines.last.name, 'Cheap');
    });

    test('are grouped by set, richest set first', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', setCode: 'XLN', setName: 'Ixalan', unitValue: 5.0),
        stack(
          id: 'b',
          setCode: 'HOU',
          setName: 'Hour of Devastation',
          unitValue: 40.0,
        ),
        stack(
          id: 'c',
          setCode: 'HOU',
          setName: 'Hour of Devastation',
          name: 'Obelisk Spider',
          unitValue: 3.0,
        ),
      ]);
      expect(report.sections.length, 2);
      expect(report.sections.first.title, 'Hour of Devastation (HOU)');
      expect(report.sections.first.lines.length, 2);
      expect(report.sections.first.subtotal, closeTo(43.0, 0.001));
      expect(report.sections.last.title, 'Ixalan (XLN)');
    });

    test('describe a stack the way the box it is in would', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', binder: 'Binder A - Red'),
      ]);
      expect(report.lines.single.identity, 'XLN #117');
      expect(
        report.lines.single.description,
        'Non-foil · Near Mint · Binder A - Red',
      );
    });

    test('name a printing the catalogue has not cached honestly', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'abc-123', withCard: false),
      ]);
      expect(report.lines.single.name, contains('abc-123'));
      expect(report.lines.single.setName, 'Unknown set');
    });
  });

  group('a report that is cut short', () {
    test('keeps the most valuable and says what it left out', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', name: 'One', unitValue: 30.0),
        stack(id: 'b', name: 'Two', unitValue: 20.0),
        stack(id: 'c', name: 'Three', unitValue: 10.0),
      ], maxLines: 2);
      expect(report.lines.length, 2);
      expect(report.lines.map((ValuationLine l) => l.name), <String>[
        'One',
        'Two',
      ]);
      expect(report.omittedLines, 1);
      expect(report.omittedValue, closeTo(10.0, 0.001));
      // The totals still describe the whole collection, and say so.
      expect(report.totalValue, closeTo(60.0, 0.001));
      expect(
        report.caveats.first,
        allOf(contains('not listed here'), contains('included in the totals')),
      );
    });

    test('says nothing about omission when nothing was omitted', () {
      final report = reportOf(<ValuedEntry>[stack(id: 'a')], maxLines: 5);
      expect(report.omittedLines, 0);
      expect(report.caveats.first, isNot(contains('not listed here')));
    });
  });

  group('concentration', () {
    test('one card that is the whole collection scores one', () {
      final report = reportOf(<ValuedEntry>[stack(id: 'a', unitValue: 50.0)]);
      expect(report.concentration, closeTo(1.0, 0.0001));
    });

    test('ten equal cards score a tenth', () {
      final report = reportOf(<ValuedEntry>[
        for (int i = 0; i < 10; i++)
          stack(id: 'c$i', name: 'Card $i', unitValue: 10.0),
      ]);
      expect(report.concentration, closeTo(0.1, 0.0001));
    });

    test(
      'an unpriced collection scores nothing rather than dividing by zero',
      () {
        final report = reportOf(<ValuedEntry>[stack(id: 'a', unitValue: null)]);
        expect(report.concentration, 0);
        expect(report.totalValue, 0);
      },
    );
  });

  group('the caveats', () {
    test('always end on what the numbers are not', () {
      final report = reportOf(<ValuedEntry>[stack(id: 'a', unitCost: 5.0)]);
      expect(report.caveats.last, contains('not an appraisal'));
      expect(
        report.caveats.any((String note) => note.contains('market prices')),
        isTrue,
      );
    });

    test('are short when nothing is missing', () {
      final report = reportOf(<ValuedEntry>[
        stack(id: 'a', unitValue: 20.0, unitCost: 5.0),
      ]);
      expect(report.caveats.length, 2);
    });
  });
}
