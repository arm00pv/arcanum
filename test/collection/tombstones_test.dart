import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/lots_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/portfolio/realised.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// What removing a card does to the collection on this device.
///
/// The sync's side of a removal is tested against a fake account; this is the
/// other half - that the row survives, that nothing the collector looks at can
/// see it, and that adding the card back puts it on that same row rather than
/// beside it. The unique index on the five values that identify a stack is what
/// makes the last of those necessary rather than merely tidy.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase app;
  late Database db;
  late CollectionDao dao;

  setUp(() async {
    app = await AppDatabase.openInMemory();
    db = app.db;
    dao = CollectionDao(db);
  });

  tearDown(() => db.close());

  Future<int> add({
    String cardId = 'lotus-1',
    int quantity = 4,
    double? price,
    String binder = '',
    String? notes,
  }) => dao.addOrMerge(
    game: CardGame.mtg,
    cardId: cardId,
    finish: CardFinish.nonfoil,
    condition: CardCondition.nearMint,
    language: 'en',
    quantity: quantity,
    purchasePrice: price,
    binder: binder,
    notes: notes,
  );

  /// The rows in the table itself, whatever the DAO chooses to show.
  Future<List<Map<String, Object?>>> rows() => db.query('collection_entries');

  test('a removed stack keeps its row and leaves every read', () async {
    final int id = await add(binder: 'Binder A');
    expect(await dao.all(CardGame.mtg), hasLength(1));

    await dao.delete(id);

    // Gone from everything the collector sees.
    expect(await dao.all(CardGame.mtg), isEmpty);
    expect(await dao.forCard(CardGame.mtg, 'lotus-1'), isEmpty);
    expect(await dao.forCards(CardGame.mtg, <String>['lotus-1']), isEmpty);
    expect(await dao.ownedCardIds(CardGame.mtg), isEmpty);
    expect(await dao.binders(CardGame.mtg), isEmpty);
    expect(await dao.totalCardCount(CardGame.mtg), 0);
    expect(await dao.uniqueCount(CardGame.mtg), 0);

    // Still there, which is what carries the removal to the account.
    final List<Map<String, Object?>> held = await rows();
    expect(held, hasLength(1));
    expect(held.single['id'], id);
    expect(held.single['deleted_at'], isNotNull);
    expect(
      held.single['binder'],
      'Binder A',
      reason: 'a removal stamps the row and changes nothing else',
    );
  });

  test('adding the card back revives the row it left behind', () async {
    final int id = await add(quantity: 4, price: 9.0, notes: 'signed');
    await dao.delete(id);

    final int again = await add(quantity: 2, price: 30.0);

    expect(
      again,
      id,
      reason: 'the row that was there is the row that comes back',
    );
    final List<Map<String, Object?>> held = await rows();
    expect(held, hasLength(1), reason: 'the unique index allows no second row');
    final CollectionEntry back = (await dao.all(CardGame.mtg)).single;
    expect(back.isDeleted, isFalse);
    expect(
      back.quantity,
      2,
      reason: 'the four copies that were deleted are not four copies they own',
    );
    expect(back.purchasePrice, 30.0);
    expect(
      back.notes,
      isNull,
      reason: 'what the deleted stack knew is not what this stack is',
    );
    expect(back.cardId, 'lotus-1');
  });

  test('a revived stack is not still up for trade', () async {
    final int id = await add();
    await dao.setForTrade(id, true);
    await dao.delete(id);

    final int again = await add();

    expect(again, id);
    expect((await dao.all(CardGame.mtg)).single.forTrade, isFalse);
  });

  test(
    'clearing a collection marks every stack, not just the ones it shows',
    () async {
      await add(cardId: 'lotus-1');
      await add(cardId: 'bolt-1', binder: 'Trade');

      await dao.clear(game: CardGame.mtg);

      expect(await dao.all(CardGame.mtg), isEmpty);
      final List<Map<String, Object?>> held = await rows();
      expect(held, hasLength(2));
      expect(
        held.every((Map<String, Object?> r) => r['deleted_at'] != null),
        isTrue,
        reason:
            'a cleared collection that still holds its rows is one the account '
            'cannot bring back',
      );
    },
  );

  test('clearing one game leaves the other game alone', () async {
    await add(cardId: 'lotus-1');
    await dao.addOrMerge(
      game: CardGame.pokemon,
      cardId: 'pika-1',
      finish: CardFinish.nonfoil,
      condition: CardCondition.nearMint,
      language: 'en',
      quantity: 1,
    );

    await dao.clear(game: CardGame.mtg);

    expect(await dao.all(CardGame.mtg), isEmpty);
    expect(await dao.all(CardGame.pokemon), hasLength(1));
  });

  group('a stack sold down to nothing', () {
    test('is marked rather than dropped, and undoing the sale brings it back', () async {
      final int id = await add(quantity: 3, price: 10.0);
      final CollectionEntry entry = (await dao.all(CardGame.mtg)).single;

      final CardSale sale = await LotsDao(db).recordSale(
        game: CardGame.mtg,
        entry: entry,
        quantity: 3,
        unitPrice: 20.0,
        soldOn: DateTime.now(),
      );

      expect(await dao.all(CardGame.mtg), isEmpty);
      final List<Map<String, Object?>> held = await rows();
      expect(held, hasLength(1));
      expect(held.single['id'], id);
      expect(
        held.single['deleted_at'],
        isNotNull,
        reason:
            'a sold-out stack is a stack that left the shelf, and the account '
            'has to be told or the next sync puts it back',
      );

      await LotsDao(db).undoSale(sale);

      final CollectionEntry back = (await dao.all(CardGame.mtg)).single;
      expect(back.id, id, reason: 'the copies come back where they were');
      expect(back.quantity, 3);
      expect(await rows(), hasLength(1));
    });

    test('cannot be sold from again while it is marked', () async {
      final int id = await add(quantity: 1, price: 10.0);
      final CollectionEntry entry = (await dao.all(CardGame.mtg)).single;
      await LotsDao(db).recordSale(
        game: CardGame.mtg,
        entry: entry,
        quantity: 1,
        unitPrice: 20.0,
        soldOn: DateTime.now(),
      );

      await expectLater(
        LotsDao(db).recordSale(
          game: CardGame.mtg,
          entry: entry.copyWith(id: id),
          quantity: 1,
          unitPrice: 20.0,
          soldOn: DateTime.now(),
        ),
        throwsArgumentError,
      );
    });
  });

  test('setting a quantity to zero removes the stack the same way', () async {
    final int id = await add();

    await dao.setQuantity(id, 0);

    expect(await dao.all(CardGame.mtg), isEmpty);
    expect((await rows()).single['deleted_at'], isNotNull);
  });

  test('a removed stack is not here to be edited', () async {
    final int id = await add(quantity: 4);
    await dao.delete(id);

    await dao.setQuantity(id, 9);
    await dao.decrement(id);

    expect(await dao.all(CardGame.mtg), isEmpty);
    expect((await rows()).single['quantity'], 4);
  });
}
