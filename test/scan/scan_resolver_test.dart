// Turning what was read off a card into a printing the catalogue holds.
//
//   flutter test test/scan/scan_resolver_test.dart
//
// The order the resolver tries things in is the whole feature. A set code and a
// number name one printing anywhere in the game and must be believed; a name
// and a number narrow a reprint; a name alone must never be treated as an
// answer, because 'Llanowar Elves' is eight different cards and the scanner has
// no idea which one is in the collector's hand.

import 'package:arcanum/data/scan/scan_resolver.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/scan/card_scan.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard card(
  String name, {
  required String set,
  required String number,
  CardGame game = CardGame.mtg,
}) => TcgCard(
  game: game,
  id: '${set.toLowerCase()}-$number',
  setCode: set.toLowerCase(),
  setName: 'Set $set',
  name: name,
  collectorNumber: number,
  rarity: 'common',
);

/// A catalogue of a few printings, with the two questions a scan asks.
class FakeCatalogue implements ScanCatalogue {
  FakeCatalogue(this.cards);

  final List<TcgCard> cards;
  final List<String> asked = <String>[];

  @override
  Future<TcgCard?> byNumber(
    CardGame game,
    String setCode,
    String collectorNumber,
  ) async {
    asked.add('number:$setCode/$collectorNumber');
    for (final TcgCard c in cards) {
      if (c.game == game &&
          c.setCode.toLowerCase() == setCode.toLowerCase() &&
          c.collectorNumber == collectorNumber) {
        return c;
      }
    }
    return null;
  }

  @override
  Future<List<TcgCard>> byName(
    CardGame game,
    String name, {
    required int limit,
  }) async {
    asked.add('name:$name');
    final lower = name.toLowerCase();
    return <TcgCard>[
      for (final TcgCard c in cards)
        if (c.game == game && c.name.toLowerCase().contains(lower)) c,
    ].take(limit).toList();
  }
}

void main() {
  final llanowarM10 = card('Llanowar Elves', set: 'M10', number: '186');
  final llanowarDom = card('Llanowar Elves', set: 'DOM', number: '168');
  final bolt = card('Lightning Bolt', set: 'LEA', number: '161');
  final charizard = card(
    'Charizard',
    set: 'base1',
    number: '4',
    game: CardGame.pokemon,
  );

  late FakeCatalogue catalogue;
  late ScanResolver resolver;

  setUp(() {
    catalogue = FakeCatalogue(<TcgCard>[
      llanowarM10,
      llanowarDom,
      bolt,
      charizard,
    ]);
    resolver = ScanResolver(catalogue: catalogue);
  });

  group('a set code and a number', () {
    test('name one printing, and are believed', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(
          setCode: 'LEA',
          collectorNumber: '161',
          name: 'Lightning Bol',
        ),
      );
      expect(result.exact?.name, 'Lightning Bolt');
      expect(result.candidates, isEmpty);
      // The name is not even asked about: the position is the answer.
      expect(catalogue.asked, <String>['number:LEA/161']);
    });

    test('are case-insensitive about the set code', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(setCode: 'lea', collectorNumber: '161'),
      );
      expect(result.exact?.name, 'Lightning Bolt');
    });

    test('that match nothing say so instead of guessing', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(
          setCode: 'LEA',
          collectorNumber: '999',
          name: 'Lightning Bolt',
        ),
      );
      expect(result.exact, isNull);
      expect(result.candidates, isEmpty);
      expect(result.note, contains('LEA'));
      expect(result.note, contains('999'));
      // Crucially: it does not fall back to the name and quietly pick a
      // different printing of the same card.
      expect(catalogue.asked, <String>['number:LEA/999']);
    });

    test('find a card whose number is stored without leading zeros', () async {
      final padded = card('Sol Ring', set: 'C21', number: '007');
      catalogue = FakeCatalogue(<TcgCard>[padded]);
      resolver = ScanResolver(catalogue: catalogue);

      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(setCode: 'C21', collectorNumber: '7'),
      );
      expect(result.exact?.name, 'Sol Ring');
    });
  });

  group('a name and a number', () {
    test('narrow a reprint to the one set that printed it there', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(collectorNumber: '168', name: 'Llanowar Elves'),
      );
      expect(result.exact?.setCode, 'dom');
    });

    test('that match several sets are offered rather than decided', () async {
      final shared = card('Llanowar Elves', set: 'M12', number: '186');
      catalogue = FakeCatalogue(<TcgCard>[llanowarM10, shared]);
      resolver = ScanResolver(catalogue: catalogue);

      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(collectorNumber: '186', name: 'Llanowar Elves'),
      );
      expect(result.exact, isNull);
      expect(result.candidates, hasLength(2));
      expect(result.note, contains('more than one set'));
    });
  });

  group('a name on its own', () {
    test('is a question, not an answer', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(name: 'Llanowar Elves'),
      );
      expect(result.exact, isNull);
      expect(result.best, isNull, reason: 'two printings is not a decision');
      expect(result.candidates, hasLength(2));
      expect(result.note, contains('2 printings'));
    });

    test('settles itself when only one printing carries the name', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(name: 'Lightning Bolt'),
      );
      expect(result.candidates, hasLength(1));
      expect(result.best?.name, 'Lightning Bolt');
      expect(result.note, isNull);
    });

    test('does not offer near misses when the exact name is known', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(name: 'Llanowar Elves'),
      );
      // The fake matches on 'contains', so 'Lightning Bolt' would come back for
      // a search of 'light'; an exact name must prune it away.
      expect(
        result.candidates.every((TcgCard c) => c.name == 'Llanowar Elves'),
        isTrue,
      );
    });

    test('that matches nothing says so', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(name: 'Mox Emerald'),
      );
      expect(result.isEmpty, isTrue);
      expect(result.note, contains('Mox Emerald'));
    });
  });

  group('nothing useful was read', () {
    test('an empty scan is reported rather than searched for', () async {
      final result = await resolver.resolve(CardGame.mtg, const CardScan());
      expect(result.isEmpty, isTrue);
      expect(catalogue.asked, isEmpty);
    });

    test('a stub of a name is not worth a lookup', () async {
      final result = await resolver.resolve(
        CardGame.mtg,
        const CardScan(name: 'El'),
      );
      expect(result.isEmpty, isTrue);
      expect(catalogue.asked, isEmpty);
    });
  });

  test('a Pokemon card is resolved in its own game and not another', () async {
    final wrongGame = await resolver.resolve(
      CardGame.mtg,
      const CardScan(name: 'Charizard'),
    );
    expect(wrongGame.isEmpty, isTrue);

    final right = await resolver.resolve(
      CardGame.pokemon,
      const CardScan(name: 'Charizard', collectorNumber: '4'),
    );
    expect(right.best?.setCode, 'base1');
  });
}
