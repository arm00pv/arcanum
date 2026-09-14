// Merging two devices' copies into one collection.
//
//   flutter test test/sync/merge_test.dart
//
// The promise this file pins down is a negative one: a merge never removes
// anything, never lowers a count and never overwrites what the collector paid.
// A test that only checked the additions would let a regression delete a
// collection quietly.

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/backup/backup_archive.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/domain/sync/merge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// One card holding, as a backup stores it.
Map<String, Object?> entry({
  required String cardId,
  int quantity = 1,
  String finish = 'nonfoil',
  String binder = 'Binder A',
  double? paid,
  int forTrade = 0,
  String game = 'mtg',
}) => <String, Object?>{
  'game': game,
  'card_id': cardId,
  'finish': finish,
  'condition': 'near_mint',
  'language': 'en',
  'quantity': quantity,
  'purchase_price': paid,
  'binder': binder,
  'for_trade': forTrade,
  'created_at': 1755000000000,
  'updated_at': 1755000000000,
};

BackupArchive archiveOf({
  List<Map<String, Object?>> entries = const <Map<String, Object?>>[],
  List<Map<String, Object?>> sealed = const <Map<String, Object?>>[],
  List<Map<String, Object?>> wants = const <Map<String, Object?>>[],
  List<Map<String, Object?>> history = const <Map<String, Object?>>[],
  Map<String, List<Object?>> index = const <String, List<Object?>>{},
  String app = '1.16.0',
}) => BackupArchive(
  created: DateTime.utc(2026, 9, 14, 12),
  appVersion: app,
  tables: <String, List<Map<String, Object?>>>{
    'collection_entries': entries,
    'sealed_products': sealed,
    'wanted_cards': wants,
    'price_history': history,
  },
  settings: const <String, Object?>{},
  cardIndex: index,
);

