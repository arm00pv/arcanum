// The backup archive and the service that moves it.
//
//   flutter test test/backup/backup_test.dart
//
// A backup is the only copy of the collection that exists when the phone is
// lost, so what it contains matters as much as that it works. These tests pin
// both halves of that: the collector's own rows survive a round trip, and the
// two things that must never travel - the catalogue cache and the credentials -
// do not.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/backup/backup_archive.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/data/db/wanted_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/sync/merge.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Answers canned payloads and records what was asked for.
class _FakeServer implements HttpClientAdapter {
  _FakeServer(
    this._respond,
    this.requests,
    this.bodies,
    this.headers, {
    this.replyHeaders = const <String, String>{},
  });

  /// Answers one request: a String for JSON, bytes for an archive, or null
  /// for the 404 the companion sends when it has nothing to give.
  final Object? Function(Uri uri, String method) _respond;
  final List<String> requests;
  final List<List<int>> bodies;

  /// The headers of each request, so a test can prove the token was sent.
  final List<Map<String, dynamic>> headers;

  /// Headers to answer with, so a test can prove the app reads them.
  final Map<String, String> replyHeaders;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(
      '${options.method} ${options.uri.path}'
      '${options.uri.query.isEmpty ? "" : "?${options.uri.query}"}',
    );
    headers.add(Map<String, dynamic>.from(options.headers));
    if (requestStream != null) {
      final chunks = <int>[];
      await for (final chunk in requestStream) {
        chunks.addAll(chunk);
      }
      bodies.add(chunks);
    }
    final responseHeaders = <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      for (final MapEntry<String, String> header in replyHeaders.entries)
        header.key: <String>[header.value],
    };
    final body = _respond(options.uri, options.method);
    if (body == null) {
      return ResponseBody.fromString(
        '{"error":"missing"}',
        404,
        headers: responseHeaders,
      );
    }
    if (body is List<int>) {
      return ResponseBody.fromBytes(body, 200, headers: responseHeaders);
    }
    return ResponseBody.fromString(
      body as String,
      200,
      headers: responseHeaders,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Fails the first [failures] requests the way a dropped connection does,
/// then answers normally.
class _UnreliableServer implements HttpClientAdapter {
  _UnreliableServer(this.failures, this.requests);

  final int failures;
  final List<String> requests;
  int _seen = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    if (_seen++ < failures) {
      throw const SocketException('connection reset by peer');
    }
    return ResponseBody.fromString(
      '{"ok":true,"saved":"a.gz","bytes":10,"kept":5}',
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every request with a refusal, as a wrong token would.
class _RefusingServer implements HttpClientAdapter {
  _RefusingServer(this.requests);

  final List<String> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    if (requestStream != null) {
      await requestStream.drain<void>();
    }
    return ResponseBody.fromString(
      '{"ok":false,"error":"bad token"}',
      401,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<(AppDatabase, AppSettings)> fresh({
  Map<String, Object> prefs = const <String, Object>{
    'backup_token': 'secret-token',
  },
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = await AppSettings.load();
  final db = await AppDatabase.openInMemory();
  return (db, settings);
}

/// One owned card, and one price row from each kind of source.
Future<void> seed(AppDatabase db, AppSettings settings) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.db.insert('collection_entries', <String, Object?>{
    'game': 'mtg',
    'card_id': 'card-1',
    'finish': 'foil',
    'condition': 'near_mint',
    'language': 'en',
    'quantity': 3,
    'purchase_price': 12.5,
    'binder': 'Binder A',
    'created_at': now,
    'updated_at': now,
  });
  await db.db.insert('alerts', <String, Object?>{
    'game': 'lorcana',
    'card_id': 'crd_1',
    'finish': 'nonfoil',
    'kind': 'above',
    'threshold': 40.0,
    'created_at': now,
  });
  await db.db.insert('portfolio_snapshots', <String, Object?>{
    'game': 'mtg',
    'date': '2026-09-13',
    'total_value': 311.0,
    'unique_cards': 1,
    'total_cards': 3,
  });
  // The app's own record of a price, which is irreplaceable.
  await db.db.insert('price_history', <String, Object?>{
    'card_id': 'card-1',
    'game': 'mtg',
    'finish': 'foil',
    'date': '2026-09-13',
    'price': 13.1,
    'source': 'snapshot',
  });
  // And one a provider supplied, which the app can fetch again.
  await db.db.insert('price_history', <String, Object?>{
    'card_id': 'card-1',
    'game': 'mtg',
    'finish': 'foil',
    'date': '2026-09-12',
    'price': 12.9,
    'source': 'companion',
  });
  // And a box on the shelf, which is the collector's own data like the rest.
  await db.db.insert('sealed_products', <String, Object?>{
    'game': 'mtg',
    'set_code': 'BLB',
    'set_name': 'Bloomburrow',
    'name': 'Bloomburrow Play Booster Display',
    'category': 'box',
    'quantity': 1,
    'unit_cost': 150.0,
    'unit_value': 199.35,
    'location': 'Top shelf',
    'created_at': now,
  });
  settings.justTcgKey = 'third-party-secret';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('what an archive holds', () {
    test(
      'carries the collection, the alerts and the app\'s own snapshots',
      () async {
        final (db, settings) = await fresh();
        await seed(db, settings);

        final archive = await BackupService(
          database: db,
          settings: settings,
        ).build(appVersion: '1.6.0');

        expect(archive.counts['collection_entries'], 1);
        expect(archive.counts['alerts'], 1);
        expect(archive.counts['portfolio_snapshots'], 1);
        expect(archive.appVersion, '1.6.0');
        await db.close();
      },
    );

    test('carries a readable index of the printings held', () async {
      final (db, settings) = await fresh();
      await seed(db, settings);
      await db.db.insert('cards', <String, Object?>{
        'id': 'card-1',
        'game': 'mtg',
        'set_code': 'xln',
        'name': 'Revel in Riches',
        'collector_number': '117',
        'collector_sort': 117,
      });
      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: 'test');

      expect(archive.cardIndex['card-1'], <Object?>[
        'Revel in Riches',
        'xln',
        '117',
      ]);
      // And it travels: the index is what makes a copy of a collection readable
      // by something that holds no catalogue of its own - the collector's own
      // server, or a phone that has not downloaded a set yet.
      final round = BackupArchive.decode(archive.encode());
      expect(round.cardIndex['card-1'], <Object?>[
        'Revel in Riches',
        'xln',
        '117',
      ]);
      await db.close();
    });

    test('an archive written before the index existed still reads', () {
      final archive = BackupArchive.fromJson(<String, Object?>{
        'format': BackupArchive.format,
        'version': 1,
        'created': DateTime.utc(2026, 9, 13).toIso8601String(),
        'app': '1.15.0',
        'tables': <String, Object?>{'collection_entries': <Object?>[]},
        'settings': <String, Object?>{},
      });
      expect(archive.cardIndex, isEmpty);
      expect(archive.tables.containsKey('collection_entries'), isTrue);
    });

    test(
      'carries the sealed shelf, so a restore does not lose the boxes',
      () async {
        final (db, settings) = await fresh();
        await seed(db, settings);
        final archive = await BackupService(
          database: db,
          settings: settings,
        ).build(appVersion: 'test');

        final rows = archive.tables['sealed_products'];
        expect(rows, isNotNull);
        expect(rows!.length, 1);
        expect(rows.first['name'], 'Bloomburrow Play Booster Display');
        expect(rows.first['unit_value'], 199.35);
        await db.close();
      },
    );

    test('leaves out the price rows a provider supplied', () async {
      // Those are re-downloadable; carrying them would bloat the file with
      // cache and say nothing about the collector.
      final (db, settings) = await fresh();
      await seed(db, settings);

      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.6.0');

      expect(archive.counts['price_history'], 1);
      expect(archive.tables['price_history']!.single['source'], 'snapshot');
      await db.close();
    });

    test('leaves out the catalogue entirely', () async {
      final (db, settings) = await fresh();
      await db.db.insert('sets', <String, Object?>{
        'game': 'mtg',
        'code': 'blb',
        'id': 'set-blb',
        'name': 'Bloomburrow',
        'set_type': 'expansion',
        'fetched_at': 1,
      });

      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.6.0');

      expect(archive.tables.keys, isNot(contains('sets')));
      expect(archive.tables.keys, isNot(contains('cards')));
      await db.close();
    });

    test('never carries a credential', () async {
      // The JustTCG key and the backup token belong to the collector and to
      // third-party services. A backup file that quietly contained them would
      // turn every copy of that file into a copy of the credentials.
      final (db, settings) = await fresh();
      await seed(db, settings);

      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.6.0');
      // Decompressed, because that is what a reader of the file would see.
      final encoded = utf8.decode(gzip.decode(archive.encode()));

      expect(encoded, isNot(contains('third-party-secret')));
      expect(encoded, isNot(contains('secret-token')));
      expect(archive.settings.keys, isNot(contains('justtcg_key')));
      expect(archive.settings.keys, isNot(contains('backup_token')));
      await db.close();
    });

    test(
      'carries the endpoints, so a new phone keeps its own server',
      () async {
        final (db, settings) = await fresh(
          prefs: <String, Object>{
            'history_endpoint': 'https://mine.example/arcanum',
            'pokemon_history_endpoint': 'https://mine.example/arcanum',
          },
        );

        final archive = await BackupService(
          database: db,
          settings: settings,
        ).build(appVersion: '1.6.0');

        expect(
          archive.settings['history_endpoint'],
          'https://mine.example/arcanum',
        );
        await db.close();
      },
    );
  });

  group('reading an archive back', () {
    test('survives a round trip through the bytes that travel', () async {
      final (db, settings) = await fresh();
      await seed(db, settings);
      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.6.0');

      final restored = BackupArchive.decode(archive.encode());

      expect(restored.counts['collection_entries'], 1);
      expect(
        restored.tables['collection_entries']!.single['binder'],
        'Binder A',
      );
      expect(
        restored.tables['collection_entries']!.single['purchase_price'],
        12.5,
      );
      await db.close();
    });

    test('refuses a file that is not a backup', () {
      expect(
        () => BackupArchive.fromJson(<String, Object?>{'hello': 'world'}),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupArchive.fromJson('not even a map'),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupArchive.decode(<int>[1, 2, 3, 4]),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('refuses a backup from a newer app rather than half-reading it', () {
      expect(
        () => BackupArchive.fromJson(<String, Object?>{
          'format': BackupArchive.format,
          'version': BackupArchive.version + 1,
          'tables': <String, Object?>{},
        }),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });

  group('restoring', () {
    test('replaces the holdings and keeps provider prices', () async {
      final (source, sourceSettings) = await fresh();
      await seed(source, sourceSettings);
      final archive = await BackupService(
        database: source,
        settings: sourceSettings,
      ).build(appVersion: '1.6.0');
      await source.close();

      // A different phone: same card catalogue, no holdings.
      final (target, targetSettings) = await fresh();
      await target.db.insert('price_history', <String, Object?>{
        'card_id': 'card-1',
        'game': 'mtg',
        'finish': 'foil',
        'date': '2026-09-11',
        'price': 12.0,
        'source': 'companion',
      });

      await BackupService(
        database: target,
        settings: targetSettings,
      ).restore(archive);

      final entries = await target.db.query('collection_entries');
      expect(entries, hasLength(1));
      expect(entries.single['quantity'], 3);
      // The provider row that was already there is untouched, and the restored
      // snapshot sits beside it.
      final history = await target.db.query('price_history');
      expect(history, hasLength(2));
      await target.close();
    });

    test('restores the endpoints the archive carried', () async {
      final (source, sourceSettings) = await fresh(
        prefs: <String, Object>{
          'history_endpoint': 'https://mine.example/arcanum',
        },
      );
      final archive = await BackupService(
        database: source,
        settings: sourceSettings,
      ).build(appVersion: '1.6.0');
      await source.close();

      final (target, targetSettings) = await fresh();
      await BackupService(
        database: target,
        settings: targetSettings,
      ).restore(archive);

      expect(targetSettings.historyEndpoint, 'https://mine.example/arcanum');
      await target.close();
    });

    test('empties what the archive does not hold, rather than merging', () async {
      // A restore is a replacement, and the dialog says so. Merging would leave
      // the collector with a collection that is neither the old one nor the
      // backed-up one, and no way to tell which rows came from where.
      final (source, sourceSettings) = await fresh();
      final archive = await BackupService(
        database: source,
        settings: sourceSettings,
      ).build(appVersion: '1.6.0');
      await source.close();

      final (target, targetSettings) = await fresh();
      await seed(target, targetSettings);

      await BackupService(
        database: target,
        settings: targetSettings,
      ).restore(archive);

      expect(await target.db.query('collection_entries'), isEmpty);
      await target.close();
    });
  });

  group('talking to the companion', () {
    test('sends the token and a device label with an upload', () async {
      final requests = <String>[];
      final bodies = <List<int>>[];
      final headers = <Map<String, dynamic>>[];
      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _FakeServer(
        (Uri uri, String method) {
          if (method == 'POST' && uri.path.endsWith('/v1/backup')) {
            return '{"ok":true,"saved":"a.gz","bytes":10,"kept":2}';
          }
          return null;
        },
        requests,
        bodies,
        headers,
      );

      final service = BackupService(database: db, settings: settings, dio: dio);
      final archive = await service.build(appVersion: '1.6.0');
      final result = await service.upload(archive, deviceLabel: 'phone');

      expect(requests, contains('POST /arcanum/v1/backup'));
      expect(result.kept, 2);
      expect(bodies.single, isNotEmpty);
      // The upload is gzipped JSON, not raw JSON.
      expect(bodies.single.length, greaterThan(2));
      expect(bodies.single[0], 0x1f);
      expect(bodies.single[1], 0x8b);
      // And it carries the token the server requires, plus the device label.
      expect(headers.single['X-Arcanum-Token'], 'secret-token');
      expect(headers.single['X-Arcanum-Device'], 'phone');
      // A length, so the archive arrives whole: the companion reads
      // Content-Length and does not decode chunked transfer encoding.
      expect(headers.single['content-length'], isNotNull);
      expect(headers.single['content-length'], isNot('0'));
      // And the app records that a backup happened.
      expect(settings.lastBackupAt, isNotNull);
      await db.close();
    });

    test('needs both a server and a token to be configured', () async {
      final (db, settings) = await fresh(
        prefs: <String, Object>{'backup_token': ''},
      );
      final service = BackupService(database: db, settings: settings);

      // The token is the gate. A blank endpoint means the hosted default,
      // exactly as it does for the history endpoints, so it can never be the
      // thing that disables writing.
      expect(service.isConfigured, isFalse);
      settings.backupToken = 'now-set';
      expect(service.isConfigured, isTrue);
      settings.backupToken = '   ';
      expect(service.isConfigured, isFalse);
      await db.close();
    });

    test('asks for the newest copy that is not this phone\'s', () async {
      // Two phones, one collection: this phone's own backup is already in its
      // own database, so the only copy worth comparing against is one another
      // device wrote. The label is what the companion filters on.
      final requests = <String>[];
      final (db, settings) = await fresh();
      final mine = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.16.0');

      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _FakeServer(
        (Uri uri, String method) =>
            uri.path.endsWith('/v1/backup/latest') ? mine.encode() : null,
        requests,
        <List<int>>[],
        <Map<String, dynamic>>[],
        replyHeaders: <String, String>{
          'X-Arcanum-Device': 'pixel',
          'X-Arcanum-Written': '2026-09-14T04:47:32+00:00',
        },
      );

      final service = BackupService(database: db, settings: settings, dio: dio);
      final RemoteCopy copy = await service.downloadLatest(
        notDevice: 'arcanum-hma1',
      );

      expect(
        requests,
        contains('GET /arcanum/v1/backup/latest?not_device=arcanum-hma1'),
      );
      // Who wrote it, read off the reply rather than guessed at from the
      // archive's own contents.
      expect(copy.device, 'pixel');
      expect(copy.written?.toUtc(), DateTime.utc(2026, 9, 14, 4, 47, 32));
      expect(copy.archive.tables['collection_entries'], isEmpty);
      await db.close();
    });

    test('says so when every copy on the server is this phone\'s own', () async {
      final requests = <String>[];
      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _FakeServer(
        (Uri uri, String method) => null,
        requests,
        <List<int>>[],
        <Map<String, dynamic>>[],
      );

      final service = BackupService(database: db, settings: settings, dio: dio);

      // Told apart from a plain failure: one phone is the normal case, and the
      // screen says that in words instead of showing an error.
      await expectLater(
        service.downloadLatest(notDevice: 'arcanum-hma1'),
        throwsA(isA<NoOtherDeviceException>()),
      );
      // A download that asked for anything at all - the restore path - is still
      // an ordinary failure when the server has nothing.
      await expectLater(service.downloadLatest(), throwsA(isA<DioException>()));
      await db.close();
    });

    test('plans a merge against the other device\'s copy', () async {
      // The plan is what the collector is shown before anything is written, so
      // it has to describe the other phone's archive and say whose it is.
      final requests = <String>[];
      final (theirDb, theirSettings) = await fresh();
      await theirDb.db.insert('collection_entries', <String, Object?>{
        'game': 'mtg',
        'card_id': 'their-card',
        'finish': 'nonfoil',
        'condition': 'nm',
        'language': 'en',
        'quantity': 4,
        'created_at': 1,
        'updated_at': 1,
      });
      final theirs = await BackupService(
        database: theirDb,
        settings: theirSettings,
      ).build(appVersion: '1.16.0');
      await theirDb.close();

      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _FakeServer(
        (Uri uri, String method) =>
            uri.path.endsWith('/v1/backup/latest') ? theirs.encode() : null,
        requests,
        <List<int>>[],
        <Map<String, dynamic>>[],
        replyHeaders: <String, String>{'X-Arcanum-Device': 'pixel'},
      );

      final service = BackupService(database: db, settings: settings, dio: dio);
      final (MergePlan plan, RemoteCopy copy) = await service.planSync(
        appVersion: '1.16.0',
        notDevice: 'arcanum-hma1',
      );

      expect(
        requests,
        contains('GET /arcanum/v1/backup/latest?not_device=arcanum-hma1'),
      );
      expect(copy.device, 'pixel');
      expect(plan.nothingToDo, isFalse);
      expect(plan.addedRows, 1);
      await db.close();
    });

    test('refuses to read a body that is not an archive', () async {
      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _FakeServer(
        (Uri uri, String method) => 'this is not gzip',
        <String>[],
        <List<int>>[],
        <Map<String, dynamic>>[],
      );

      final service = BackupService(database: db, settings: settings, dio: dio);

      await expectLater(
        service.downloadLatest(),
        throwsA(isA<BackupFormatException>()),
      );
      await db.close();
    });
  });

  group('finishes and grades still round-trip', () {
    test('an entry keeps its finish through a backup', () async {
      // A foil stack that came back as non-foil would be valued at the wrong
      // price on a restored phone, which is worse than losing it outright.
      final (db, settings) = await fresh();
      await db.db.insert('collection_entries', <String, Object?>{
        'game': 'mtg',
        'card_id': 'card-1',
        'finish': CardFinish.foil.code,
        'condition': CardCondition.lightPlayed.code,
        'language': 'en',
        'quantity': 1,
        'created_at': 1,
        'updated_at': 1,
      });
      final archive = await BackupService(
        database: db,
        settings: settings,
      ).build(appVersion: '1.6.0');

      final restored = BackupArchive.decode(archive.encode());
      final row = restored.tables['collection_entries']!.single;

      expect(row['finish'], CardFinish.foil.code);
      expect(row['condition'], CardCondition.lightPlayed.code);
      await db.close();
    });
  });
  group('a companion that is briefly unreachable', () {
    test('is asked again rather than failing the backup', () async {
      // The companion is the collector's own machine and is not always up.
      // A dropped connection says nothing about whether the request was
      // reasonable, and a collector who has to press the button twice will
      // stop believing the first press did anything.
      final requests = <String>[];
      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _UnreliableServer(2, requests);

      final service = BackupService(database: db, settings: settings, dio: dio);
      final archive = await service.build(appVersion: '1.7.2');
      final result = await service.upload(archive);

      expect(requests.length, 3);
      expect(result.kept, 5);
      await db.close();
    });

    test('gives up once the companion has answered, even to refuse', () async {
      // A refusal is an answer. Retrying a 401 three times would only make
      // the wrong token slower to diagnose.
      final requests = <String>[];
      final (db, settings) = await fresh();
      final dio = Dio(BaseOptions(baseUrl: 'https://mine.example/arcanum'));
      dio.httpClientAdapter = _RefusingServer(requests);

      final service = BackupService(database: db, settings: settings, dio: dio);
      final archive = await service.build(appVersion: '1.7.2');

      await expectLater(service.upload(archive), throwsA(isA<DioException>()));
      expect(requests.length, 1);
      await db.close();
    });
  });
  group('the wants list travels with the collection', () {
    test('a want survives a backup and a restore', () async {
      // A wants list is the collector's own work, like the collection itself:
      // it exists nowhere else and cannot be re-derived from a price feed.
      final (source, sourceSettings) = await fresh();
      final wanted = WantedDao(source.db);
      await wanted.add(CardGame.mtg, 'card-1');
      await wanted.add(CardGame.lorcana, 'crd_1', note: 'birthday');

      final archive = await BackupService(
        database: source,
        settings: sourceSettings,
      ).build(appVersion: '1.8.0');
      await source.close();

      final (target, targetSettings) = await fresh();
      await BackupService(
        database: target,
        settings: targetSettings,
      ).restore(archive);

      final restored = WantedDao(target.db);
      expect(await restored.ids(CardGame.mtg), <String>['card-1']);
      expect(await restored.count(CardGame.lorcana), 1);
      await target.close();
    });
  });
}
