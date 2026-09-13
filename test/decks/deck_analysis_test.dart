// Reading a deck, and suggesting what to add from what is already owned.
//
//   flutter test test/decks/deck_analysis_test.dart
//
// Two things are being pinned down here. First, that the reading only ever
// claims what the cards actually say: a role comes from printed rules text, an
// unreadable card is admitted rather than guessed at, and a deck the app cannot
// read gets no advice instead of invented advice. Second, that a suggestion can
// always be argued with - every one carries the numbers behind it, and never
// proposes something the format forbids or the collector does not own.

import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_analysis.dart';
import 'package:arcanum/domain/decks/deck_check.dart';
import 'package:arcanum/domain/decks/deck_roles.dart';
import 'package:arcanum/domain/decks/deck_suggestions.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

/// A card with just enough filled in for the reader to have an opinion.
TcgCard mtg(
  String name, {
  String? id,
  String? text,
  String? type = 'Creature',
  double? cmc,
  List<String> identity = const <String>['G'],
  int? edhrec,
  List<String> faceText = const <String>[],
  CardGame game = CardGame.mtg,
  Map<String, Object?> extras = const <String, Object?>{},
}) => TcgCard(
  game: game,
  id: id ?? name.toLowerCase().replaceAll(' ', '-'),
  setCode: 'tst',
  setName: 'Test Set',
  name: name,
  collectorNumber: '1',
  rarity: 'common',
  typeLine: type,
  oracleText: text,
  cmc: cmc,
  colorIdentity: identity,
  edhrecRank: edhrec,
  extras: extras,
  faces: <TcgCardFace>[for (final String t in faceText) TcgCardFace(text: t)],
);