Future<BackupService> serviceOver(AppDatabase db) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await AppSettings.load();
  return BackupService(database: db, settings: settings);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('what a plan says before anything happens', () {
    test('counts what is new, what is higher and what already agrees', () {
      final local = archiveOf(
        entries: <Map<String, Object?>>[
          entry(cardId: 'card-1', quantity: 2),
          entry(cardId: 'card-2', quantity: 5),
        ],
      );
      final remote = archiveOf(
        entries: <Map<String, Object?>>[
          entry(cardId: 'card-1', quantity: 2),
          entry(cardId: 'card-2', quantity: 3),
          entry(cardId: 'card-3', quantity: 1),
        ],
        index: <String, List<Object?>>{
          'card-3': <Object?>['Revel in Riches', 'xln', '117'],
        },
      );

      final MergePlan plan = planMerge(local, remote);
      expect(plan.addedRows, 1);
      expect(plan.raisedRows, 0);
      expect(plan.unchangedRows, 2);
      expect(plan.nothingToDo, isFalse);
      expect(plan.headline, contains('1 new'));
      // The plan names what it is about to add, using the other device's index,
      // so a collector can read it before agreeing even without the set here.
      expect(plan.changes.single.label, contains('Revel in Riches'));
      expect(plan.changes.single.label, contains('XLN'));
    });

    test('a copy with less on it changes nothing', () {
      final local = archiveOf(
        entries: <Map<String, Object?>>[entry(cardId: 'card-1', quantity: 4)],
      );
      final remote = archiveOf(
        entries: <Map<String, Object?>>[entry(cardId: 'card-1', quantity: 1)],
      );
      final MergePlan plan = planMerge(local, remote);
      expect(plan.nothingToDo, isTrue);
      expect(plan.headline, 'Both devices already agree');
      expect(plan.changes, isEmpty);
    });

    test('an empty archive is not a change', () {
      final plan = planMerge(archiveOf(), archiveOf());
      expect(plan.remoteRows, 0);
      expect(plan.headline, 'The other device has nothing to add');
      expect(plan.nothingToDo, isTrue);
    });

    test('price points are counted apart from holdings', () {
      final local = archiveOf(
        history: <Map<String, Object?>>[
          <String, Object?>{
            'game': 'mtg',
            'card_id': 'card-1',
            'finish': 'nonfoil',
            'date': '2026-09-13',
            'price': 20.0,
            'source': 'snapshot',
          },
        ],
      );
      final remote = archiveOf(
        history: <Map<String, Object?>>[
          <String, Object?>{
            'game': 'mtg',
            'card_id': 'card-1',
            'finish': 'nonfoil',
            'date': '2026-09-13',
            'price': 20.0,
            'source': 'snapshot',
          },
          <String, Object?>{
            'game': 'mtg',
            'card_id': 'card-1',
            'finish': 'nonfoil',
            'date': '2026-09-14',
            'price': 21.0,
            'source': 'snapshot',
          },
        ],
      );
      final MergePlan plan = planMerge(local, remote);
      expect(plan.freshPricePoints, 1);
      expect(
        plan.nothingToDo,
        isTrue,
        reason: 'a price point is not a holding',
      );
    });

    test('the plan says what it will not do', () {
      final MergePlan plan = planMerge(archiveOf(), archiveOf());
      expect(plan.notes.any((String n) => n.contains('never removes')), isTrue);
      expect(plan.notes.any((String n) => n.contains('Decks')), isTrue);
    });
  });

  group('what a merge actually does', () {
    late AppDatabase db;
    late BackupService service;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      service = await serviceOver(db);
    });

    tearDown(() async => db.close());

    test('adds what is missing and never removes what is here', () async {
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-1', quantity: 2, paid: 12.5),
      );
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-9', quantity: 1, binder: 'Box 9'),
      );

      final MergeReport report = await service.merge(
        archiveOf(
          entries: <Map<String, Object?>>[
            entry(cardId: 'card-1', quantity: 2),
            entry(cardId: 'card-2', quantity: 3, paid: 4.0),
          ],
        ),
      );

      expect(report.addedRows, 1);
      expect(report.raisedRows, 0);
      final List<Map<String, Object?>> rows = await db.db.query(
        'collection_entries',
        orderBy: 'card_id',
      );
      expect(rows.map((Map<String, Object?> r) => r['card_id']), <String>[
        'card-1',
        'card-2',
        'card-9',
      ]);
      expect(rows.first['quantity'], 2);
      expect(report.nothingChanged, isFalse);
      expect(report.summary, contains('Nothing was removed'));
    });

    test('raises a count and keeps what this phone paid', () async {
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-1', quantity: 2, paid: 12.5, binder: 'Binder A'),
      );

      final MergeReport report = await service.merge(
        archiveOf(
          entries: <Map<String, Object?>>[
            entry(cardId: 'card-1', quantity: 5, paid: 99.0),
          ],
        ),
      );

      expect(report.raisedRows, 1);
      final Map<String, Object?> row = (await db.db.query('collection_entries'))
          .single;
      expect(row['quantity'], 5, reason: 'the higher count wins');
      expect(row['purchase_price'], 12.5, reason: 'what was paid is kept');
      expect(row['binder'], 'Binder A', reason: 'where it is filed is kept');
    });

    test('takes a purchase price this phone never had', () async {
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-1', quantity: 2),
      );
      await service.merge(
        archiveOf(
          entries: <Map<String, Object?>>[
            entry(cardId: 'card-1', quantity: 3, paid: 7.25),
          ],
        ),
      );
      final Map<String, Object?> row = (await db.db.query('collection_entries'))
          .single;
      expect(row['quantity'], 3);
      expect(row['purchase_price'], 7.25);
    });

    test('a different binder is a different holding, not a bigger one', () async {
      // The unique index says so and the merge follows it: the same card filed
      // in two places is two stacks, so it is added rather than used to raise a
      // count that already exists.
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-1', quantity: 2, binder: 'Binder A'),
      );
      final MergeReport report = await service.merge(
        archiveOf(
          entries: <Map<String, Object?>>[
            entry(cardId: 'card-1', quantity: 3, binder: 'Box 7'),
          ],
        ),
      );
      expect(report.addedRows, 1);
      expect(report.raisedRows, 0);
      final List<Map<String, Object?>> rows = await db.db.query(
        'collection_entries',
      );
      expect(rows.length, 2);
      expect(
        rows.map((Map<String, Object?> r) => r['quantity']),
        containsAll(<int>[2, 3]),
      );
    });

    test('a lower count on the other device lowers nothing', () async {
      await db.db.insert(
        'collection_entries',
        entry(cardId: 'card-1', quantity: 6),
      );
      final MergeReport report = await service.merge(
        archiveOf(
          entries: <Map<String, Object?>>[entry(cardId: 'card-1', quantity: 1)],
        ),
      );
      expect(report.raisedRows, 0);
      expect(report.nothingChanged, isTrue);
      final Map<String, Object?> row = (await db.db.query('collection_entries'))
          .single;
      expect(row['quantity'], 6);
    });

    test('keeps the price history of both devices', () async {
      await db.db.insert('price_history', <String, Object?>{
        'card_id': 'card-1',
        'game': 'mtg',
        'finish': 'nonfoil',
        'date': '2026-09-13',
        'price': 20.0,
        'source': 'snapshot',
      });
      final MergeReport report = await service.merge(
        archiveOf(
          history: <Map<String, Object?>>[
            <String, Object?>{
              'card_id': 'card-1',
              'game': 'mtg',
              'finish': 'nonfoil',
              'date': '2026-09-13',
              'price': 19.0,
              'source': 'snapshot',
            },
            <String, Object?>{
              'card_id': 'card-1',
              'game': 'mtg',
              'finish': 'nonfoil',
              'date': '2026-09-14',
              'price': 21.0,
              'source': 'snapshot',
            },
          ],
        ),
      );

      expect(report.pricePoints, 1);
      final List<Map<String, Object?>> rows = await db.db.query(
        'price_history',
        orderBy: 'date',
      );
      expect(rows.length, 2);
      expect(
        rows.first['price'],
        20.0,
        reason: 'a day this phone already recorded is left as it was',
      );
      expect(rows.last['price'], 21.0);
    });

    test('merges the sealed shelf by product, not by row', () async {
      await db.db.insert('sealed_products', <String, Object?>{
        'game': 'mtg',
        'set_code': 'BLB',
        'set_name': 'Bloomburrow',
        'name': 'Bloomburrow Play Booster Display',
        'category': 'box',
        'quantity': 1,
        'unit_cost': 150.0,
        'location': 'Top shelf',
        'product_id': '541235',
        'created_at': 1755000000000,
      });

      final MergeReport report = await service.merge(
        archiveOf(
          sealed: <Map<String, Object?>>[
            <String, Object?>{
              'game': 'mtg',
              'set_code': 'BLB',
              'set_name': 'Bloomburrow',
              'name': 'Bloomburrow Play Booster Display',
              'category': 'box',
              'quantity': 3,
              'unit_cost': 140.0,
              'location': 'Cupboard',
              'product_id': '541235',
              'created_at': 1755000000000,
            },
            <String, Object?>{
              'game': 'mtg',
              'set_code': 'BLB',
              'set_name': 'Bloomburrow',
              'name': 'Bloomburrow Bundle',
              'category': 'bundle',
              'quantity': 2,
              'unit_cost': 40.0,
              'location': '',
              'product_id': '',
              'created_at': 1755000000000,
            },
          ],
        ),
      );

      expect(report.addedRows, 1, reason: 'the bundle is new');
      expect(
        report.raisedRows,
        1,
        reason: 'the display went from one to three',
      );
      final List<Map<String, Object?>> rows = await db.db.query(
        'sealed_products',
        orderBy: 'name',
      );
      expect(rows.length, 2);
      final Map<String, Object?> display = rows.firstWhere(
        (Map<String, Object?> r) => r['product_id'] == '541235',
      );
      expect(display['quantity'], 3);
      expect(display['unit_cost'], 150.0);
      expect(display['location'], 'Top shelf');
    });

    test(
      'takes the wants it does not have and leaves the ones it does',
      () async {
        await db.db.insert('wanted_cards', <String, Object?>{
          'game': 'mtg',
          'card_id': 'card-1',
          'created_at': 1755000000000,
        });
        final MergeReport report = await service.merge(
          archiveOf(
            wants: <Map<String, Object?>>[
              <String, Object?>{
                'game': 'mtg',
                'card_id': 'card-1',
                'created_at': 1755000000000,
              },
              <String, Object?>{
                'game': 'mtg',
                'card_id': 'card-2',
                'created_at': 1755000000000,
              },
            ],
          ),
        );
        expect(report.addedRows, 1);
        final List<Map<String, Object?>> rows = await db.db.query(
          'wanted_cards',
        );
        expect(rows.length, 2);
      },
    );

    test('the same merge twice changes nothing the second time', () async {
      final BackupArchive remote = archiveOf(
        entries: <Map<String, Object?>>[
          entry(cardId: 'card-1', quantity: 3),
          entry(cardId: 'card-2', quantity: 1),
        ],
      );
      await service.merge(remote);
      final MergeReport again = await service.merge(remote);
      expect(again.nothingChanged, isTrue);
      expect(again.summary, contains('already agree'));
    });
  });
}
