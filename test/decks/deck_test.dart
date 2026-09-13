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
}
