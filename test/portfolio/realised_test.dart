// Tests for realised profit and loss and the tax-year export.
//
//   flutter test test/portfolio/realised_test.dart

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:arcanum/domain/portfolio/realised.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CardSale sale({
    int quantity = 1,
    double unitPrice = 10,
    double fees = 0,
    DateTime? soldOn,
    String platform = '',
    String note = '',
    CardFinish finish = CardFinish.nonfoil,
    List<LotMatch> matches = const <LotMatch>[],
  }) => CardSale(
    game: CardGame.mtg,
    cardId: 'bolt',
    quantity: quantity,
    unitPrice: unitPrice,
    fees: fees,
    soldOn: soldOn ?? DateTime(2025, 4, 1),
    platform: platform,
    note: note,
    finish: finish,
    matches: matches,
  );

  SaleRow row(CardSale s, {String name = 'Lightning Bolt'}) => SaleRow(
    sale: s,
    name: name,
    setCode: 'lea',
    setName: 'Limited Edition Alpha',
  );

  group('a sale', () {
    test('takes its fees off what arrived, not off what was made', () {
      // A marketplace's cut and the postage are money that never arrived, so
      // they reduce the proceeds rather than being a cost of the cards.
      final s = sale(quantity: 2, unitPrice: 10, fees: 3.5);
      expect(s.gross, 20);
      expect(s.proceeds, 16.5);
    });

    test('realises the difference against the lots it came out of', () {
      final s = sale(
        quantity: 3,
        unitPrice: 4,
        fees: 1,
        matches: const <LotMatch>[
          LotMatch(lotId: 1, quantity: 2, unitCost: 1.5),
          LotMatch(lotId: 2, quantity: 1, unitCost: 3),
        ],
      );

      expect(s.cost, 6);
      expect(s.gain, 5);
      expect(s.costKnown, isTrue);
    });

    test('has no gain at all when a lot had no price', () {
      final s = sale(
        matches: const <LotMatch>[
          LotMatch(lotId: 1, quantity: 1, unitCost: null),
        ],
      );

      expect(s.cost, isNull);
      expect(s.gain, isNull);
      expect(s.costKnown, isFalse);
    });

    test('loses money when it sells for less than it cost', () {
      final s = sale(
        quantity: 2,
        unitPrice: 1,
        matches: const <LotMatch>[LotMatch(lotId: 1, quantity: 2, unitCost: 5)],
      );

      expect(s.gain, -8);
    });
  });

  group('a year of sales', () {
    test('is grouped by the year the sale happened, newest first', () {
      final realised = Realised.of(<SaleRow>[
        row(sale(soldOn: DateTime(2024, 12, 31))),
        row(sale(soldOn: DateTime(2025, 1, 1))),
        row(sale(soldOn: DateTime(2025, 8, 4))),
      ]);

      expect(realised.years.map((RealisedYear y) => y.year), <int>[2025, 2024]);
      // Inside a year, the newest sale is first.
      expect(realised.years.first.rows.map((SaleRow r) => r.soldOn), <DateTime>[
        DateTime(2025, 8, 4),
        DateTime(2025, 1, 1),
      ]);
      expect(realised.rows, hasLength(3));
      expect(realised.year(2024)!.sales, 1);
      expect(realised.year(1999), isNull);
      expect(Realised.of(const <SaleRow>[]).isEmpty, isTrue);
    });

    test('adds up what arrived, what it cost and what it made', () {
      final realised = Realised.of(<SaleRow>[
        row(
          sale(
            quantity: 2,
            unitPrice: 10,
            fees: 2,
            soldOn: DateTime(2025, 3, 1),
            matches: const <LotMatch>[
              LotMatch(lotId: 1, quantity: 2, unitCost: 4),
            ],
          ),
        ),
        row(
          sale(
            quantity: 1,
            unitPrice: 5,
            soldOn: DateTime(2025, 9, 1),
            matches: const <LotMatch>[
              LotMatch(lotId: 2, quantity: 1, unitCost: 1),
            ],
          ),
        ),
      ]);

      final year = realised.year(2025)!;
      expect(year.copies, 3);
      expect(year.proceeds, 23);
      expect(year.cost, 9);
      expect(year.gain, 14);
      expect(year.everyCostKnown, isTrue);
      expect(year.unknownCost, 0);
    });

    test(
      'counts the sales it cannot account for rather than adding a zero',
      () {
        final realised = Realised.of(<SaleRow>[
          row(
            sale(
              unitPrice: 10,
              soldOn: DateTime(2025, 3, 1),
              matches: const <LotMatch>[
                LotMatch(lotId: 1, quantity: 1, unitCost: 4),
              ],
            ),
          ),
          row(sale(unitPrice: 20, soldOn: DateTime(2025, 4, 1))),
        ]);

        final year = realised.year(2025)!;
        expect(year.unknownCost, 1);
        expect(year.everyCostKnown, isFalse);
        // The known sale still counts on both sides; the unknown one counts on
        // the money-in side only, which is why the sheet has to say so.
        expect(year.proceeds, 30);
        expect(year.cost, 4);
        // Only the sale whose cost is known contributes a gain: 10 - 4.
        expect(year.gain, 6);
      },
    );
  });

  group('the tax-year export', () {
    test('writes a header and one row per sale, with money as bare numbers', () {
      final csv = salesCsv(<SaleRow>[
        row(
          sale(
            quantity: 2,
            unitPrice: 7.5,
            fees: 1.25,
            soldOn: DateTime(2025, 3, 9),
            platform: 'Cardmarket',
            finish: CardFinish.foil,
            matches: const <LotMatch>[
              LotMatch(lotId: 1, quantity: 2, unitCost: 3),
            ],
          ),
        ),
      ]);

      final lines = csv.trim().split('\n');
      expect(
        lines.first,
        startsWith('Date,Card,Set,Set code,Finish,Condition'),
      );
      expect(
        lines[1],
        '2025-03-09,Lightning Bolt,Limited Edition Alpha,LEA,Foil,'
        'Near Mint,2,7.50,1.25,13.75,6.00,7.75,Cardmarket,',
      );
      // One header, one row, and a trailing newline so the file is a text file
      // like any other.
      expect(lines, hasLength(2));
      expect(csv.endsWith('\n'), isTrue);
    });

    test('leaves the cost columns empty when the cost was never recorded', () {
      final csv = salesCsv(<SaleRow>[row(sale(unitPrice: 4))]);
      final fields = csv.trim().split('\n')[1].split(',');
      // ... quantity, unit price, fees, proceeds, cost, gain
      expect(fields[9], '4.00');
      expect(fields[10], '');
      expect(fields[11], '');
    });

    test('quotes a name with a comma and a note with a quote in it', () {
      // The card that needs it is a real one, and a note is free text.
      final csv = salesCsv(<SaleRow>[
        row(
          sale(note: 'sold to a friend, "mint"'),
          name: 'Nicol Bolas, Dragon-God',
        ),
      ]);

      expect(csv, contains('"Nicol Bolas, Dragon-God"'));
      expect(csv, contains('"sold to a friend, ""mint"""'));
    });

    test('has nothing but a header when nothing has been sold', () {
      expect(salesCsv(const <SaleRow>[]).trim().split('\n'), hasLength(1));
    });
  });
}
