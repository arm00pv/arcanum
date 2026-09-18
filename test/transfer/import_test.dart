import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/db/collection_dao.dart';
import 'package:arcanum/data/db/lots_dao.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/data/transfer/collection_transfer.dart';
import 'package:arcanum/data/transfer/import_service.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// A catalogue that answers from memory, so import matching is tested without a
/// network and deterministically.
class _FakeCatalog extends CardCatalog {
  _FakeCatalog(this.game, this.cards);

  @override
  final CardGame game;

  final List<TcgCard> cards;

  @override
  String get sourceName => 'test';

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async => const [];

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async => cards.where((c) => c.setCode == setCode.toLowerCase()).toList();

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    for (final c in cards) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final q = query.toLowerCase();
    return cards
        .where((c) => c.name.toLowerCase().contains(q))
        .take(limit)
        .toList();
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      cards.where((c) => c.oracleId == groupId).toList();

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async => cards;
}

TcgCard _mtg(
  String id,
  String name,
  String setCode,
  String number, {
  int year = 1993,
  int month = 8,
  int day = 5,
}) => TcgCard(
  game: CardGame.mtg,
  id: id,
  setCode: setCode,
  setName: setCode.toUpperCase(),
  name: name,
  collectorNumber: number,
  rarity: 'rare',
  releasedAt: DateTime.utc(year, month, day),
  prices: TcgPrices(byFinish: {CardFinish.nonfoil.code: 100.0}),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CollectionRepository collection;
  late CollectionImporter importer;
  late CollectionDao entries;

  final lea = <TcgCard>[
    _mtg('lea-161', 'Lightning Bolt', 'lea', '161'),
    _mtg('lea-232', 'Black Lotus', 'lea', '232'),
  ];
  final m19 = <TcgCard>[
    _mtg(
      'm19-150',
      'Lightning Bolt',
      'm19',
      '150',
      year: 2018,
      month: 7,
      day: 13,
    ),
    _mtg(
      'm19-217',
      'Nicol Bolas, the Ravager',
      'm19',
      '217',
      year: 2018,
      month: 7,
      day: 13,
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    db = await AppDatabase.openInMemory();
    final catalogDao = CatalogDao(db.db);
    entries = CollectionDao(db.db);
    final settings = await AppSettings.load();
    final catalogs = CatalogRepository(
      catalogs: <CardGame, CardCatalog>{
        CardGame.mtg: _FakeCatalog(CardGame.mtg, [...lea, ...m19]),
      },
      dao: catalogDao,
    );
    collection = CollectionRepository(
      game: CardGame.mtg,
      collectionDao: entries,
      lotsDao: LotsDao(db.db),
      catalogDao: catalogDao,
      historyDao: HistoryDao(db.db),
      history: PriceHistoryService(dao: HistoryDao(db.db), settings: settings),
      catalogs: catalogs,
      settings: settings,
    );
    importer = CollectionImporter(collection: collection, catalogs: catalogs);
  });

  tearDown(() async => db.close());

  Future<ImportPlan> planFor(String csvText) async {
    final parsed = CollectionCsvReader.parse(csvText);
    return importer.plan(parsed);
  }

  group('normaliseCollector', () {
    test('strips leading zeros from purely numeric numbers', () {
      expect(CollectionImporter.normaliseCollector('0161'), '161');
      expect(CollectionImporter.normaliseCollector('161'), '161');
      expect(CollectionImporter.normaliseCollector(' 161 '), '161');
      expect(CollectionImporter.normaliseCollector('000'), '0');
    });

    test('keeps zeros that are part of a suffixed or prefixed number', () {
      expect(CollectionImporter.normaliseCollector('TG01'), 'tg01');
      expect(CollectionImporter.normaliseCollector('H01'), 'h01');
      expect(CollectionImporter.normaliseCollector('161a'), '161a');
    });
  });

  group('matching', () {
    test('matches on set code and collector number', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n1,Black Lotus,lea,232\n',
      );
      expect(plan.problems, isEmpty);
      final row = plan.ready.single;
      expect(row.card.id, 'lea-232');
      expect(row.match, ImportMatch.bySetAndNumber);
    });

    test('tolerates zero-padded collector numbers', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n1,Black Lotus,lea,0232\n',
      );
      expect(plan.ready.single.card.id, 'lea-232');
      expect(plan.ready.single.match, ImportMatch.bySetAndNumber);
    });

    test('matches an unambiguous name when no set is given', () async {
      final plan = await planFor('Quantity,Name\n1,Black Lotus\n');
      expect(plan.ready.single.card.id, 'lea-232');
      expect(plan.ready.single.match, ImportMatch.byName);
      expect(plan.ready.single.match.needsReview, isFalse);
    });

    test(
      'picks the newest printing of an ambiguous name and flags it',
      () async {
        final plan = await planFor('Quantity,Name\n1,Lightning Bolt\n');
        final row = plan.ready.single;
        expect(row.match, ImportMatch.byNameNewest);
        expect(row.match.needsReview, isTrue);
        expect(row.card.id, 'm19-150');
        expect(plan.needingReview, 1);
      },
    );

    test('falls back to the name when the set code is stale', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n1,Black Lotus,zzz,999\n',
      );
      final row = plan.ready.single;
      expect(row.card.id, 'lea-232');
      expect(row.match, ImportMatch.byName);
    });

    test('reports an unknown card rather than importing something wrong', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n1,Nonexistent Card,lea,999\n',
      );
      expect(plan.ready, isEmpty);
      expect(
        plan.problems.single.message,
        contains('no ${CardGame.mtg.label} printing matches'),
      );
    });

    test('still imports the rows it could match', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n'
        '1,Black Lotus,lea,232\n'
        '1,Nope,lea,999\n',
      );
      expect(plan.ready.length, 1);
      expect(plan.problems.length, 1);
    });

    test('reads a quoted name containing a comma', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n'
        '1,"Nicol Bolas, the Ravager",m19,217\n',
      );
      expect(plan.ready.single.card.id, 'm19-217');
    });
  });

  group('game vocabulary', () {
    test('replaces a finish the game does not have, and says so', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Foil\n'
        '1,Black Lotus,lea,232,reverseholo\n',
      );
      final row = plan.ready.single;
      expect(row.row.finish, CardFinish.nonfoil);
      expect(plan.problems.single.message, contains('does not exist in Magic'));
    });

    test('replaces a condition the game does not grade, and says so', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Condition\n'
        '1,Black Lotus,lea,232,DMG\n',
      );
      final row = plan.ready.single;
      // Damaged is a Pokémon grade; Magic uses Played instead.
      expect(row.row.condition, CardCondition.nearMint);
      expect(plan.problems.single.message, contains('is not used in Magic'));
    });
  });

  group('plan totals', () {
    test('sums cards, stacks and cost basis', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Purchase Price\n'
        '4,Black Lotus,lea,232,10.00\n'
        '1,Lightning Bolt,lea,161,\n',
      );
      expect(plan.totalCards, 5);
      expect(plan.creating, 2);
      expect(plan.merging, 0);
      expect(plan.knownCost, 40.0);
    });

    test('reports no cost when the file supplies none', () async {
      final plan = await planFor('Quantity,Name\n1,Black Lotus\n');
      expect(plan.knownCost, isNull);
    });
  });

  group('merge detection', () {
    test('recognises a stack that is already owned', () async {
      await collection.addCard(cardId: 'lea-232', quantity: 2);

      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n3,Black Lotus,lea,232\n',
      );
      final row = plan.ready.single;
      expect(row.mergesExisting, isTrue);
      expect(row.existingQuantity, 2);
      expect(plan.merging, 1);
      expect(plan.creating, 0);
    });

    test('a different finish is a new stack, not a merge', () async {
      await collection.addCard(cardId: 'lea-232', quantity: 2);

      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Foil\n3,Black Lotus,lea,232,foil\n',
      );
      final row = plan.ready.single;
      expect(row.row.finish, CardFinish.foil);
      expect(row.mergesExisting, isFalse);
    });

    test('counts repeated rows in one file as a single stack', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n'
        '2,Black Lotus,lea,232\n'
        '3,Black Lotus,lea,232\n',
      );
      // Two rows, one physical stack, five cards.
      expect(plan.totalCards, 5);
      expect(plan.creating, 1);
      expect(plan.merging, 1);
      expect(plan.ready.last.existingQuantity, 2);

      await importer.apply(plan);
      final stacks = await collection.entriesForCard('lea-232');
      expect(stacks.length, 1);
      expect(stacks.single.quantity, 5);
    });

    test('a different binder is a new stack, not a merge', () async {
      await collection.addCard(
        cardId: 'lea-232',
        quantity: 2,
        binder: 'Binder A',
      );

      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Binder\n3,Black Lotus,lea,232,Binder B\n',
      );
      expect(plan.ready.single.mergesExisting, isFalse);
    });
  });

  group('apply', () {
    test('writes the imported quantities', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n4,Black Lotus,lea,232\n',
      );
      final outcome = await importer.apply(plan);

      expect(outcome.ok, isTrue);
      expect(outcome.cardsAdded, 4);
      expect(outcome.stacksCreated, 1);
      expect(await collection.totalCardCount(), 4);
    });

    test('adds to an existing stack instead of duplicating it', () async {
      await collection.addCard(cardId: 'lea-232', quantity: 2);

      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n3,Black Lotus,lea,232\n',
      );
      final outcome = await importer.apply(plan);

      expect(outcome.stacksMerged, 1);
      expect(outcome.stacksCreated, 0);
      final stacks = await collection.entriesForCard('lea-232');
      expect(stacks.length, 1);
      expect(stacks.single.quantity, 5);
    });

    test('keeps the cost basis from the file', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Purchase Price\n'
        '2,Black Lotus,lea,232,7.50\n',
      );
      await importer.apply(plan);

      final stack = (await collection.entriesForCard('lea-232')).single;
      expect(stack.purchasePrice, 7.50);
      expect(stack.totalCost, 15.0);
    });

    test('records finish, condition, language and binder', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number,Foil,Condition,Language,Binder\n'
        '1,Black Lotus,lea,232,foil,LP,ja,Trade\n',
      );
      await importer.apply(plan);

      final stack = (await collection.entriesForCard('lea-232')).single;
      expect(stack.finish, CardFinish.foil);
      expect(stack.condition, CardCondition.lightPlayed);
      expect(stack.language, 'ja');
      expect(stack.binder, 'Trade');
    });

    test(
      'importing the same file twice accumulates, which is the honest result',
      () async {
        final csvText =
            'Quantity,Name,Set Code,Collector Number\n2,Black Lotus,lea,232\n';
        await importer.apply(await planFor(csvText));
        await importer.apply(await planFor(csvText));

        expect(await collection.totalCardCount(), 4);
      },
    );

    test('reports progress as it writes', () async {
      final plan = await planFor(
        'Quantity,Name,Set Code,Collector Number\n'
        '1,Black Lotus,lea,232\n'
        '1,Lightning Bolt,lea,161\n',
      );
      final seen = <int>[];
      await importer.apply(
        plan,
        onProgress: (done, total) {
          expect(total, 2);
          seen.add(done);
        },
      );
      expect(seen, [1, 2]);
    });
  });
}