DeckEntry line(
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

DeckContents deck(
  String formatId,
  List<DeckEntry> entries, {
  CardGame game = CardGame.mtg,
}) => DeckContents(
  deck: Deck(
    id: 1,
    game: game,
    name: 'Test',
    formatId: formatId,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  entries: entries,
  value: 0,
  missingValue: 0,
);

/// Fills a Commander deck out to exactly a hundred with unremarkable forests.
DeckContents commanderDeck(List<DeckEntry> entries) {
  final filler = <DeckEntry>[
    for (int i = 0; i < 40; i++)
      line(mtg('Forest $i', type: 'Basic Land — Forest')),
  ];
  final held = entries.fold(0, (int a, DeckEntry e) => a + e.quantity);
  final room = 100 - held - filler.length;
  return deck('commander', <DeckEntry>[
    ...entries,
    ...filler,
    if (room > 0)
      for (int i = 0; i < room; i++)
        line(mtg('Bear $i', text: 'Vanilla.', cmc: 2)),
  ]);
}

void main() {
  group('reading roles off the cards', () {
    test('a land is a land and nothing else', () {
      final fetch = mtg(
        'Evolving Wilds',
        type: 'Land',
        text: 'Sacrifice this land: search your library for a basic land.',
      );
      expect(rolesOf(fetch), <DeckRole>{DeckRole.land});
    });

    test('a mana ability reads as ramp', () {
      expect(
        rolesOf(mtg('Elf', text: 'Tap: Add {G}.')),
        contains(DeckRole.ramp),
      );
      expect(
        rolesOf(
          mtg('Signet', type: 'Artifact', text: 'Add one mana of any color.'),
        ),
        contains(DeckRole.ramp),
      );
    });

    test('drawing reads as draw', () {
      expect(
        rolesOf(mtg('Divination', type: 'Sorcery', text: 'Draw two cards.')),
        contains(DeckRole.draw),
      );
    });

    test('spot removal and a wipe are different jobs', () {
      final spot = rolesOf(
        mtg('Doom Blade', type: 'Instant', text: 'Destroy target creature.'),
      );
      expect(spot, contains(DeckRole.removal));
      expect(spot, isNot(contains(DeckRole.wipe)));

      final wipe = rolesOf(
        mtg('Wrath', type: 'Sorcery', text: 'Destroy all creatures.'),
      );
      expect(wipe, contains(DeckRole.wipe));
      expect(wipe, isNot(contains(DeckRole.removal)));
    });

    test('a counterspell reads as a counter, not as removal', () {
      final roles = rolesOf(
        mtg('Counterspell', type: 'Instant', text: 'Counter target spell.'),
      );
      expect(roles, contains(DeckRole.counter));
      expect(roles, isNot(contains(DeckRole.removal)));
    });

    test('keywords that keep a card alive read as protection', () {
      expect(
        rolesOf(
          mtg(
            'Boots',
            type: 'Artifact',
            text: 'Equipped creature has hexproof.',
          ),
        ),
        contains(DeckRole.protection),
      );
    });

    test('a land fetch is ramp, a card fetch is a tutor', () {
      final ramp = rolesOf(
        mtg(
          'Rampant Growth',
          type: 'Sorcery',
          text: 'Search your library for a basic land card.',
        ),
      );
      expect(ramp, contains(DeckRole.ramp));
      expect(ramp, isNot(contains(DeckRole.tutor)));

      final tutor = rolesOf(
        mtg(
          'Demonic Tutor',
          type: 'Sorcery',
          text: 'Search your library for a card.',
        ),
      );
      expect(tutor, contains(DeckRole.tutor));
      expect(tutor, isNot(contains(DeckRole.ramp)));
    });

    test('a vanilla card fills no role at all', () {
      expect(rolesOf(mtg('Grizzly Bears', text: null)), isEmpty);
    });

    test('the back face counts as well as the front', () {
      final roles = rolesOf(
        mtg('Flipper', text: null, faceText: <String>['Draw a card.']),
      );
      expect(roles, contains(DeckRole.draw));
    });

    test('another game gets its own wording', () {
      final ygo = mtg(
        'Dark Hole',
        game: CardGame.yugioh,
        type: 'Normal Spell',
        text: 'Destroy all monsters on the field.',
      );
      expect(rolesOf(ygo), contains(DeckRole.removal));
      expect(hasRoleRules(CardGame.yugioh), isTrue);
    });
  });

  group('reading a deck', () {
    test('the curve buckets by mana value with seven and up together', () {
      final a = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(mtg('One', cmc: 1)),
          line(mtg('Two', cmc: 2), quantity: 3),
          line(mtg('Seven', cmc: 7)),
          line(mtg('Ten', cmc: 10)),
        ]),
      );
      expect(a.curve[1], 1);
      expect(a.curve[2], 3);
      expect(a.curve[7], 2);
      expect(a.costed, 6);
      expect(a.averageCost, closeTo((1 + 2 * 3 + 7 + 10) / 6, 0.001));
    });

    test('lands are counted from the type line and kept out of the rest', () {
      final a = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(mtg('Forest', type: 'Basic Land — Forest'), quantity: 10),
          line(mtg('Bear', cmc: 2, text: 'Vanilla.'), quantity: 5),
        ]),
      );
      expect(a.lands, 10);
      expect(a.size, 15);
      expect(a.nonLandSize, 5);
      expect(a.curve[2], 5);
      expect(a.types.first.key, 'Land');
    });

    test('role targets scale with the cards that are not lands', () {
      final a = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(mtg('Forest', type: 'Basic Land — Forest'), quantity: 50),
          line(mtg('Bear', cmc: 2, text: 'Vanilla.'), quantity: 50),
        ]),
      );
      expect(a.roleTargets[DeckRole.removal], 4);
      expect(a.roleTargets[DeckRole.draw], 5);
      expect(a.deficit(DeckRole.removal), 4);
      expect(a.thinRoles, contains(DeckRole.removal));
    });

    test('a deck whose cards say nothing is not read rather than misread', () {
      final silent = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(mtg('Bear', cmc: 2), quantity: 20),
        ]),
      );
      expect(silent.rolesRead, isFalse);
      expect(
        silent.advice.where((DeckIssue i) => i.title.contains('Removal')),
        isEmpty,
      );
    });

    test('a deck with words on its cards is read', () {
      final talking = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(mtg('Bear', cmc: 2, text: 'Trample.'), quantity: 20),
        ]),
      );
      expect(talking.rolesRead, isTrue);
    });

    test('too few lands is called out', () {
      final entries = <DeckEntry>[
        line(mtg('Forest', type: 'Basic Land — Forest'), quantity: 10),
        for (int i = 0; i < 90; i++)
          line(mtg('Spell $i', type: 'Instant', cmc: 2, text: 'Draw a card.')),
      ];
      final a = analyseDeck(deck('mtg-casual', entries));
      expect(a.lands, 10);
      expect(
        a.advice.any(
          (DeckIssue i) =>
              i.title.contains('lands') && i.level == DeckIssueLevel.warning,
        ),
        isTrue,
      );
    });

    test('a deck too small to have a shape gets no advice', () {
      final a = analyseDeck(
        deck('commander', <DeckEntry>[
          line(mtg('Bear', cmc: 2, text: 'Trample.')),
        ]),
      );
      expect(a.advice, isEmpty);
    });

    test('the sideboard is not part of the deck', () {
      final a = analyseDeck(
        deck('standard', <DeckEntry>[
          line(mtg('Bear', cmc: 2, text: 'Trample.'), quantity: 4),
          line(
            mtg('Side', cmc: 5, text: 'Draw a card.'),
            quantity: 15,
            board: DeckBoard.side,
          ),
        ]),
      );
      expect(a.size, 4);
      expect(a.costed, 4);
      expect(a.roleCounts[DeckRole.draw], isNull);
    });

    test('tallies come back biggest first and stable between runs', () {
      final a = analyseDeck(
        deck('mtg-casual', <DeckEntry>[
          line(
            mtg('A', type: 'Creature — Goblin', text: 'Trample.'),
            quantity: 2,
          ),
          line(mtg('B', type: 'Creature — Elf', text: 'Trample.'), quantity: 7),
        ]),
      );
      expect(a.subtypes.first.key, 'Elf');
      expect(a.subtypes.first.value, 7);
      expect(a.types.first.key, 'Creature');
      expect(a.types.first.value, 9);
    });

    test('supertypes are not types', () {
      final a = analyseDeck(
        deck('commander', <DeckEntry>[
          line(
            mtg('Boss', type: 'Legendary Creature — Goblin', text: 'Trample.'),
            board: DeckBoard.commander,
          ),
        ]),
      );
      expect(
        a.types.map((MapEntry<String, int> e) => e.key),
        isNot(contains('Legendary')),
      );
      expect(a.commanderTypes, contains('Goblin'));
    });
  });

  group('suggesting from the collection', () {
    final commander = mtg(
      'Krenko',
      type: 'Legendary Creature — Goblin',
      text: 'Other Goblins get +1/+1.',
      cmc: 4,
      identity: <String>['R'],
    );

    /// A commander deck with a commander and nothing else worth speaking of.
    DeckContents krenko(List<DeckEntry> extra) => commanderDeck(<DeckEntry>[
      line(commander, board: DeckBoard.commander),
      ...extra,
    ]);

    List<DeckSuggestion> suggest(
      DeckContents contents,
      List<TcgCard> owned, {
      Map<String, int> quantities = const <String, int>{},
      Set<String> banned = const <String>{},
    }) => suggestForDeck(
      contents: contents,
      ownedCards: <String, TcgCard>{for (final TcgCard c in owned) c.id: c},
      ownedQuantities: quantities.isEmpty
          ? <String, int>{for (final TcgCard c in owned) c.id: 1}
          : quantities,
      bannedNames: banned,
    );

    test('a card outside the commander identity is never suggested', () {
      final blue = mtg(
        'Counterspell',
        type: 'Instant',
        text: 'Counter target spell.',
        identity: <String>['U'],
      );
      final red = mtg(
        'Shock',
        type: 'Instant',
        text: 'Deals 2 damage to target creature.',
        identity: <String>['R'],
      );
      final out = suggest(krenko(<DeckEntry>[]), <TcgCard>[blue, red]);
      final names = out.map((DeckSuggestion s) => s.card.name).toList();
      expect(names, contains('Shock'));
      expect(names, isNot(contains('Counterspell')));
    });

    test('a banned card is never suggested', () {
      final rock = mtg(
        'Mox Ruby',
        type: 'Artifact',
        text: 'Add {R}.',
        identity: <String>['R'],
      );
      final out = suggest(
        krenko(<DeckEntry>[]),
        <TcgCard>[rock],
        banned: <String>{TcgCard.normaliseName('Mox Ruby')},
      );
      expect(out, isEmpty);
    });

    test('a card the collector does not own is not offered', () {
      final out = suggestForDeck(
        contents: krenko(<DeckEntry>[]),
        ownedCards: <String, TcgCard>{},
        ownedQuantities: <String, int>{},
      );
      expect(out, isEmpty);
    });

    test(
      'a singleton deck is not offered a second copy of what it already runs',
      () {
        final rock = mtg(
          'Sol Ring',
          type: 'Artifact',
          text: 'Add {2}.',
          identity: <String>[],
        );
        final out = suggest(
          krenko(<DeckEntry>[line(rock)]),
          <TcgCard>[rock],
          quantities: <String, int>{rock.id: 4},
        );
        expect(out, isEmpty);
      },
    );

    test('spare copies are capped by the format copy limit', () {
      final goblin = mtg(
        'Goblin Guide',
        type: 'Creature — Goblin',
        text: 'Haste.',
        cmc: 1,
        identity: <String>['R'],
      );
      final singleton = suggest(
        krenko(<DeckEntry>[]),
        <TcgCard>[goblin],
        quantities: <String, int>{goblin.id: 4},
      );
      expect(singleton.single.canAdd, 1);

      final standard = suggest(
        deck('standard', <DeckEntry>[line(commander)]),
        <TcgCard>[goblin],
        quantities: <String, int>{goblin.id: 4},
      );
      expect(standard.single.canAdd, 4);
    });

    test('what the deck is short of outranks what is merely popular', () {
      final removal = mtg(
        'Doom Blade',
        type: 'Instant',
        text: 'Destroy target creature.',
        cmc: 2,
        identity: <String>['R'],
        edhrec: 40000,
      );
      final popular = mtg(
        'Fancy Rock',
        type: 'Artifact',
        text: 'Vanilla.',
        cmc: 2,
        identity: <String>['R'],
        edhrec: 12,
      );
      final out = suggest(krenko(<DeckEntry>[]), <TcgCard>[removal, popular]);
      expect(out.first.card.name, 'Doom Blade');
      expect(
        out.first.reasons.any((String r) => r.contains('Removal')),
        isTrue,
      );
      expect(
        out.first.reasons.any((String r) => r.contains('EDHREC')),
        isFalse,
      );
    });

    test('a card on the deck tribe is favoured and says why', () {
      final goblin = mtg(
        'Goblin Chieftain',
        type: 'Creature — Goblin',
        text: 'Haste.',
        cmc: 3,
        identity: <String>['R'],
      );
      final elf = mtg(
        'Elf Lord',
        type: 'Creature — Elf',
        text: 'Haste.',
        cmc: 3,
        identity: <String>['R'],
      );
      final out = suggest(krenko(<DeckEntry>[]), <TcgCard>[goblin, elf]);
      expect(out.first.card.name, 'Goblin Chieftain');
      expect(
        out.first.reasons.any(
          (String r) => r.contains('Goblin') && r.contains('share the type'),
        ),
        isTrue,
      );
    });

    test('a card with no reasons still says it is legal and owned', () {
      final plain = mtg(
        'Grizzly Bears',
        type: 'Creature',
        text: 'Vanilla.',
        cmc: 2,
        identity: <String>['R'],
      );
      final out = suggest(krenko(<DeckEntry>[]), <TcgCard>[plain]);
      expect(out.single.reasons, isNotEmpty);
    });

    test('popularity is named when it is good enough to name', () {
      final star = mtg(
        'Cultivate',
        type: 'Sorcery',
        text: 'Search your library for a basic land.',
        cmc: 3,
        identity: <String>['R'],
        edhrec: 200,
      );
      final out = suggest(krenko(<DeckEntry>[]), <TcgCard>[star]);
      expect(out.single.reasons.any((String r) => r.contains('#200')), isTrue);
    });
  });
}
