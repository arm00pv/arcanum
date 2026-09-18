// Which catalogue answers, and what the app does when the shared one cannot.
//
//   flutter test test/catalog/routed_catalog_test.dart
//
// The property being tested is the one the whole migration turns on: the shared
// catalogue is an optimisation with a working fallback, never a dependency. So
// the cases that matter are the unhappy ones - no session, a server that
// throws, a server that answers nothing - and every one of them has to end with
// the app behaving exactly as it does today.
//
// Nothing here touches the network: both sides of the router are fakes, which
// is why CardCatalog is the seam it is.

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/data/catalog/lorcana_catalog.dart';
import 'package:arcanum/data/catalog/mtg_catalog.dart';
import 'package:arcanum/data/catalog/routed_catalog.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

TcgCard cardOf(String id) => TcgCard(
  game: CardGame.lorcana,
  id: id,
  setCode: '1',
  setName: 'The First Chapter',
  name: 'A card named $id',
  collectorNumber: '1',
  rarity: 'Common',
);

TcgSet setOf(String code) => TcgSet(
  game: CardGame.lorcana,
  id: code,
  code: code,
  name: 'A set named $code',
  setType: 'expansion',
);

/// A catalogue that answers from a script, or refuses to answer at all.
///
/// Both sides of the router are one of these, so a test can say which of them
/// was asked and how many times without either of them existing on a network.
class _ScriptedCatalog extends CardCatalog {
  _ScriptedCatalog({
    required this.label,
    this.fail = false,
    this.sets = const <TcgSet>[],
    this.cards = const <TcgCard>[],
    this.card,
    this.byId = const <String, TcgCard>{},
    this.byNumber = const <TcgCard>[],
  });

  final String label;
  final bool fail;
  final List<TcgSet> sets;
  final List<TcgCard> cards;
  final TcgCard? card;
  final Map<String, TcgCard> byId;
  final List<TcgCard> byNumber;

  /// How many requests reached this catalogue.
  int calls = 0;

  void _asked() {
    calls++;
    if (fail) {
      throw CatalogException('nothing from $label', source: label);
    }
  }

  @override
  CardGame get game => CardGame.lorcana;

  @override
  String get sourceName => label;

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    _asked();
    return sets;
  }

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    _asked();
    return cards;
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    _asked();
    return card;
  }

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    _asked();
    return <String, TcgCard>{
      for (final String id in ids)
        if (byId.containsKey(id)) id: byId[id]!,
    };
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    _asked();
    return cards;
  }

  @override
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) async {
    _asked();
    return byNumber;
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    _asked();
    return cards;
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    _asked();
    return this.cards;
  }
}

/// A catalogue that answers with everything a script holds, so one assertion
/// can tell whose answer arrived.
_ScriptedCatalog _answering(String label) => _ScriptedCatalog(
  label: label,
  sets: <TcgSet>[setOf(label)],
  cards: <TcgCard>[cardOf(label)],
  card: cardOf(label),
  byId: <String, TcgCard>{'x': cardOf(label)},
  byNumber: <TcgCard>[cardOf(label)],
);

/// A number query, as the repository parses one before it asks anybody.
CollectorQuery get _number => CollectorQuery.parse('001')!;

RoutedCatalog _routedTo(
  _ScriptedCatalog server,
  _ScriptedCatalog provider, {
  required bool Function() serverAllowed,
}) => RoutedCatalog(
  game: CardGame.lorcana,
  provider: provider,
  server: server,
  serverAllowed: serverAllowed,
);

