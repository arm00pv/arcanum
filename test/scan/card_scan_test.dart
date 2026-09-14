// Reading a card out of a photograph of it.
//
//   flutter test test/scan/card_scan_test.dart
//
// This is the part of scanning that can be checked without a camera, so it is
// where the work is. The strings below are shaped like what a text recogniser
// actually returns from a phone held over a card: the right words, in the right
// places, with the punctuation mangled. A reader that trusts a line's content
// alone reports a set called 'R' - the rarity - and a card called 'Legendary'.

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/scan/card_scan.dart';
import 'package:flutter_test/flutter_test.dart';

/// A line at a position down the card, 0 at the top edge and 1 at the bottom.
ScannedLine at(double top, String text, {double height = 0.03}) =>
    ScannedLine(text, top: top, height: height);

/// A Magic card, laid out the way one is printed.
List<ScannedLine> mtgCard({
  String name = 'Revel in Riches',
  String mana = '4 B',
  String type = 'Enchantment',
  String bottom = '117/279 R',
  String setLine = 'XLN • EN',
  String artist = 'Eric Deschamps',
  String rules =
      'Whenever a creature an opponent controls dies, create a '
      'colorless Treasure artifact token.',
}) => <ScannedLine>[
  at(0.05, name, height: 0.05),
  at(0.10, mana),
  at(0.55, type),
  at(0.60, rules),
  at(0.86, bottom, height: 0.02),
  at(0.89, setLine, height: 0.02),
  at(0.92, artist, height: 0.02),
];

const Set<String> known = <String>{
  'XLN',
  '2X2',
  'M21',
  'EOS',
  'TDC',
  'FIC',
  'NEO',
  'DMU',
};

