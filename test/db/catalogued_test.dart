import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A set as the provider's own list describes it.
TcgSet set(String code, {DateTime? releasedAt, int cardCount = 0}) => TcgSet(
  game: CardGame.gundam,
  id: code,
  code: code,
  name: code.toUpperCase(),
  setType: 'expansion',
  releasedAt: releasedAt,
  cardCount: cardCount,
);

TcgCard card(String id, String code) => TcgCard(
  game: CardGame.gundam,
  id: id,
  setCode: code,
  setName: code.toUpperCase(),
  name: 'Card $id',
  collectorNumber: id,
  rarity: 'Common',
);

/// A shop that was asked and had nothing to say.
///
/// The state a set is in between being announced and being published, which is
/// what Gundam's Blazing Fist (a group page with no products on it) is today.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late CatalogDao dao;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
  });

  tearDown(() async => db.close());

  group('what the shop was asked and what it said', () {
    test('a set nobody has looked up has not been asked about', () async {
      await dao.upsertSets(CardGame.gundam, <TcgSet>[set('gd07')]);
      expect(await dao.cataloguedAt(CardGame.gundam, 'gd07'), isNull);
      expect(await dao.isCatalogued(CardGame.gundam, 'gd07'), isFalse);
    });

    test(
      'a set the shop has no cards for is asked about and answered',
      () async {
        await dao.upsertSets(CardGame.gundam, <TcgSet>[set('gd07')]);
        await dao.markCatalogued(CardGame.gundam, 'gd07');

        expect(await dao.cataloguedAt(CardGame.gundam, 'gd07'), isNotNull);
        // True so that opening the set again does not re-download the same
        // nothing; the screen reads cataloguedAt to say which nothing it was.
        expect(await dao.isCatalogued(CardGame.gundam, 'gd07'), isTrue);
      },
    );

    test('an answer of nothing is asked again the next day', () async {
      await dao.upsertSets(CardGame.gundam, <TcgSet>[set('gd06')]);
      await dao.markCatalogued(CardGame.gundam, 'gd06');
      // Backdate the answer past the window, which is what a set that was
      // announced months ago and never populated looks like.
      await db.db.update(
        'sets',
        <String, Object?>{
          'catalogued_at': DateTime.now()
              .subtract(const Duration(days: 2))
              .millisecondsSinceEpoch,
        },
        where: 'game = ? AND code = ?',
        whereArgs: <Object?>[CardGame.gundam.id, 'gd06'],
      );

      expect(await dao.isCatalogued(CardGame.gundam, 'gd06'), isFalse);
    });

    test('a set with cards in it needs no asking', () async {
      await dao.upsertSets(CardGame.gundam, <TcgSet>[set('gd01')]);
      await dao.upsertCards(CardGame.gundam, <TcgCard>[
        card('GD01-001', 'gd01'),
      ]);

      expect(await dao.isCatalogued(CardGame.gundam, 'gd01'), isTrue);
      expect(await dao.cataloguedAt(CardGame.gundam, 'gd01'), isNull);
    });

    test(
      'a set with a published count is not complete until it is all there',
      () async {
        await dao.upsertSets(CardGame.gundam, <TcgSet>[
          set('gd05', cardCount: 148),
        ]);
        await dao.upsertCards(CardGame.gundam, <TcgCard>[
          card('GD05-001', 'gd05'),
        ]);
        expect(await dao.isCatalogued(CardGame.gundam, 'gd05'), isFalse);

        await dao.setCardCount(CardGame.gundam, 'gd05', 148);
        await dao.upsertCards(CardGame.gundam, <TcgCard>[
          for (var i = 1; i <= 148; i++) card('GD05-$i', 'gd05'),
        ]);
        expect(await dao.isCatalogued(CardGame.gundam, 'gd05'), isTrue);
      },
    );
  });
}
