// Tests for the cost-basis lots: which copies a sale came out of, and what
// they cost.
//
//   flutter test test/portfolio/lots_test.dart
//
// The arithmetic here is the part of a tax figure that has to be right, so it is
// pure and it is tested without a database.

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/lots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  CardLot lot(int? id, int quantity, double? cost, DateTime? on) => CardLot(
    id: id,
    game: CardGame.mtg,
    cardId: 'bolt',
    quantity: quantity,
    unitCost: cost,
    acquiredOn: on,
  );

  group('taking copies out of lots', () {
    test('comes out of the oldest purchase first', () {
      final lots = <CardLot>[
        lot(2, 4, 3.0, DateTime(2025, 6, 1)),
        lot(1, 2, 1.0, DateTime(2024, 1, 5)),
      ];

      final match = matchFifo(lots, 3);

      // Two from the 2024 lot at a dollar, one from the 2025 lot at three.
      expect(match.matches.map((LotMatch m) => m.lotId), <int>[1, 2]);
      expect(match.matches.map((LotMatch m) => m.quantity), <int>[2, 1]);
      expect(match.cost, 5.0);
      expect(match.costKnown, isTrue);
      expect(match.unmatched, 0);
    });

    test('leaves the lots that were not touched alone', () {
      final lots = <CardLot>[
        lot(1, 2, 1.0, DateTime(2024, 1, 5)),
        lot(2, 4, 3.0, DateTime(2025, 6, 1)),
      ];

      final match = matchFifo(lots, 2);

      expect(match.remaining.map((CardLot l) => l.quantity), <int>[0, 4]);
      expect(match.remaining.map((CardLot l) => l.id), <int>[1, 2]);
      // The lots handed back are copies, so the originals still say what they
      // said before the disposal.
      expect(lots.first.quantity, 2);
    });

    test('an undated purchase is not assumed to be the oldest', () {
      final lots = <CardLot>[
        lot(1, 5, 9.0, null),
        lot(2, 5, 2.0, DateTime(2024, 3, 1)),
      ];

      final match = matchFifo(lots, 1);

      expect(match.matches.single.lotId, 2);
      expect(match.cost, 2.0);
    });

    test('sorts two lots bought the same day by the order they were filed', () {
      final sameDay = DateTime(2024, 3, 1);
      final match = matchFifo(<CardLot>[
        lot(7, 1, 4.0, sameDay),
        lot(3, 1, 4.5, sameDay),
      ], 1);

      expect(match.matches.single.lotId, 3);
    });

    test('one undated lot comes before another, by id', () {
      final match = matchFifo(<CardLot>[
        lot(9, 1, 1.0, null),
        lot(4, 1, 2.0, null),
      ], 2);

      expect(match.matches.map((LotMatch m) => m.lotId), <int>[4, 9]);
    });

    test('says so when more copies were sold than the lots account for', () {
      // A stack recorded before lots existed, or one whose lots were deleted:
      // the copies are real, the cost is not, and an invented cost would be an
      // invented gain.
      final match = matchFifo(<CardLot>[
        lot(1, 1, 2.0, DateTime(2024, 1, 1)),
      ], 3);

      expect(match.disposed, 1);
      expect(match.unmatched, 2);
      expect(match.cost, isNull);
      expect(match.costKnown, isFalse);
    });

    test('a lot with no recorded price makes the whole cost unknown', () {
      final match = matchFifo(<CardLot>[
        lot(1, 1, 2.0, DateTime(2024, 1, 1)),
        lot(2, 1, null, DateTime(2024, 2, 1)),
      ], 2);

      expect(match.matches, hasLength(2));
      expect(match.cost, isNull);
      expect(match.costKnown, isFalse);
    });

    test('an empty disposal matches nothing and costs nothing', () {
      final match = matchFifo(<CardLot>[
        lot(1, 2, 3.0, DateTime(2024, 1, 1)),
      ], 0);

      expect(match.matches, isEmpty);
      expect(match.unmatched, 0);
      expect(match.cost, isNull);
      expect(match.remaining.single.quantity, 2);
    });

    test('a negative quantity takes nothing rather than adding copies', () {
      final match = matchFifo(<CardLot>[
        lot(1, 2, 3.0, DateTime(2024, 1, 1)),
      ], -4);

      expect(match.disposed, 0);
      expect(match.remaining.single.quantity, 2);
    });

    test('sells through emptied lots without stopping', () {
      final match = matchFifo(<CardLot>[
        lot(1, 0, 1.0, DateTime(2024, 1, 1)),
        lot(2, 3, 2.0, DateTime(2024, 2, 1)),
      ], 2);

      expect(match.matches.single.lotId, 2);
      expect(match.cost, 4.0);
    });
  });

  group('a lot', () {
    test(
      'knows what its copies cost, and nothing when the price is missing',
      () {
        expect(lot(1, 3, 2.5, null).cost, 7.5);
        expect(lot(1, 3, null, null).cost, isNull);
      },
    );
  });
}
