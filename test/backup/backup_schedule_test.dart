// Automatic backup: when it runs, and what it says when it does not.
//
//   flutter test test/backup/backup_schedule_test.dart
//
// An automatic backup is a promise made on the collector's behalf, so the two
// things worth pinning down are that it does not fire more often than it was
// asked to, and that a run which fails says exactly why. A scheduler that
// silently stopped is worse than one that never started.

import 'dart:typed_data';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/backup/backup_schedule.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/data/backup/backup_worker.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Answers with a canned status, so a run can be made to succeed or fail.
class _Server implements HttpClientAdapter {
  _Server(this.status, this.body, this.requests);

  final int status;
  final String body;
  final List<String> requests;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      body,
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A database with one holding in it, so an archive has something to carry.
Future<AppDatabase> seeded() async {
  final db = await AppDatabase.openInMemory();
  final now = DateTime.now().millisecondsSinceEpoch;
  // The in-memory database is shared between opens, so a previous test's rows
  // are still here. Clearing first keeps each test's archive its own.
  await db.db.delete('collection_entries');
  await db.db.insert('collection_entries', <String, Object?>{
    'game': 'mtg',
    'card_id': 'card-1',
    'finish': 'nonfoil',
    'condition': 'near_mint',
    'language': 'en',
    'quantity': 2,
    'created_at': now,
    'updated_at': now,
  });
  return db;
}

Future<AppSettings> settings(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  return AppSettings.load();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('the schedule', () {
    final now = DateTime(2026, 9, 14, 12);

    test('off is never due', () {
      expect(
        isBackupDue(last: null, cadence: BackupCadence.off, now: now),
        isFalse,
      );
      expect(
        nextBackupAt(last: now, cadence: BackupCadence.off, now: now),
        isNull,
      );
    });

    test('a collection that has never been backed up is due at once', () {
      expect(
        isBackupDue(last: null, cadence: BackupCadence.daily, now: now),
        isTrue,
      );
      // Due now rather than at a time in the past, because 'next backup: three
      // days ago' is not a sentence.
      expect(
        nextBackupAt(last: null, cadence: BackupCadence.daily, now: now),
        now,
      );
    });

    test('a daily backup waits out its grace period', () {
      final ran = now.subtract(const Duration(hours: 24));
      expect(
        isBackupDue(last: ran, cadence: BackupCadence.daily, now: now),
        isFalse,
      );
      expect(
        isBackupDue(
          last: ran.subtract(kBackupGrace),
          cadence: BackupCadence.daily,
          now: now,
        ),
        isTrue,
      );
    });

    test('each cadence holds for its own gap', () {
      final ran = now.subtract(const Duration(hours: 48));
      expect(
        isBackupDue(last: ran, cadence: BackupCadence.daily, now: now),
        isTrue,
      );
      expect(
        isBackupDue(last: ran, cadence: BackupCadence.threeDays, now: now),
        isFalse,
      );
      expect(
        isBackupDue(last: ran, cadence: BackupCadence.weekly, now: now),
        isFalse,
      );
    });

    test('an overdue backup reports itself due now, not in the past', () {
      final ran = now.subtract(const Duration(days: 30));
      expect(
        nextBackupAt(last: ran, cadence: BackupCadence.daily, now: now),
        now,
      );
    });

    test('codes round trip, and an unknown one is off', () {
      for (final cadence in BackupCadence.values) {
        expect(BackupCadence.fromCode(cadence.code), cadence);
      }
      expect(BackupCadence.fromCode('hourly'), BackupCadence.off);
      expect(BackupCadence.fromCode(null), BackupCadence.off);
    });
  });

  group('the catch-up run', () {
    test('does nothing while the schedule is off', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': 'secret',
        'auto_backup_cadence': 'off',
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()
          ..httpClientAdapter = _Server(200, '{"ok":true,"kept":1}', asks),
      );

      final ran = await catchUpAutoBackup(settings: s, service: service);

      expect(ran, isFalse);
      expect(asks, isEmpty);
      await db.close();
    });

    test('does nothing when the last backup is recent', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': 'secret',
        'auto_backup_cadence': 'daily',
        'last_backup_at': DateTime.now().millisecondsSinceEpoch,
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()
          ..httpClientAdapter = _Server(200, '{"ok":true,"kept":1}', asks),
      );

      expect(await catchUpAutoBackup(settings: s, service: service), isFalse);
      expect(asks, isEmpty);
      await db.close();
    });

    test('uploads what is owed, and records that it worked', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': 'secret',
        'auto_backup_cadence': 'daily',
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()
          ..httpClientAdapter = _Server(
            200,
            '{"ok":true,"saved":"a.gz","kept":3}',
            asks,
          ),
      );

      expect(await catchUpAutoBackup(settings: s, service: service), isTrue);
      expect(asks, <String>['POST /arcanum/v1/backup']);
      expect(s.lastAutoBackupOk, isTrue);
      expect(s.lastAutoBackupAt, isNotNull);
      expect(s.lastAutoBackupNote, isEmpty);
      expect(s.lastBackupAt, isNotNull);
      await db.close();
    });

    test('a refused token is recorded as such rather than retried', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': 'wrong',
        'auto_backup_cadence': 'daily',
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()..httpClientAdapter = _Server(401, '{"ok":false}', asks),
      );

      final finished = await catchUpAutoBackup(settings: s, service: service);

      // One request, not three: a second 401 is still a 401.
      expect(asks.length, 1);
      expect(finished, isTrue);
      expect(s.lastAutoBackupOk, isFalse);
      expect(s.lastAutoBackupNote, contains('401'));
      await db.close();
    });

    test('a server error is not blamed on the collectors own token', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': 'secret',
        'auto_backup_cadence': 'daily',
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()..httpClientAdapter = _Server(503, '{"ok":false}', asks),
      );

      await catchUpAutoBackup(settings: s, service: service);

      expect(s.lastAutoBackupOk, isFalse);
      expect(s.lastAutoBackupNote, contains('503'));
      // The collector's own token is fine, and sending them to re-paste it
      // because the server is unwell is the wrong errand.
      expect(s.lastAutoBackupNote, isNot(contains('Check the token')));
      expect(s.lastAutoBackupNote, contains('companion'));
      await db.close();
    });

    test('no server configured is said plainly', () async {
      final asks = <String>[];
      final db = await seeded();
      final s = await settings(<String, Object>{
        'backup_token': '',
        'auto_backup_cadence': 'daily',
      });
      final service = BackupService(
        database: db,
        settings: s,
        dio: Dio()..httpClientAdapter = _Server(200, '{}', asks),
      );

      await catchUpAutoBackup(settings: s, service: service);

      expect(asks, isEmpty);
      expect(s.lastAutoBackupOk, isFalse);
      expect(s.lastAutoBackupNote, contains('token'));
      await db.close();
    });
  });
}
