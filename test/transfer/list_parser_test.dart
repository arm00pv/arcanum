// Reading a card list somebody pasted in.
//
//   flutter test test/transfer/list_parser_test.dart
//
// The parser is the part of the import that can go wrong quietly: a line it
// misreads becomes a card in the collection that is not there, and nobody
// notices for a year. So these tests pin the shapes that must work and, just
// as importantly, the shapes that must be refused rather than guessed at.

import 'package:arcanum/data/transfer/list_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ListEntry only(String text) {
  final parsed = parseList(text);
  expect(parsed.entries, hasLength(1), reason: text);
  return parsed.entries.single;
}

void main() {
  group('the ways a quantity is written', () {
    test('leading number', () {
      final e = only('4 Lightning Bolt');
      expect(e.quantity, 4);
      expect(e.name, 'Lightning Bolt');
    });

    test('leading number with an x', () {
      expect(only('4x Counterspell').quantity, 4);
      expect(only('4 x Counterspell').quantity, 4);
    });

    test('trailing x and number', () {
      final e = only('Sol Ring x2');
      expect(e.quantity, 2);
      expect(e.name, 'Sol Ring');
    });

    test('no number at all means one', () {
      final e = only('Sol Ring');
      expect(e.quantity, 1);
      expect(e.name, 'Sol Ring');
    });

    test('a bullet from a chat message is not part of the name', () {
      expect(only('- 4 Lightning Bolt').name, 'Lightning Bolt');
      expect(only('* 4 Lightning Bolt').name, 'Lightning Bolt');
    });
  });

  group('the ways a printing is written', () {
    test('set and number in brackets', () {
      final e = only('4 Lightning Bolt (LEA) 161');
      expect(e.setCode, 'LEA');
      expect(e.collectorNumber, '161');
      expect(e.name, 'Lightning Bolt');
      expect(e.isExact, isTrue);
    });

    test('set only', () {
      final e = only('4 Lightning Bolt (2X2)');
      expect(e.setCode, '2X2');
      expect(e.collectorNumber, isNull);
      expect(e.name, 'Lightning Bolt');
      expect(e.isExact, isFalse);
    });

    test('square brackets work the same way', () {
      final e = only('4 Lightning Bolt [LEA] 161');
      expect(e.setCode, 'LEA');
      expect(e.collectorNumber, '161');
    });

    test('a foil marker is read and removed from the name', () {
      final e = only('1 Sol Ring (LTC) 284 *F*');
      expect(e.foil, isTrue);
      expect(e.name, 'Sol Ring');
      expect(e.setCode, 'LTC');
      expect(e.collectorNumber, '284');
    });

    test('the word foil counts too', () {
      final e = only('1 Sol Ring (LTC) 284 Foil');
      expect(e.foil, isTrue);
      expect(e.name, 'Sol Ring');
    });

    test('a non-foil line is not marked foil', () {
      expect(only('1 Sol Ring').foil, isFalse);
    });
  });

  group('names that contain punctuation', () {
    test('parentheses in a real name survive', () {
      // Stripping every bracket would turn this into a card called Erase,
      // which does not exist, and the import would fail silently.
      final e = only("1 Erase (Not the Urza's Legacy One)");
      expect(e.name, "Erase (Not the Urza's Legacy One)");
      expect(e.setCode, isNull);
    });

    test('apostrophes and dashes survive', () {
      expect(only("4 Aragorn's Company").name, "Aragorn's Company");
      expect(only('1 Aether-Vial').name, 'Aether-Vial');
    });

    test('a modal card keeps both faces', () {
      expect(only('1 Fire // Ice').name, 'Fire // Ice');
    });

    test('a trailing comma from prose is dropped', () {
      expect(only('4 Lightning Bolt,').name, 'Lightning Bolt');
    });
  });

  group('what gets skipped', () {
    test('section headings are passed over and reported', () {
      final parsed = parseList(
        'Deck\n4 Lightning Bolt\nSideboard\n2 Pyroblast',
      );
      expect(parsed.entries, hasLength(2));
      expect(parsed.sections, <String>['Deck', 'Sideboard']);
      expect(parsed.entries.map((ListEntry e) => e.name), <String>[
        'Lightning Bolt',
        'Pyroblast',
      ]);
    });

    test('comments and blank lines are ignored', () {
      final parsed = parseList('// my deck\n\n# a note\n4 Lightning Bolt');
      expect(parsed.entries, hasLength(1));
      expect(parsed.rejected, isEmpty);
    });

    test('a line with no name is rejected rather than invented', () {
      final parsed = parseList('4\n4 Lightning Bolt');
      expect(parsed.entries, hasLength(1));
      expect(parsed.rejected, hasLength(1));
      expect(parsed.rejected.single.line, 1);
    });
  });

  group('the list as a whole', () {
    test('counts cards, not lines', () {
      final parsed = parseList('4 Lightning Bolt\n2 Pyroblast');
      expect(parsed.entries, hasLength(2));
      expect(parsed.cards, 6);
    });

    test('line numbers refer to the pasted text', () {
      final parsed = parseList('Deck\n\n4 Lightning Bolt');
      expect(parsed.entries.single.line, 3);
    });

    test('an empty paste is empty rather than an error', () {
      expect(parseList('').isEmpty, isTrue);
      expect(parseList('   \n\n  ').isEmpty, isTrue);
    });

    test('a whole realistic deck list reads cleanly', () {
      final parsed = parseList('''
// Krenko, Mob Boss
Commander
1 Krenko, Mob Boss (M13) 213

Deck
30 Mountain (UNF) 240
4 Skirk Prospector (DOM) 139
4 Goblin Warchief (M15) 219 *F*

Sideboard
2 Pyroblast (ICE) 213
''');
      expect(parsed.cards, 41);
      expect(parsed.entries, hasLength(5));
      expect(parsed.sections, hasLength(3));
      expect(parsed.rejected, isEmpty);
      expect(
        parsed.entries.firstWhere((ListEntry e) => e.foil).name,
        'Goblin Warchief',
      );
      expect(
        parsed.entries
            .firstWhere((ListEntry e) => e.name == 'Mountain')
            .quantity,
        30,
      );
    });
  });
}