void main() {
  group('which catalogue answers', () {
    test('the server, while it may be used', () async {
      final server = _answering('server');
      final provider = _answering('provider');
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      expect((await routed.fetchAllSets()).single.code, 'server');
      expect((await routed.fetchCardsInSet('1')).single.id, 'server');
      expect((await routed.fetchCardById('x'))!.id, 'server');
      expect((await routed.fetchCardsByIds(<String>['x']))['x']!.id, 'server');
      expect((await routed.search('elsa')).single.id, 'server');
      expect((await routed.fetchCardsByNumber(_number)).single.id, 'server');
      expect((await routed.fetchPrintingsOf('g')).single.id, 'server');
      expect(
        (await routed.refreshPrices(<TcgCard>[cardOf('x')])).single.id,
        'server',
      );

      expect(
        provider.calls,
        0,
        reason: 'the provider is not consulted when the server answered',
      );
    });

    test(
      'the provider, when there is nobody signed in to read a server',
      () async {
        final server = _answering('server');
        final provider = _answering('provider');
        final routed = _routedTo(server, provider, serverAllowed: () => false);

        expect((await routed.fetchAllSets()).single.code, 'provider');
        expect((await routed.fetchCardsInSet('1')).single.id, 'provider');
        expect((await routed.search('elsa')).single.id, 'provider');
        expect(
          (await routed.fetchCardsByNumber(_number)).single.id,
          'provider',
        );

        expect(
          server.calls,
          0,
          reason: 'signed out, the server is not asked at all',
        );
      },
    );

    test('is decided per call, not once when the app starts', () async {
      // Signing in happens long after the catalogue map is built, so a decision
      // taken at boot would answer "no server" for the rest of the session.
      var signedIn = false;
      final server = _ScriptedCatalog(
        label: 'server',
        sets: <TcgSet>[setOf('server')],
      );
      final provider = _ScriptedCatalog(
        label: 'provider',
        sets: <TcgSet>[setOf('provider')],
      );
      final routed = _routedTo(server, provider, serverAllowed: () => signedIn);

      expect((await routed.fetchAllSets()).single.code, 'provider');
      expect(server.calls, 0);

      signedIn = true;
      expect((await routed.fetchAllSets()).single.code, 'server');
      expect(server.calls, 1);
      expect(provider.calls, 1);
    });
  });

  group('a server that cannot answer', () {
    test('is answered by the provider rather than surfaced', () async {
      final server = _ScriptedCatalog(label: 'server', fail: true);
      final provider = _answering('provider');
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      // None of these may throw: an unreachable shared catalogue is exactly the
      // app as it was before this step existed.
      expect((await routed.fetchAllSets()).single.code, 'provider');
      expect((await routed.fetchCardsInSet('1')).single.id, 'provider');
      expect((await routed.fetchCardById('x'))!.id, 'provider');
      expect(
        (await routed.fetchCardsByIds(<String>['x']))['x']!.id,
        'provider',
      );
      expect((await routed.search('elsa')).single.id, 'provider');
      expect((await routed.fetchCardsByNumber(_number)).single.id, 'provider');
      expect((await routed.fetchPrintingsOf('g')).single.id, 'provider');
      expect(
        (await routed.refreshPrices(<TcgCard>[cardOf('x')])).single.id,
        'provider',
      );

      expect(server.calls, 8);
      expect(provider.calls, 8);
    });

    test('and so is one that answers with nothing', () async {
      // The quiet failure, which is the one that would be written into the
      // cache as though it were the truth: a game whose import never ran looks
      // exactly like a game with no sets.
      final server = _ScriptedCatalog(label: 'server');
      final provider = _answering('provider');
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      expect((await routed.fetchAllSets()).single.code, 'provider');
      expect((await routed.fetchCardsInSet('1')).single.id, 'provider');
      expect((await routed.fetchCardById('x'))!.id, 'provider');
      expect(
        (await routed.fetchCardsByIds(<String>['x']))['x']!.id,
        'provider',
      );
      expect((await routed.search('elsa')).single.id, 'provider');
      expect((await routed.fetchCardsByNumber(_number)).single.id, 'provider');
      expect((await routed.fetchPrintingsOf('g')).single.id, 'provider');
      expect(
        (await routed.refreshPrices(<TcgCard>[cardOf('x')])).single.id,
        'provider',
      );
    });
  });

  group('a collector number', () {
    test('goes to the server, and never to a provider', () async {
      // The case this exists for: a browser that has just signed in has the
      // collection and no catalogue, so the number is in neither the cache nor
      // the provider's vocabulary.
      final server = _ScriptedCatalog(
        label: 'server',
        byNumber: <TcgCard>[cardOf('from-the-catalogue')],
      );
      final provider = _ScriptedCatalog(
        label: 'provider',
        byNumber: <TcgCard>[cardOf('from-the-provider')],
      );
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      final cards = await routed.fetchCardsByNumber(_number);
      expect(cards.single.id, 'from-the-catalogue');
      expect(provider.calls, 0);
    });

    test('stays empty when the shared catalogue has nothing', () async {
      // Which is the phone's whole behaviour, unchanged: it has no router, and
      // a provider's number lookup is the empty default above.
      final server = _ScriptedCatalog(label: 'server');
      final provider = _ScriptedCatalog(label: 'provider');
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      expect(await routed.fetchCardsByNumber(_number), isEmpty);
    });
  });

  group('a batch of ids', () {
    test('the server mostly answered is kept', () async {
      // One id the catalogue has never heard of is not a reason to pay a
      // provider request per id in the batch.
      final server = _ScriptedCatalog(
        label: 'server',
        byId: <String, TcgCard>{'a': cardOf('a')},
      );
      final provider = _ScriptedCatalog(
        label: 'provider',
        byId: <String, TcgCard>{
          'a': cardOf('a'),
          'b': cardOf('b'),
          'c': cardOf('c'),
        },
      );
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      final cards = await routed.fetchCardsByIds(<String>['a', 'b', 'c']);
      expect(cards.keys, <String>['a']);
      expect(provider.calls, 0);
    });

    test('the server could answer nothing for goes to the provider', () async {
      final server = _ScriptedCatalog(label: 'server');
      final provider = _ScriptedCatalog(
        label: 'provider',
        byId: <String, TcgCard>{
          'a': cardOf('a'),
          'b': cardOf('b'),
          'c': cardOf('c'),
        },
      );
      final routed = _routedTo(server, provider, serverAllowed: () => true);

      final cards = await routed.fetchCardsByIds(<String>['a', 'b', 'c']);
      expect(cards.keys, <String>['a', 'b', 'c']);
      expect(provider.calls, 1);
    });
  });

  group('the switch', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('is off until it is asked for, and stays where it is put', () async {
      // Off by default is the whole rollback story: a browser that never
      // touches it never reads the shared catalogue, and one that turns it off
      // is back on the provider path without a release.
      final AppSettings settings = await AppSettings.load(
        secrets: MemorySecretStore(),
      );
      expect(settings.serverCatalog, isFalse);

      settings.serverCatalog = true;
      final AppSettings reopened = await AppSettings.load(
        secrets: MemorySecretStore(),
      );
      expect(reopened.serverCatalog, isTrue);
    });
  });

  group('the wiring', () {
    late AppSettings settings;
    late AppDatabase db;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      settings = await AppSettings.load(secrets: MemorySecretStore());
      db = await AppDatabase.openInMemory();
      addTearDown(db.close);
    });

    test('a build with no server is the five providers, untouched', () {
      // What a phone gets. There is no router in the map at all, so nothing
      // about the server path exists on that platform to go wrong.
      final Bootstrap bootstrap = Bootstrap.create(
        database: db,
        settings: settings,
      );
      expect(bootstrap.catalogs, hasLength(CardGame.values.length));
      for (final CardGame game in CardGame.values) {
        expect(
          bootstrap.catalogs[game],
          isNot(isA<RoutedCatalog>()),
          reason: 'no game is routed anywhere without a server',
        );
      }
      expect(bootstrap.catalogs[CardGame.lorcana], isA<LorcanaCatalog>());
    });

    test('a build with a server routes the one game that has one', () {
      final server = _ScriptedCatalog(label: 'server');
      final Bootstrap bootstrap = Bootstrap.create(
        database: db,
        settings: settings,
        sharedCatalog: () => server,
        sharedCatalogAllowed: () => settings.serverCatalog,
      );
      expect(bootstrap.catalogs[CardGame.lorcana], isA<RoutedCatalog>());
      expect(bootstrap.catalogs[CardGame.mtg], isA<MtgCatalog>());
      expect(bootstrap.catalogs, hasLength(CardGame.values.length));
    });
  });
}
