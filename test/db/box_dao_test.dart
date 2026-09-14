import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/box_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/portfolio/box_ev.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the box composition table', () {
    late AppDatabase db;
    late BoxDao dao;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      dao = BoxDao(db.db);
    });

    tearDown(() async => db.close());

    test('a stated composition comes back whole', () async {
      await dao.save(
        CardGame.mtg,
        'blb',
        const BoxComposition(
          packs: 25,
          cardsPerPack: 16,
          slots: <BoxSlot>[
            BoxSlot(CardRarity.common, 300),
            BoxSlot(CardRarity.uncommon, 90),
            BoxSlot(CardRarity.mythic, 10),
          ],
        ),
      );

      final BoxComposition? saved = await dao.forSet(CardGame.mtg, 'blb');
      expect(saved, isNotNull);
      expect(saved!.packs, 25);
      expect(saved.cardsPerPack, 16);
      expect(saved.cards, 400);
      expect(saved.countOf(CardRarity.mythic), 10);
      expect(saved.isWhole, isTrue);
    });

    test('stating it again replaces it rather than adding a second', () async {
      await dao.save(CardGame.mtg, 'blb', const BoxComposition(packs: 30));
      await dao.save(CardGame.mtg, 'blb', const BoxComposition(packs: 36));

      expect((await dao.forSet(CardGame.mtg, 'blb'))!.packs, 36);
      expect(await dao.count(CardGame.mtg), 1);
    });

    test(
      'a set nobody has described answers nothing, not an empty box',
      () async {
        expect(await dao.forSet(CardGame.mtg, 'unstated'), isNull);
        expect((await dao.allForGame(CardGame.mtg)), isEmpty);
      },
    );

    test('clearing a composition forgets it', () async {
      await dao.save(CardGame.mtg, 'blb', const BoxComposition(packs: 30));
      await dao.clear(CardGame.mtg, 'blb');
      expect(await dao.forSet(CardGame.mtg, 'blb'), isNull);
    });

    test(
      'an empty composition clears rather than stores a blank row',
      () async {
        await dao.save(CardGame.mtg, 'blb', const BoxComposition(packs: 30));
        await dao.save(CardGame.mtg, 'blb', BoxComposition.none);

        expect(await dao.forSet(CardGame.mtg, 'blb'), isNull);
        expect(await dao.count(CardGame.mtg), 0);
      },
    );

    test(
      'one set does not answer for another, in the same game or across',
      () async {
        await dao.save(CardGame.mtg, 'blb', const BoxComposition(packs: 30));
        await dao.save(CardGame.gundam, 'blb', const BoxComposition(packs: 12));

        expect((await dao.forSet(CardGame.mtg, 'blb'))!.packs, 30);
        expect((await dao.forSet(CardGame.gundam, 'blb'))!.packs, 12);
        expect(await dao.forSet(CardGame.pokemon, 'blb'), isNull);

        final Map<String, BoxComposition> gundam = await dao.allForGame(
          CardGame.gundam,
        );
        expect(gundam.keys, <String>['blb']);
        expect(gundam['blb']!.packs, 12);
      },
    );

    test('a stored row with unreadable slots is still a size', () async {
      // Not a shape the app writes, but a row a hand-edited backup could hold:
      // the size is what the box is valued from, so it survives bad JSON.
      await db.db.insert('box_compositions', <String, Object?>{
        'game': 'mtg',
        'set_code': 'blb',
        'packs': 30,
        'cards_per_pack': 14,
        'slots': 'not json at all',
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      final BoxComposition saved = (await dao.forSet(CardGame.mtg, 'blb'))!;
      expect(saved.packs, 30);
      expect(saved.cardsPerPack, 14);
      expect(saved.slots, isEmpty);
    });

    test('the composition table is what the v12 upgrade creates', () async {
      // The upgrade path runs on a phone that already has a collection, so its
      // DDL is checked on its own rather than only as part of a fresh schema.
      final raw = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await AppDatabase.createBoxCompositions(raw);

      final tables = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        <Object?>['box_compositions'],
      );
      expect(tables.length, 1);

      await raw.insert('box_compositions', <String, Object?>{
        'game': 'mtg',
        'set_code': 'blb',
        'packs': 30,
        'cards_per_pack': 0,
        'slots': '[]',
        'updated_at': 0,
      });
      await expectLater(
        raw.insert('box_compositions', <String, Object?>{
          'game': 'mtg',
          'set_code': 'blb',
          'packs': 36,
          'cards_per_pack': 0,
          'slots': '[]',
          'updated_at': 0,
        }),
        throwsA(isA<DatabaseException>()),
      );
      await raw.close();
    });
  });
}
