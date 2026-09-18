// What free-text search does with a number, and with a name.
//
//   flutter test test/catalog/catalog_search_test.dart
//
// A number is an address: it is answered from the cache, and the provider is
// never asked, because the provider's search takes names and rules text and
// would answer "001" with every card that mentions it. A name is a word, and a
// word still goes to the provider when the cache comes up short.

import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/catalog_dao.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A provider that answers one card and counts what it was asked.
class _RecordingCatalog extends CardCatalog {
  _RecordingCatalog(this.game, this.answering);

  @override
  final CardGame game;

  /// The card a name search comes back with.
  final TcgCard answering;

  final List<String> queries = <String>[];

  @override
  String get sourceName => 'recording';

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    queries.add(query);
    return <TcgCard>[answering];
  }

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async => const <TcgSet>[];

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async => const <TcgCard>[];

  @override
  Future<TcgCard?> fetchCardById(String id) async => null;

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async => cards;
}

const TcgCard _yokomon = TcgCard(
  game: CardGame.digimon,
  id: 'bt26-001',
  setCode: 'BT26',
  setName: 'Timeless Bonds',
  name: 'Yokomon',
  collectorNumber: '001',
  rarity: 'common',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late AppDatabase db;
  late CatalogDao dao;
  late _RecordingCatalog catalog;
  late CatalogRepository catalogs;

  setUp(() async {
    db = await AppDatabase.openInMemory();
    dao = CatalogDao(db.db);
    catalog = _RecordingCatalog(CardGame.digimon, _yokomon);
    catalogs = CatalogRepository(
      catalogs: <CardGame, CardCatalog>{CardGame.digimon: catalog},
      dao: dao,
    );
    await dao.upsertSets(CardGame.digimon, <TcgSet>[
      TcgSet(
        game: CardGame.digimon,
        id: '24623',
        code: 'BT26',
        name: 'Timeless Bonds',
        setType: 'expansion',
        releasedAt: DateTime(2026, 9, 4),
      ),
    ]);
    await dao.upsertCards(CardGame.digimon, <TcgCard>[_yokomon]);
  });

  tearDown(() async => db.close());

  test(
    'a number is answered from the cache and never leaves the phone',
    () async {
      final hits = await catalogs.search(CardGame.digimon, 'BT-26-001');

      expect(hits.map((c) => c.name), <String>['Yokomon']);
      expect(catalog.queries, isEmpty, reason: 'no provider was asked');
    },
  );

  test('a bare number is answered the same way', () async {
    final hits = await catalogs.search(CardGame.digimon, '001');

    expect(hits.map((c) => c.name), <String>['Yokomon']);
    expect(catalog.queries, isEmpty);
  });

  test('a name still falls through to the provider', () async {
    final hits = await catalogs.search(CardGame.digimon, 'Yokomon');

    expect(hits.map((c) => c.name), <String>['Yokomon']);
    expect(catalog.queries, <String>['Yokomon']);
  });
}
