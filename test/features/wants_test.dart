// Tests for set completion and the wants list.
//
//   flutter test test/features/wants_test.dart
//
// Two questions that only look like one. Set completion asks what is missing
// from a binder; the wants list records what the collector has decided to go
// and buy. Both are counted in binder slots rather than printings, because
// Yu-Gi-Oh! lists one card several times over and a collector who owns one
// version of Blue-Eyes has not left two thirds of that slot empty.

import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/wanted_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/set_completion.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TcgCard card({
  required String id,
  required String name,
  required String number,
  CardGame game = CardGame.mtg,
  String setCode = 'tst',
  double? price,
}) => TcgCard(
  game: game,
  id: id,
  setCode: setCode,
  setName: 'Test Set',
  name: name,
  collectorNumber: number,
  rarity: 'common',
  prices: price == null
      ? TcgPrices.empty
      : TcgPrices(byFinish: <String, double?>{'nonfoil': price}),
);

Future<void> storeSet(AppDatabase db, CardGame game, String code) async {
  await db.db.insert('sets', <String, Object?>{
    'game': game.id,
    'code': code,
    'id': code,
    'name': 'Test Set',
    'set_type': 'core',
    'card_count': 0,
    'fetched_at': 1,
  });
}

Future<void> own(AppDatabase db, CardGame game, String cardId, int qty) async {
  await db.db.insert('collection_entries', <String, Object?>{
    'game': game.id,
    'card_id': cardId,
    'finish': 'nonfoil',
    'condition': 'near_mint',
    'language': 'en',
    'quantity': qty,
    'binder': '',
    'created_at': 1,
    'updated_at': 1,
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('set completion', () {
    test('counts a set in binder slots, not copies', () async {
      final db = await AppDatabase.openInMemory();
      await storeSet(db, CardGame.mtg, 'tst');
      await CatalogDao(db.db).upsertCards(CardGame.mtg, <TcgCard>[
        card(id: 'a', name: 'Alpha', number: '1'),
        card(id: 'b', name: 'Beta', number: '2'),
        card(id: 'c', name: 'Gamma', number: '3'),
      ]);
      await own(db, CardGame.mtg, 'a', 4);

      final done = (await CatalogDao(db.db)
          .setCompletion(CardGame.mtg))['tst']!;

      expect(done.total, 3);
      expect(done.owned, 1);
      expect(done.missing, 2);
      expect(done.fraction, closeTo(1 / 3, 0.0001));
      expect(done.complete, isFalse);
      await db.close();
    });

    test(
      'treats versions of one card at one number as a single slot',
      () async {
        // The Yu-Gi-Oh! case: LOB-000, LOB-E000 and LOB-EN000 are one binder
        // position, and owning one of them fills it.
        final db = await AppDatabase.openInMemory();
        await storeSet(db, CardGame.yugioh, 'lob');
        await CatalogDao(db.db).upsertCards(CardGame.yugioh, <TcgCard>[
          card(
            id: 'lob-000',
            name: 'Blue-Eyes White Dragon',
            number: '001',
            game: CardGame.yugioh,
            setCode: 'lob',
          ),
          card(
            id: 'lob-e000',
            name: 'Blue-Eyes White Dragon',
            number: '001',
            game: CardGame.yugioh,
            setCode: 'lob',
          ),
          card(
            id: 'lob-002',
            name: 'Dark Magician',
            number: '002',
            game: CardGame.yugioh,
            setCode: 'lob',
          ),
        ]);
        await own(db, CardGame.yugioh, 'lob-000', 1);

        final done = (await CatalogDao(db.db)
            .setCompletion(CardGame.yugioh))['lob']!;

        expect(done.total, 2, reason: 'two slots, not three printings');
        expect(done.owned, 1);
        expect(done.fraction, 0.5);
        await db.close();
      },
    );

    test('a set with nothing downloaded has no completion to report', () async {
      final db = await AppDatabase.openInMemory();
      await storeSet(db, CardGame.lorcana, 'coconut');

      final done = (await CatalogDao(db.db)
          .setCompletion(CardGame.lorcana))['coconut']!;

      expect(done.known, isFalse);
      expect(done.fraction, 0);
      expect(done.complete, isFalse, reason: 'empty is not finished');
      await db.close();
    });

    test('a holding is credited only to its own game', () async {
      final db = await AppDatabase.openInMemory();
      await storeSet(db, CardGame.mtg, 'tst');
      await storeSet(db, CardGame.pokemon, 'tst');
      await CatalogDao(db.db).upsertCards(CardGame.mtg, <TcgCard>[
        card(id: 'a', name: 'Alpha', number: '1'),
      ]);
      await own(db, CardGame.pokemon, 'a', 1);

      final mtg = (await CatalogDao(db.db).setCompletion(CardGame.mtg))['tst']!;
      expect(mtg.owned, 0);
      await db.close();
    });
  });

  group('the completion model', () {
    test('never reports a bar past its own end', () {
      const over = SetCompletion(
        code: 'x',
        name: 'X',
        owned: 12,
        total: 10,
        published: 10,
      );
      expect(over.fraction, 1);
      expect(over.complete, isTrue);
      expect(over.missing, 0);
    });

    test('reports a stated size the cache has not caught up with', () {
      const short = SetCompletion(
        code: 'x',
        name: 'X',
        owned: 0,
        total: 176,
        published: 180,
      );
      expect(short.short, isTrue);
      expect(short.started, isFalse);
    });
  });

  group('the wants list', () {
    test('adds, counts and removes, and is scoped to one game', () async {
      final db = await AppDatabase.openInMemory();
      final dao = WantedDao(db.db);

      await dao.add(CardGame.mtg, 'a');
      await dao.add(CardGame.mtg, 'b');
      await dao.add(CardGame.lorcana, 'a');

      expect(await dao.count(CardGame.mtg), 2);
      expect(await dao.count(CardGame.lorcana), 1);
      expect(await dao.ids(CardGame.mtg), containsAll(<String>['a', 'b']));

      await dao.remove(CardGame.mtg, 'a');
      expect(await dao.ids(CardGame.mtg), <String>['b']);
      // The other game's want of the same printing is untouched.
      expect(await dao.ids(CardGame.lorcana), <String>['a']);
      await db.close();
    });

    test('wanting a card twice does not move it up the list', () async {
      // The list is ordered by when a want was first made; a second press is
      // a no-op rather than a promotion.
      final db = await AppDatabase.openInMemory();
      final dao = WantedDao(db.db);

      await dao.add(CardGame.mtg, 'first');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await dao.add(CardGame.mtg, 'second');
      await dao.add(CardGame.mtg, 'first');

      expect(await dao.ids(CardGame.mtg), <String>['second', 'first']);
      await db.close();
    });

    test('adds a whole set at once and reports only the new ones', () async {
      final db = await AppDatabase.openInMemory();
      final dao = WantedDao(db.db);

      await dao.add(CardGame.mtg, 'b');
      final added = await dao.addAll(CardGame.mtg, <String>['a', 'b', 'c']);

      expect(added, 2);
      expect(await dao.count(CardGame.mtg), 3);
      await db.close();
    });

    test('clearing one game leaves the others alone', () async {
      final db = await AppDatabase.openInMemory();
      final dao = WantedDao(db.db);
      await dao.add(CardGame.mtg, 'a');
      await dao.add(CardGame.pokemon, 'a');

      await dao.clear(CardGame.mtg);

      expect(await dao.count(CardGame.mtg), 0);
      expect(await dao.count(CardGame.pokemon), 1);
      await db.close();
    });
  });
}
