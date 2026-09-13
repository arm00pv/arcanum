// Which history sources a game is offered, and in what order.
//
//   flutter test test/history/price_history_service_test.dart
//
// The rule these pin is the one that changed when the companion started
// sampling every game: Yu-Gi-Oh! and Lorcana used to be handed an empty list
// because no source for them existed anywhere. They now have exactly one, the
// user's own infrastructure, and the app has to actually ask for it - a
// database full of daily samples that nobody requests is the same as no
// database at all.

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/data/history/price_history_service.dart';
import 'package:arcanum/data/history/price_history_source.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A service over an in-memory database and a given stored settings state.
Future<(PriceHistoryService, AppDatabase)> serviceWith(
  Map<String, Object> stored,
) async {
  SharedPreferences.setMockInitialValues(stored);
  final settings = await AppSettings.load();
  final db = await AppDatabase.openInMemory();
  return (PriceHistoryService(dao: HistoryDao(db.db), settings: settings), db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('with the companion configured', () {
    test('every game is offered it, including the two that had none', () async {
      final (service, db) = await serviceWith(<String, Object>{});

      for (final game in CardGame.values) {
        final ids = service.providersFor(game).map((p) => p.id).toList();
        expect(
          ids,
          contains(game == CardGame.mtg ? 'backfill' : 'companion'),
          reason: game.id,
        );
      }
      await db.close();
    });

    test('the companion is preferred over the game-specific fallbacks',
        () async {
      // Order is not cosmetic: the first source that answers with a usable
      // series is the one the chart is drawn from, and it is the one whose
      // points are stored alongside a source label.
      final (service, db) = await serviceWith(<String, Object>{});

      expect(service.providersFor(CardGame.mtg).first.id, 'backfill');
      // One sampler source serves every other game.
      expect(service.providersFor(CardGame.pokemon).first.id, 'companion');
      expect(service.providersFor(CardGame.lorcana).first.id, 'companion');
      expect(service.providersFor(CardGame.yugioh).first.id, 'companion');
      await db.close();
    });

    test('Magic asks its own endpoint and the rest ask the shared one',
        () async {
      // Magic's database is rebuilt from MTGJSON and is a different thing from
      // the daily samplers, so the two are configured separately and neither
      // may be sent the other's address.
      final (service, db) = await serviceWith(<String, Object>{
        'history_endpoint': 'https://magic.example/arcanum',
        'pokemon_history_endpoint': 'https://samplers.example/arcanum',
      });

      final magic = service.providersFor(CardGame.mtg).first as BackfillPackSource;
      final lorcana =
          service.providersFor(CardGame.lorcana).first as BackfillPackSource;
      final yugioh =
          service.providersFor(CardGame.yugioh).first as BackfillPackSource;

      expect(magic.baseUrl, 'https://magic.example/arcanum');
      expect(lorcana.baseUrl, 'https://samplers.example/arcanum');
      expect(yugioh.baseUrl, 'https://samplers.example/arcanum');
      await db.close();
    });

    test('reports a configured provider for all four games', () async {
      final (service, db) = await serviceWith(<String, Object>{});

      for (final game in CardGame.values) {
        expect(service.hasNetworkProvider(game), isTrue, reason: game.id);
      }
      await db.close();
    });
  });

  group('what each game falls back to', () {
    test('Magic and Pokemon keep their free keyless sources', () async {
      final (service, db) = await serviceWith(<String, Object>{});

      expect(
        service.providersFor(CardGame.mtg).map((p) => p.id),
        contains('mtgstocks'),
      );
      expect(
        service.providersFor(CardGame.pokemon).map((p) => p.id),
        contains('tcgdex_archive'),
      );
      await db.close();
    });

    test('Lorcana and Yu-Gi-Oh! have nothing behind the companion', () async {
      // Not pessimism but the truth about those two games: no provider
      // publishes their history and no free archive of either exists, so the
      // companion is the whole list. If it ever stops being offered, the game
      // silently drops to whatever the app snapshotted itself, and this is the
      // test that says so.
      final (service, db) = await serviceWith(<String, Object>{});

      for (final game in <CardGame>[CardGame.lorcana, CardGame.yugioh]) {
        final sources = service.providersFor(game);
        expect(sources, hasLength(1), reason: game.id);
        expect(sources.single.id, 'companion', reason: game.id);
      }
      await db.close();
    });

    test('a key adds JustTCG without displacing the companion', () async {
      final (service, db) = await serviceWith(<String, Object>{
        'justtcg_key': 'test-key',
      });

      final ids = service.providersFor(CardGame.lorcana).map((p) => p.id).toList();
      expect(ids.first, 'companion');
      expect(ids, contains('justtcg'));
      await db.close();
    });
  });

  group('JustTCG', () {
    test('is offered only when a key is stored', () async {
      // Ignored when absent rather than guessed at: the key belongs to the
      // collector and no plan of JustTCG's covers Yu-Gi-Oh! history at all.
      final (without, db1) = await serviceWith(<String, Object>{});
      expect(
        without.providersFor(CardGame.pokemon).map((p) => p.id),
        isNot(contains('justtcg')),
      );
      await db1.close();

      final (with_, db2) = await serviceWith(<String, Object>{
        'justtcg_key': 'test-key',
      });
      expect(
        with_.providersFor(CardGame.pokemon).map((p) => p.id),
        contains('justtcg'),
      );
      await db2.close();
    });
  });
}
