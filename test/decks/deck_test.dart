// Decks: what is in them, and whether the format allows it.
//
//   flutter test test/decks/deck_test.dart
//
// The rules are the point of the feature. A deck builder that says nothing
// when a Commander deck is 96 cards, or holds two Sol Rings, or plays a red
// card under a blue commander, is worse than a plain list of cards - it has
// taken on the authority of a judge and earned none of it.

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/deck_dao.dart';
import 'package:arcanum/data/db/wanted_dao.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_check.dart';
import 'package:arcanum/domain/decks/deck_format.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TcgCard card(
  String id, {
  String name = 'Card',
  List<String> identity = const <String>[],
  String? typeLine,
  double? price,
  CardGame game = CardGame.mtg,
}) => TcgCard(
  game: game,
  id: id,
  setCode: 'tst',
  setName: 'Test Set',
  name: name,
  collectorNumber: '1',
  rarity: 'common',
  typeLine: typeLine,
  colorIdentity: identity,
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{'nonfoil': price}),
);

DeckEntry entry(
  TcgCard c, {
  int quantity = 1,
  DeckBoard board = DeckBoard.main,
}) => DeckEntry(
  cardId: c.id,
  quantity: quantity,
  board: board,
  game: c.game,
  card: c,
);

/// A deck with these entries, in the named format.
DeckContents contents(
  String formatId,
  List<DeckEntry> entries, {
  Map<String, int> owned = const <String, int>{},
}) {
  final deck = Deck(
    id: 1,
    game: CardGame.mtg,
    name: 'Test',
    formatId: formatId,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  var value = 0.0;
  var missingValue = 0.0;
  for (final e in entries) {
    final price = e.card?.prices.from;
    if (price != null) value += price * e.quantity;
    final missing = e.missingWith(owned);
    if (missing > 0 && price != null) missingValue += price * missing;
  }
  return DeckContents(
    deck: deck,
    entries: entries,
    value: value,
    missingValue: missingValue,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('storing a deck', () {
    test('adds a card twice as two copies, not as two lines', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );

      await dao.addCard(id, 'goblin');
      await dao.addCard(id, 'goblin');

      final entries = await dao.entries(id, CardGame.mtg);
      expect(entries.length, 1);
      expect(entries.single.quantity, 2);
      await db.close();
    });

    test('setting a count to zero removes the line', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await dao.addCard(id, 'goblin', quantity: 3);

      await dao.setQuantity(id, 'goblin', DeckBoard.main, 0);

      expect(await dao.entries(id, CardGame.mtg), isEmpty);
      await db.close();
    });

    test('a card can be a commander and the move keeps its count', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await dao.addCard(id, 'krenko');

      await dao.moveCard(id, 'krenko', DeckBoard.main, DeckBoard.commander);

      final entries = await dao.entries(id, CardGame.mtg);
      expect(entries.single.board, DeckBoard.commander);
      expect(entries.single.quantity, 1);
      await db.close();
    });

    test('deleting a deck takes its lines with it', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await dao.addCard(id, 'goblin', quantity: 12);

      await dao.deleteDeck(id);

      final left = await db.db.query('deck_cards');
      expect(left, isEmpty, reason: 'the cascade should have cleaned up');
      await db.close();
    });

    test('the counts a list needs come back with the deck', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await dao.addCard(id, 'goblin', quantity: 4);
      await dao.addCard(id, 'mountain', quantity: 30);
      await dao.addCard(id, 'pyroblast', board: DeckBoard.side, quantity: 3);

      final deck = (await dao.decks(CardGame.mtg)).single;

      expect(deck.cardCount, 34);
      expect(deck.sideboardCount, 3);
      expect(deck.uniqueCards, 3);
      await db.close();
    });

    test('decks are scoped to their game', () async {
      final db = await AppDatabase.openInMemory();
      final dao = DeckDao(db.db);
      await dao.createDeck(game: CardGame.mtg, name: 'A', formatId: 'modern');
      await dao.createDeck(
        game: CardGame.lorcana,
        name: 'B',
        formatId: 'lorcana-core',
      );

      expect((await dao.decks(CardGame.mtg)).length, 1);
      expect((await dao.decks(CardGame.mtg)).single.name, 'A');
      await db.close();
    });
  });

  group('commander rules', () {
    /// A legal 100-card Commander deck, plus whatever is being tested, with
    /// the rest filled out so that the size rule never fires by accident.
    List<DeckEntry> hundred([List<DeckEntry> given = const <DeckEntry>[]]) {
      final entries = <DeckEntry>[
        entry(
          card(
            'cmd',
            name: 'Krenko',
            identity: <String>['R'],
            typeLine: 'Legendary Creature — Goblin',
          ),
          board: DeckBoard.commander,
        ),
        ...given,
      ];
      var have = 1 + given.fold<int>(0, (int a, DeckEntry e) => a + e.quantity);
      var n = 0;
      while (have < 100) {
        entries.add(
          entry(card('c$n', name: 'Goblin $n', identity: <String>['R'])),
        );
        have += 1;
        n += 1;
      }
      return entries;
    }

    TcgCard basicLand(String name) =>
        card('basic', name: name, typeLine: 'Basic Land — Mountain');

    test('a hundred singleton cards with a commander is clean', () {
      final result = checkDeck(contents('commander', hundred()));

      expect(
        result.errors,
        isEmpty,
        reason: result.errors.map((DeckIssue i) => i.title).join(', '),
      );
      // The ban list is the one thing it cannot vouch for, and it says so.
      expect(result.issues.map((DeckIssue i) => i.title), <String>[
        'Ban list not checked',
      ]);
    });

    test('a second copy of a card is an error', () {
      final result = checkDeck(
        contents(
          'commander',
          hundred(<DeckEntry>[
            entry(card('dup', name: 'Sol Ring'), quantity: 2),
          ]),
        ),
      );

      final issue = result.errors.single;
      expect(issue.title, contains('More than one copy'));
      expect(issue.cards.single, contains('Sol Ring'));
    });

    test('basic lands are exempt from the singleton rule', () {
      final result = checkDeck(
        contents(
          'commander',
          hundred(<DeckEntry>[entry(basicLand('Mountain'), quantity: 30)]),
        ),
      );

      expect(result.errors, isEmpty);
      expect(result.isLegal, isTrue);
    });

    test('a card outside the commander colours is an error', () {
      final result = checkDeck(
        contents(
          'commander',
          hundred(<DeckEntry>[
            entry(card('blue', name: 'Counterspell', identity: <String>['U'])),
          ]),
        ),
      );

      final issue = result.errors.single;
      expect(issue.title, contains('colours'));
      expect(issue.cards.single, contains('Counterspell'));
    });

    test('a deck with no commander cannot be judged on colour', () {
      final entries = hundred()..removeAt(0);
      final result = checkDeck(contents('commander', entries));

      expect(
        result.errors.map((DeckIssue i) => i.title),
        contains('No commander'),
      );
    });
  });

  group('constructed rules', () {
    test('four copies is fine and a fifth is not, sideboard included', () {
      final four = <DeckEntry>[
        entry(card('bolt', name: 'Lightning Bolt'), quantity: 4),
      ];
      expect(checkDeck(contents('modern', four)).isLegal, isTrue);

      final five = <DeckEntry>[
        entry(card('bolt', name: 'Lightning Bolt'), quantity: 4),
        entry(
          card('bolt', name: 'Lightning Bolt'),
          quantity: 1,
          board: DeckBoard.side,
        ),
      ];
      final result = checkDeck(contents('modern', five));

      expect(result.isLegal, isFalse);
      expect(result.errors.single.detail, contains('counting the sideboard'));
    });

    test('a fifteen card sideboard is fine and sixteen is not', () {
      final entries = <DeckEntry>[
        for (var i = 0; i < 16; i++)
          entry(card('s$i', name: 'Side $i'), board: DeckBoard.side),
      ];

      final result = checkDeck(contents('modern', entries));

      expect(
        result.errors.map((DeckIssue i) => i.title),
        contains('Sideboard too large'),
      );
    });

    test('a short deck is a warning rather than an error', () {
      final result = checkDeck(
        contents('modern', <DeckEntry>[entry(card('a', name: 'A'))]),
      );

      expect(result.isLegal, isTrue);
      expect(
        result.issues.map((DeckIssue i) => i.title),
        contains('Not enough cards'),
      );
    });
  });

  group('the banned list', () {
    List<DeckEntry> sixty({String name = 'Bolt'}) => <DeckEntry>[
      for (var i = 0; i < 59; i++) entry(card('f$i', name: 'Filler $i')),
      entry(card('banned', name: name)),
    ];

    test('a banned card is an error when the list is known', () {
      final result = checkDeck(
        contents('modern', sixty()),
        bannedNames: const <String>{'Bolt'},
        banListChecked: true,
      );

      expect(
        result.errors.map((DeckIssue i) => i.title).single,
        contains('Banned'),
      );
    });

    test('an unfetched list is reported as unchecked, not as clean', () {
      // The distinction the whole feature turns on: silence would read as
      // approval, and the app has not earned that.
      final result = checkDeck(contents('modern', sixty()));

      expect(result.banListChecked, isFalse);
      expect(
        result.issues.map((DeckIssue i) => i.title),
        contains('Ban list not checked'),
      );
    });

    test('a card not in the catalogue is called out', () {
      final entries = <DeckEntry>[
        entry(card('known', name: 'Known')),
        const DeckEntry(
          cardId: 'missing',
          quantity: 1,
          board: DeckBoard.main,
          game: CardGame.mtg,
        ),
      ];

      final result = checkDeck(contents('modern', entries));

      expect(
        result.issues.map((DeckIssue i) => i.title),
        contains('Not in the catalogue'),
      );
    });
  });

  group('what a deck is worth', () {
    test('counts the gap between what is wanted and what is owned', () {
      final deck = contents(
        'modern',
        <DeckEntry>[entry(card('bolt', name: 'Bolt', price: 2.0), quantity: 4)],
        owned: <String, int>{'bolt': 1},
      );

      expect(deck.value, 8.0);
      expect(deck.missingWith(<String, int>{'bolt': 1}), 3);
      expect(deck.missingValue, 6.0);
      expect(deck.completeWith(<String, int>{'bolt': 1}), isFalse);
      expect(deck.completeWith(<String, int>{'bolt': 4}), isTrue);
    });
  });

  group('a deck survives a backup', () {
    test('the deck and its lines come back', () async {
      final source = await AppDatabase.openInMemory();
      final dao = DeckDao(source.db);
      final id = await dao.createDeck(
        game: CardGame.mtg,
        name: 'Krenko',
        formatId: 'commander',
      );
      await dao.addCard(id, 'goblin', quantity: 4);

      final decks = await source.db.query('decks');
      final lines = await source.db.query('deck_cards');
      await source.close();

      final target = await AppDatabase.openInMemory();
      await target.db.insert('decks', decks.single);
      await target.db.insert('deck_cards', lines.single);

      final back = (await DeckDao(target.db).decks(CardGame.mtg)).single;
      expect(back.name, 'Krenko');
      expect(back.cardCount, 4);
      // Wants are a separate table and must not have been disturbed by this.
      expect(await WantedDao(target.db).count(CardGame.mtg), 0);
      await target.close();
    });
  });

  group('what one card means to a copy limit', () {
    /// A printing with everything the copy rules read: its own id, the set and
    /// number it prints, and the identity that groups its reprints.
    TcgCard printing(
      String id, {
      required String number,
      String set = 'tst',
      String? oracle,
      String name = 'Lightning Bolt',
      CardGame game = CardGame.mtg,
    }) => TcgCard(
      game: game,
      id: id,
      setCode: set,
      setName: 'Test Set',
      name: name,
      collectorNumber: number,
      rarity: 'common',
      oracleId: oracle,
    );

    test('a Magic deck counts the card, not the printing', () {
      // Four Lightning Bolts is four Lightning Bolts however many sets they
      // were printed in, and a deck holding four from M10 and four from M11 is
      // an illegal deck that a printing-by-printing check calls legal.
      final m10 = printing('m10-1', number: '146', oracle: 'bolt');
      final m11 = printing('m11-1', number: '149', oracle: 'bolt');

      final result = checkDeck(
        contents('modern', <DeckEntry>[
          entry(m10, quantity: 4),
          entry(m11, quantity: 4),
        ]),
      );

      expect(result.isLegal, isFalse);
      expect(result.errors.single.title, 'More than 4 copies of a card');
    });

    test('and two different cards are still two cards', () {
      final bolt = printing('m10-1', number: '146', oracle: 'bolt');
      final shock = printing(
        'm10-2',
        number: '147',
        oracle: 'shock',
        name: 'Shock',
      );

      expect(
        checkDeck(
          contents('modern', <DeckEntry>[
            entry(bolt, quantity: 4),
            entry(shock, quantity: 4),
          ]),
        ).isLegal,
        isTrue,
      );
    });

    test('a One Piece deck counts parallel arts together', () {
      // The card's number is what One Piece writes its four-of rule against,
      // and the original art and its parallel are two products with two ids
      // and one number between them.
      final original = printing(
        '3188-453600',
        number: '010',
        set: 'op01',
        game: CardGame.onePiece,
        name: 'Nami',
      );
      final parallel = printing(
        '3188-453601',
        number: '010',
        set: 'op01',
        game: CardGame.onePiece,
        name: 'Nami (Parallel)',
      );

      // A Leader, because the format needs one and says so: what is being
      // tested here is the copy rule, and a deck failing for a second reason
      // would not tell the two apart.
      final leader = printing(
        '3188-453505',
        number: '002',
        set: 'op01',
        game: CardGame.onePiece,
        name: 'Trafalgar Law',
      );

      // Three of one art and one of the other is the four the rules allow.
      expect(
        checkDeck(
          contents('onepiece-standard', <DeckEntry>[
            entry(leader, board: DeckBoard.commander),
            entry(original, quantity: 3),
            entry(parallel, quantity: 1),
          ]),
        ).isLegal,
        isTrue,
      );

      final fifth = checkDeck(
        contents('onepiece-standard', <DeckEntry>[
          entry(leader, board: DeckBoard.commander),
          entry(original, quantity: 3),
          entry(parallel, quantity: 2),
        ]),
      );
      expect(fifth.isLegal, isFalse);
      expect(
        fifth.errors.map((DeckIssue i) => i.title),
        contains('More than 4 copies of a card'),
      );
    });

    test('a Digimon deck counts them together too', () {
      final a = printing(
        '24623-1',
        number: '052',
        set: 'bt26',
        game: CardGame.digimon,
        name: 'Agumon',
      );
      final b = printing(
        '24623-2',
        number: '052',
        set: 'bt26',
        game: CardGame.digimon,
        name: 'Agumon (Alternate Art)',
      );
      // Two different numbers, in the same set, are two different cards.
      final c = printing(
        '24623-3',
        number: '053',
        set: 'bt26',
        game: CardGame.digimon,
        name: 'Gabumon',
      );

      expect(
        checkDeck(
          contents('digimon-standard', <DeckEntry>[
            entry(a, quantity: 4),
            entry(b, quantity: 4),
          ]),
        ).isLegal,
        isFalse,
      );
      expect(
        checkDeck(
          contents('digimon-standard', <DeckEntry>[
            entry(a, quantity: 2),
            entry(c, quantity: 2),
          ]),
        ).isLegal,
        isTrue,
      );
    });

    test('a Pokemon deck still counts the printing', () {
      // Pokemon prints one product per playable card and its variants are
      // finishes of that product, so the id is the card.
      final a = printing(
        'base1-4',
        number: '4',
        set: 'base1',
        game: CardGame.pokemon,
        name: 'Charizard',
      );
      final b = printing(
        'base1-4x',
        number: '4',
        set: 'base1',
        game: CardGame.pokemon,
        name: 'Charizard',
      );
      expect(
        checkDeck(
          contents('pokemon-standard', <DeckEntry>[
            entry(a, quantity: 4),
            entry(b, quantity: 4),
          ]),
        ).isLegal,
        isTrue,
      );
    });
  });

  group('the formats of the games TCGplayer catalogs', () {
    test('One Piece is a Leader and exactly fifty cards', () {
      final format = DeckFormats.forGame(CardGame.onePiece).first;
      expect(format.id, 'onepiece-standard');
      expect(format.minCards, 50);
      expect(format.maxCards, 50);
      expect(format.maxCopies, 4);
      expect(format.hasCommander, isTrue);
      expect(format.usesColourIdentity, isTrue);
      expect(format.copyKey, DeckCopyKey.printedNumber);
    });

    test('Unlimited has Premier and Twin Suns', () {
      final formats = DeckFormats.forGame(CardGame.starWarsUnlimited);
      final premier = formats.firstWhere(
        (DeckFormat f) => f.id == 'swu-premier',
      );
      expect(premier.minCards, 50);
      expect(premier.maxCards, isNull);
      expect(premier.maxCopies, 3);

      final twinSuns = formats.firstWhere(
        (DeckFormat f) => f.id == 'swu-twin-suns',
      );
      expect(twinSuns.minCards, 80);
      expect(twinSuns.maxCards, 80);
      expect(twinSuns.singleton, isTrue);
    });

    test('Digimon is exactly fifty with four of a number', () {
      final format = DeckFormats.forGame(CardGame.digimon).first;
      expect(format.minCards, 50);
      expect(format.maxCards, 50);
      expect(format.maxCopies, 4);
      // What the app does not model, it says it does not model.
      expect(format.notes, contains('Digi-Egg'));
    });

    test('Fusion World is a Leader and fifty to sixty cards', () {
      // The official rule: one Leader, and a deck of 50 to 60 cards with no
      // more than four copies of a card number. The Leader gates the colours
      // exactly as One Piece's does, so it is held the same way.
      final format = DeckFormats.forGame(CardGame.dragonBall).first;
      expect(format.id, 'dragonball-standard');
      expect(format.minCards, 50);
      expect(format.maxCards, 60);
      expect(format.maxCopies, 4);
      expect(format.hasCommander, isTrue);
      expect(format.usesColourIdentity, isTrue);
      expect(format.copyKey, DeckCopyKey.printedNumber);
    });

    test('Gundam is exactly fifty, and says what it does not check', () {
      final format = DeckFormats.forGame(CardGame.gundam).first;
      expect(format.minCards, 50);
      expect(format.maxCards, 50);
      expect(format.maxCopies, 4);
      expect(format.copyKey, DeckCopyKey.printedNumber);
      // The resource deck and the two-colour limit are real rules the app does
      // not model, and the format says so rather than staying quiet.
      expect(format.notes, contains('resource deck'));
      expect(format.notes, contains('two-colour'));
    });

    test('every format of every game can be judged', () {
      for (final game in CardGame.values) {
        final formats = DeckFormats.forGame(game);
        expect(formats, isNotEmpty, reason: game.id);
        for (final format in formats) {
          expect(format.game, game, reason: format.id);
          expect(format.minCards, greaterThanOrEqualTo(0), reason: format.id);
          if (format.maxCards != null) {
            expect(
              format.maxCards,
              greaterThanOrEqualTo(format.minCards),
              reason: format.id,
            );
          }
          expect(format.maxCopies, greaterThan(0), reason: format.id);
        }
      }
    });

    test('a One Piece deck outside its Leader is not legal', () {
      // One Piece is the one game here whose colour rule is absolute: every
      // card in the deck must match the colour of the Leader.
      final leader = TcgCard(
        game: CardGame.onePiece,
        id: '3188-453505',
        setCode: 'op01',
        setName: 'Romance Dawn',
        name: 'Trafalgar Law',
        collectorNumber: '002',
        rarity: 'L',
        colorIdentity: const <String>['Green'],
      );
      final stray = TcgCard(
        game: CardGame.onePiece,
        id: '3188-453600',
        setCode: 'op01',
        setName: 'Romance Dawn',
        name: 'Nami',
        collectorNumber: '010',
        rarity: 'C',
        colorIdentity: const <String>['Blue'],
      );

      final result = checkDeck(
        contents('onepiece-standard', <DeckEntry>[
          entry(leader, board: DeckBoard.commander),
          entry(stray),
        ]),
      );

      expect(result.isLegal, isFalse);
      expect(
        result.errors.map((DeckIssue i) => i.title),
        contains("Outside the commander's colours"),
      );
    });
  });
}