void main() {
  group('a Magic card', () {
    test('set, number, size and name all come off it', () {
      final scan = readCardText(
        mtgCard(),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.setCode, 'XLN');
      expect(scan.collectorNumber, '117');
      expect(scan.setSize, 279);
      expect(scan.name, 'Revel in Riches');
      expect(scan.isAddressable, isTrue);
    });

    test('the rarity and the language are not set codes', () {
      final scan = readCardText(
        mtgCard(setLine: 'R  EN'),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, '117');
    });

    test('a reader that loses the slash still gives up the number', () {
      final scan = readCardText(
        mtgCard(bottom: '117 279', setLine: 'XLN EN'),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.collectorNumber, '117');
      expect(scan.setCode, 'XLN');
    });

    test('a reader that turns the slash into a pipe or a one still works', () {
      for (final String mangled in <String>['117|279', '117l279', '117!279']) {
        final scan = readCardText(
          mtgCard(bottom: '$mangled R'),
          game: CardGame.mtg,
          knownSetCodes: known,
        );
        expect(scan.collectorNumber, '117', reason: mangled);
        expect(scan.setSize, 279, reason: mangled);
      }
    });

    test(
      'without a catalogue to check against, the bullet pair is the hint',
      () {
        final scan = readCardText(mtgCard(), game: CardGame.mtg);
        expect(scan.setCode, 'XLN');
      },
    );

    test('a set code with a digit in it is only accepted from the catalogue', () {
      final verified = readCardText(
        mtgCard(setLine: '2X2 • EN'),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(verified.setCode, '2X2');

      final unverified = readCardText(
        mtgCard(setLine: '2X2 • EN'),
        game: CardGame.mtg,
      );
      // Nothing here can tell '2X2' from a number the reader ran together, and
      // guessing would send the lookup to a set the card is not in.
      expect(unverified.setCode, isNot('2X2'));
    });

    test('the type line is not the name', () {
      final scan = readCardText(
        <ScannedLine>[
          at(0.55, 'LEGENDARY CREATURE'),
          at(0.86, '117/279 R'),
          at(0.89, 'XLN • EN'),
        ],
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.name, isNull);
      expect(scan.setCode, 'XLN');
    });

    test('a name glued to its mana cost is separated', () {
      final scan = readCardText(
        <ScannedLine>[at(0.05, 'Revel in Riches 4B'), at(0.89, 'XLN • EN')],
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.name, 'Revel in Riches');
    });

    test('lines arriving out of order are put back in order', () {
      final scan = readCardText(
        <ScannedLine>[
          at(0.89, 'XLN • EN'),
          at(0.05, 'Revel in Riches'),
          at(0.86, '117/279 R'),
        ],
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.name, 'Revel in Riches');
      expect(scan.setCode, 'XLN');
    });

    test('a lone bottom line is still read', () {
      final scan = readCardText(
        <ScannedLine>[at(0.5, '117/279 R XLN EN')],
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.collectorNumber, '117');
      expect(scan.setCode, 'XLN');
    });

    test('a set code split onto its own line is still read', () {
      final scan = readCardText(
        <ScannedLine>[
          at(0.05, 'Revel in Riches', height: 0.05),
          at(0.90, '117/279'),
          at(0.94, 'XLN'),
          at(0.96, 'EN >ERIC DESCHAMPS'),
        ],
        game: CardGame.mtg,
        knownSetCodes: <String>{...known, 'ONE', 'WAR'},
      );
      expect(scan.setCode, 'XLN');
      expect(scan.collectorNumber, '117');
    });

    test('a word in the rules is not the set code', () {
      // A real reading, off a phone, of a real card. The reader cut the rules
      // into short lines and one of them sat low enough to count as the bottom
      // strip, where 'one' - as in 'Add one mana of any color' - is exactly the
      // letters of Phyrexia: All Will Be One. The catalogue's own list of set
      // codes is what turns that list from a shortcut into a trap.
      final scan = readCardText(
        <ScannedLine>[
          at(0.30, '4', height: 0.05),
          at(0.33, 'Revel in Riches', height: 0.05),
          at(0.42, 'Enchantment'),
          at(0.72, 'controls dies, create a'),
          at(0.75, 'colorless Treasure'),
          at(0.78, 'artifact: Add one mana of any color to'),
          at(0.81, 'At the beginning of your upkeep, if'),
          at(0.84, 'control ten or more Treasures, you win'),
          at(0.87, 'the'),
          at(0.89, 'game'),
          at(0.91, '117/279'),
          at(0.92, 'R'),
          at(0.93, 'TM & O2017 Wizards of the'),
          at(0.94, 'Coast'),
          at(0.95, 'XLN'),
          at(0.96, 'EN >ERIC DESCHAMPS'),
        ],
        game: CardGame.mtg,
        knownSetCodes: <String>{...known, 'ONE', 'WAR'},
      );
      expect(scan.setCode, 'XLN');
      expect(scan.collectorNumber, '117');
      expect(scan.setSize, 279);
      expect(scan.name, 'Revel in Riches');
    });

    test('a lowercase word alone on a line is not a set code', () {
      final scan = readCardText(
        <ScannedLine>[
          at(0.05, 'Revel in Riches', height: 0.05),
          at(0.80, 'one'),
          at(0.90, '117/279'),
          at(0.94, 'EN'),
        ],
        game: CardGame.mtg,
        knownSetCodes: <String>{'ONE', 'XLN'},
      );
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, '117');
    });
  });

  group('Yu-Gi-Oh!', () {
    test('one code carries both the set and the number', () {
      final scan = readCardText(<ScannedLine>[
        at(0.04, 'Blue-Eyes White Dragon', height: 0.05),
        at(0.88, 'LOB-EN001', height: 0.02),
        at(0.92, '1996 KAZUKI TAKAHASHI'),
      ], game: CardGame.yugioh);
      expect(scan.setCode, 'LOB');
      expect(scan.collectorNumber, '001');
      expect(scan.name, 'Blue-Eyes White Dragon');
      expect(scan.isAddressable, isTrue);
    });

    test('the region in the middle is not part of the number', () {
      final scan = readCardText(<ScannedLine>[
        at(0.88, 'SDK-EN001'),
      ], game: CardGame.yugioh);
      expect(scan.setCode, 'SDK');
      expect(scan.collectorNumber, '001');
    });

    test('a code printed without a region still works', () {
      final scan = readCardText(<ScannedLine>[
        at(0.88, 'LOB-001'),
      ], game: CardGame.yugioh);
      expect(scan.setCode, 'LOB');
      expect(scan.collectorNumber, '001');
    });
  });

  group('games that print no set code', () {
    test('Pokemon gives a number and a name and nothing else', () {
      final scan = readCardText(<ScannedLine>[
        at(0.04, 'Charizard', height: 0.05),
        at(0.88, '4/102', height: 0.02),
        at(0.92, '1999 Wizards of the Coast'),
      ], game: CardGame.pokemon);
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, '4');
      expect(scan.setSize, 102);
      expect(scan.name, 'Charizard');
      // The number alone does not name a printing, and the app says so by
      // leaving isAddressable false.
      expect(scan.isAddressable, isFalse);
    });

    test('Lorcana does the same', () {
      final scan = readCardText(<ScannedLine>[
        at(0.04, 'Elsa - Snow Queen', height: 0.05),
        at(0.88, '46/204', height: 0.02),
      ], game: CardGame.lorcana);
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, '46');
    });
  });

  group('awkward pictures', () {
    test('nothing read is nothing claimed', () {
      final scan = readCardText(const <ScannedLine>[], game: CardGame.mtg);
      expect(scan.isEmpty, isTrue);
      expect(scan.isAddressable, isFalse);
    });

    test('blank and punctuation-only lines are dropped', () {
      final scan = readCardText(<ScannedLine>[
        at(0.05, '   '),
        at(0.10, '---'),
        at(0.86, '117/279'),
      ], game: CardGame.mtg);
      expect(scan.collectorNumber, '117');
      expect(scan.lines, <String>['117/279']);
    });

    test('a reader that reads a zero as an O is corrected against a digit', () {
      final scan = readCardText(<ScannedLine>[
        at(0.86, '12O/279'),
      ], game: CardGame.mtg);
      expect(scan.collectorNumber, '120');
    });

    test('the raw lines are kept so a person can see what it saw', () {
      final scan = readCardText(
        mtgCard(),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.lines, contains('XLN • EN'));
      expect(scan.lines, contains('Eric Deschamps'));
    });

    test('toString is readable, for logs', () {
      final scan = readCardText(
        mtgCard(),
        game: CardGame.mtg,
        knownSetCodes: known,
      );
      expect(scan.toString(), contains('XLN'));
      expect(scan.toString(), contains('117'));
    });
  });

  group('a One Piece card', () {
    /// An One Piece card, laid out the way one is printed: the name at the top
    /// and the one hyphenated code under the art, with nothing else on it that
    /// looks like a set.
    List<ScannedLine> onePieceCard({
      String name = 'Monkey.D.Luffy',
      String bottom = 'OP01-003',
      String type = 'Leader',
    }) => <ScannedLine>[
      at(0.05, name, height: 0.05),
      at(0.12, type, height: 0.03),
      at(0.86, bottom, height: 0.02),
      at(0.90, 'P-070', height: 0.02),
    ];

    test('set and number come off the one code it prints', () {
      final scan = readCardText(onePieceCard(), game: CardGame.onePiece);
      // The code the card prints is the code the catalogue stores: the shop
      // spells the set 'OP-01' and the card spells it 'OP01', and only the
      // second is a match.
      expect(scan.setCode, 'OP01');
      expect(scan.collectorNumber, '003');
      expect(scan.name, 'Monkey.D.Luffy');
    });

    test('a starter deck is read the same way', () {
      final scan = readCardText(
        onePieceCard(name: 'Roronoa Zoro', bottom: 'ST31-001'),
        game: CardGame.onePiece,
      );
      expect(scan.setCode, 'ST31');
      expect(scan.collectorNumber, '001');
    });

    test('with nothing readable it offers the name alone', () {
      // A photograph of the top half of a card still narrows a search.
      final scan = readCardText(<ScannedLine>[
        at(0.05, 'Nami', height: 0.05),
      ], game: CardGame.onePiece);
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, isNull);
      expect(scan.name, 'Nami');
    });
  });

  group('a Digimon card', () {
    test('set and number come off a code with a rarity stuck to it', () {
      final scan = readCardText(<ScannedLine>[
        at(0.05, 'Agumon', height: 0.05),
        at(0.86, 'BT26-052 C', height: 0.02),
      ], game: CardGame.digimon);
      // The rarity on the end is not part of the position, and the set is
      // stored the way the card prints it rather than the way the shop does.
      expect(scan.setCode, 'BT26');
      expect(scan.collectorNumber, '052');
      expect(scan.name, 'Agumon');
    });

    test('an extra booster is read the same way', () {
      final scan = readCardText(<ScannedLine>[
        at(0.05, 'Omnimon', height: 0.05),
        at(0.86, 'EX13-011 U', height: 0.02),
      ], game: CardGame.digimon);
      expect(scan.setCode, 'EX13');
      expect(scan.collectorNumber, '011');
    });
  });

  group('a Star Wars: Unlimited card', () {
    test('prints a fraction of the set and no code at all', () {
      final scan = readCardText(<ScannedLine>[
        at(0.05, 'Grand Admiral Thrawn', height: 0.05),
        at(0.86, '094/264', height: 0.02),
      ], game: CardGame.starWarsUnlimited);
      // No set code on the card, and a token that merely looked like one would
      // send the lookup to a set the card is not in.
      expect(scan.setCode, isNull);
      expect(scan.collectorNumber, '094');
      expect(scan.name, 'Grand Admiral Thrawn');
    });
  });
}
