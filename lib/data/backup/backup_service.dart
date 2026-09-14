import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/backup/backup_archive.dart';
import 'package:arcanum/data/db/app_database.dart';
import 'package:arcanum/domain/sync/merge.dart';

/// One archive read back from the companion, and who wrote it.
///
/// The companion knows which device uploaded each archive, so it is asked
/// rather than guessed at: a merge is a merge of two devices, and the collector
/// is told which phone the copy came from before anything is written.
class RemoteCopy {
  /// Describes one downloaded copy.
  const RemoteCopy({required this.archive, this.device = '', this.written});

  /// The archive itself.
  final BackupArchive archive;

  /// The label the other phone uploaded under, or empty when it sent none.
  final String device;

  /// When the companion stored it, or null when it did not say.
  final DateTime? written;
}

/// Thrown when the companion holds copies, but none from another device.
///
/// Not an error the collector needs to fix: one phone is the normal case, and
/// comparing this phone's collection against its own backup would report a
/// merge that cannot happen. The screen says so in words instead.
class NoOtherDeviceException implements Exception {
  /// Creates the exception.
  const NoOtherDeviceException();

  @override
  String toString() =>
      'The server holds only copies from this phone, so there is nothing from '
      'another device to add.';
}

/// One device that has written to the companion.
class BackupDevice {
  /// Creates a device row.
  const BackupDevice({
    required this.label,
    required this.latest,
    required this.backups,
    required this.bytes,
  });

  /// What the device called itself when it uploaded.
  final String label;

  /// When it last did.
  final DateTime? latest;

  /// How many archives it has on the server.
  final int backups;

  /// The size of its newest one.
  final int bytes;

  static BackupDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String label = (raw['device'] ?? '').toString();
    if (label.isEmpty) return null;
    return BackupDevice(
      label: label,
      latest: DateTime.tryParse(raw['latest']?.toString() ?? '')?.toLocal(),
      backups: (raw['backups'] as num?)?.toInt() ?? 0,
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What the companion says about the backups it holds.
class BackupStatus {
  const BackupStatus({
    required this.enabled,
    required this.count,
    required this.latest,
    required this.bytes,
    this.devices = const <BackupDevice>[],
  });

  /// False when the server has no token file, which is its safe default: the
  /// read-only routes keep working and nothing can be written at all.
  final bool enabled;
  final int count;
  final DateTime? latest;
  final int bytes;

  /// Every device that has written here, newest first.
  ///
  /// This is what makes a second phone visible: without it the app can only say
  /// that a backup exists, never that it came from somewhere else.
  final List<BackupDevice> devices;

  static const unknown = BackupStatus(
    enabled: false,
    count: 0,
    latest: null,
    bytes: 0,
  );

  static BackupStatus fromJson(Object? raw) {
    if (raw is! Map) return unknown;
    final List<BackupDevice> devices = <BackupDevice>[
      for (final Object? row
          in (raw['devices'] as List<Object?>?) ?? const <Object?>[])
        if (BackupDevice.fromJson(row) case final BackupDevice device) device,
    ];
    return BackupStatus(
      enabled: raw['enabled'] == true,
      count: (raw['backups'] as num?)?.toInt() ?? 0,
      latest: DateTime.tryParse(raw['latest']?.toString() ?? '')?.toLocal(),
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      devices: devices,
    );
  }

  /// Whether some device other than [mine] has written here.
  bool hasOtherDevice(String mine) =>
      devices.any((BackupDevice d) => d.label != mine);
}

/// What one merge added, for the sentence the collector reads afterwards.
class MergeReport {
  /// Creates a report.
  const MergeReport({
    required this.addedRows,
    required this.raisedRows,
    required this.pricePoints,
    required this.snapshots,
  });

  /// Rows this phone did not have.
  final int addedRows;

  /// Holdings whose count went up.
  final int raisedRows;

  /// Price points the other device had recorded and this one had not.
  final int pricePoints;

  /// Portfolio days added to the chart.
  final int snapshots;

  /// Nothing changed at all, which is worth saying out loud rather than
  /// reporting a successful merge of zero things.
  bool get nothingChanged =>
      addedRows == 0 && raisedRows == 0 && pricePoints == 0 && snapshots == 0;

  /// The sentence Settings shows after one.
  String get summary {
    if (nothingChanged) {
      return 'Both devices already agree; nothing needed adding.';
    }
    final List<String> parts = <String>[
      if (addedRows > 0)
        '${Fmt.count(addedRows)} '
            '${addedRows == 1 ? "holding" : "holdings"} added',
      if (raisedRows > 0)
        '${Fmt.count(raisedRows)} '
            '${raisedRows == 1 ? "count" : "counts"} raised',
      if (pricePoints > 0)
        '${Fmt.count(pricePoints)} price '
            '${pricePoints == 1 ? "point" : "points"} added',
      if (snapshots > 0)
        '${Fmt.count(snapshots)} portfolio '
            '${snapshots == 1 ? "day" : "days"} added',
    ];
    return '${parts.join(', ')}. Nothing was removed.';
  }
}

/// The outcome of one upload.
class BackupUpload {
  const BackupUpload({required this.bytes, required this.kept});

  final int bytes;
  final int kept;
}

/// Keeps the collector's data local, and a copy of it on their own server.
///
/// The app's SQLite database stays the source of truth; this service only ever
/// writes a second copy somewhere the collector controls, and reads one back.
/// Nothing is uploaded automatically and nothing is uploaded anywhere the user
/// has not named - there is no hosted account, and the default endpoint is
/// their own companion.
class BackupService {
  BackupService({
    required AppDatabase database,
    required AppSettings settings,
    Dio? dio,
  }) : _db = database.db,
       _settings = settings,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 60),
               sendTimeout: const Duration(seconds: 60),
             ),
           );

  final Database _db;
  final AppSettings _settings;
  final Dio _dio;

  /// True when the collector has named a server and given a token for it.
  bool get isConfigured =>
      _settings.backupEndpoint.trim().isNotEmpty &&
      _settings.backupToken.trim().isNotEmpty;

  String get _root => _settings.backupEndpoint.replaceAll(RegExp(r'/+$'), '');

  Map<String, String> get _authHeaders => <String, String>{
    'X-Arcanum-Token': _settings.backupToken.trim(),
  };

  /// Asks again when a request died before the server answered it.
  ///
  /// The companion runs on the collector's own machine, which is by turns
  /// busy, rebooting and behind a domestic connection. A transport failure
  /// says nothing about whether the request was reasonable, so it is worth
  /// asking again; an answer - even a refusal - is not retried, because a
  /// second 401 is still a 401 and the collector would rather be told once,
  /// immediately, than three times slowly.
  Future<T> _withRetry<T>(String what, Future<T> Function() send) async {
    const List<Duration> backoff = <Duration>[
      Duration(milliseconds: 400),
      Duration(milliseconds: 1200),
    ];
    for (int attempt = 0; ; attempt++) {
      try {
        return await send();
      } on DioException catch (error) {
        final bool unreachable = error.response == null;
        if (!unreachable || attempt >= backoff.length) {
          debugPrint(
            '[backup] $what gave up after ${attempt + 1} attempt(s): '
            '${error.type} ${error.message}',
          );
          rethrow;
        }
        debugPrint(
          '[backup] $what attempt ${attempt + 1} failed: '
          '${error.type} ${error.message} - trying again',
        );
        await Future<void>.delayed(backoff[attempt]);
      }
    }
  }

  /// Reads everything the collector created out of the database.
  Future<BackupArchive> build({required String appVersion}) async {
    final tables = <String, List<Map<String, Object?>>>{};
    for (final table in BackupArchive.userTables) {
      if (table == 'price_history') {
        // Only the rows the app recorded itself. Everything else in that table
        // came from a provider and would be fetched again anyway.
        final marks = List.filled(
          BackupArchive.ownHistorySources.length,
          '?',
        ).join(',');
        tables[table] = await _db.rawQuery(
          'SELECT * FROM price_history WHERE source IN ($marks)',
          BackupArchive.ownHistorySources,
        );
      } else {
        tables[table] = await _db.query(table);
      }
    }

    // Whatever is already stored, so a restore on a new phone lands the
    // collector back on their own companion rather than the hosted default.
    final settings = <String, Object?>{};
    for (final key in BackupArchive.carriedPreferences) {
      final value = _settings.rawPreference(key);
      if (value != null) settings[key] = value;
    }

    return BackupArchive(
      created: DateTime.now().toUtc(),
      appVersion: appVersion,
      tables: tables,
      settings: settings,
      cardIndex: await _cardIndex(tables),
    );
  }

  /// Names and set codes for the printings the collection actually holds.
  ///
  /// Chunked, because a collection can hold more printings than SQLite will take
  /// in one IN clause and a backup that quietly dropped the tail would be worse
  /// than one that carried no index at all.
  Future<Map<String, List<Object?>>> _cardIndex(
    Map<String, List<Map<String, Object?>>> tables,
  ) async {
    final List<Map<String, Object?>> rows =
        tables['collection_entries'] ?? const <Map<String, Object?>>[];
    final Set<String> ids = <String>{
      for (final row in rows)
        if (row['card_id'] is String) row['card_id']! as String,
    };
    if (ids.isEmpty) return const <String, List<Object?>>{};
    final List<String> list = ids.toList();
    final index = <String, List<Object?>>{};
    for (var i = 0; i < list.length; i += 400) {
      final chunk = list.sublist(
        i,
        i + 400 > list.length ? list.length : i + 400,
      );
      final marks = List.filled(chunk.length, '?').join(',');
      final found = await _db.rawQuery(
        'SELECT id, name, set_code, collector_number FROM cards '
        'WHERE id IN ($marks)',
        chunk,
      );
      for (final row in found) {
        index[row['id'] as String] = <Object?>[
          row['name'],
          row['set_code'],
          row['collector_number'],
        ];
      }
    }
    return index;
  }

  /// Uploads one archive to the collector's companion.
  Future<BackupUpload> upload(
    BackupArchive archive, {
    String deviceLabel = '',
  }) async {
    final bytes = archive.encode();
    final res = await _withRetry(
      'upload',
      () => _dio.post<dynamic>(
        '$_root/v1/backup',
        // The bytes, not a stream of them: a streamed body goes out chunked, and
        // the companion is a stdlib Python server that reads Content-Length and
        // does not decode chunked transfer encoding. A List<int> makes Dio set
        // the length and send the archive whole.
        data: bytes,
        options: Options(
          headers: <String, String>{
            ..._authHeaders,
            'Content-Type': 'application/octet-stream',
            if (deviceLabel.isNotEmpty) 'X-Arcanum-Device': deviceLabel,
          },
        ),
      ),
    );
    final body = res.data is String ? jsonDecode(res.data as String) : res.data;
    final kept = body is Map ? (body['kept'] as num?)?.toInt() ?? 0 : 0;
    _settings.lastBackupAt = DateTime.now();
    return BackupUpload(bytes: bytes.length, kept: kept);
  }

  /// What the companion currently holds.
  Future<BackupStatus> status() async {
    try {
      final res = await _withRetry(
        'status',
        () => _dio.get<dynamic>(
          '$_root/v1/backup/status',
          options: Options(headers: _authHeaders),
        ),
      );
      return BackupStatus.fromJson(res.data);
    } on DioException {
      return BackupStatus.unknown;
    }
  }

  /// Downloads an archive without applying it, so the collector can be told
  /// what is in it before anything changes on the phone.
  ///
  /// With [notDevice] the companion is asked for its newest archive that some
  /// other device wrote - which is the only useful question when two phones
  /// share one collection, because this phone's own copy is already in its own
  /// database. When every archive on the server came from this phone the
  /// companion says so and [NoOtherDeviceException] is thrown.
  Future<RemoteCopy> downloadLatest({String notDevice = ''}) async {
    final Response<List<int>> res;
    try {
      res = await _withRetry(
        'download',
        () => _dio.get<List<int>>(
          '$_root/v1/backup/latest',
          queryParameters: <String, dynamic>{
            if (notDevice.isNotEmpty) 'not_device': notDevice,
          },
          options: Options(
            headers: _authHeaders,
            responseType: ResponseType.bytes,
          ),
        ),
      );
    } on DioException catch (error) {
      if (notDevice.isNotEmpty && error.response?.statusCode == 404) {
        throw const NoOtherDeviceException();
      }
      rethrow;
    }
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw const BackupFormatException('The server sent no backup.');
    }
    return RemoteCopy(
      archive: BackupArchive.decode(data),
      device: _headerOf(res, 'x-arcanum-device'),
      written: DateTime.tryParse(_headerOf(res, 'x-arcanum-written'))
          ?.toLocal(),
    );
  }

  /// One response header, or an empty string when the companion did not send
  /// it - an older companion is not a reason to fail a download.
  String _headerOf(Response<dynamic> res, String name) {
    final String? value = res.headers.value(name);
    return value?.trim() ?? '';
  }

  /// Replaces the collector's data with an archive's contents.
  ///
  /// All or nothing, in one transaction: a restore that failed half way would
  /// leave a collection that is neither the old one nor the new one, and the
  /// collector has no way to unpick that.
  ///
  /// The catalogue is untouched - sets and cards stay, so the restored holdings
  /// are valued against prices the app already has. Secrets are untouched too,
  /// which is why this does not restore the endpoints' credentials.
  Future<void> restore(BackupArchive archive) async {
    await _db.transaction((txn) async {
      for (final table in BackupArchive.userTables) {
        final rows = archive.tables[table];
        if (rows == null) continue;
        if (table == 'price_history') {
          final marks = List.filled(
            BackupArchive.ownHistorySources.length,
            '?',
          ).join(',');
          await txn.delete(
            table,
            where: 'source IN ($marks)',
            whereArgs: BackupArchive.ownHistorySources,
          );
        } else {
          await txn.delete(table);
        }
        final batch = txn.batch();
        for (final row in rows) {
          batch.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }
    });

    for (final entry in archive.settings.entries) {
      await _settings.writeRawPreference(entry.key, entry.value);
    }
  }

  /// Works out what another device's newest copy would add.
  ///
  /// Builds this phone's own archive, downloads the newest copy that is *not*
  /// this phone's - [notDevice] is the label this phone uploads under - and
  /// hands both to [planMerge]. Nothing is written: the plan is what the
  /// collector is shown before they agree to anything.
  Future<(MergePlan, RemoteCopy)> planSync({
    required String appVersion,
    String notDevice = '',
  }) async {
    final BackupArchive local = await build(appVersion: appVersion);
    final RemoteCopy remote = await downloadLatest(notDevice: notDevice);
    return (planMerge(local, remote.archive), remote);
  }

  /// Adds what another device has, and takes nothing away.
  ///
  /// The counterpart to [restore], and deliberately not the same thing. A
  /// restore replaces a collection, which is right on a new phone and wrong when
  /// the other copy belongs to a second device that has been used in parallel.
  /// A merge is additive by construction: no row is deleted, no quantity goes
  /// down, and no purchase price the collector recorded is overwritten. Two
  /// devices each holding half a collection end up with the whole of it.
  ///
  /// All or nothing, in one transaction, for the same reason a restore is: a
  /// merge that stopped half way would leave a collection that is neither of the
  /// two it came from.
  Future<MergeReport> merge(BackupArchive archive) async {
    var added = 0;
    var raised = 0;
    var history = 0;
    var snapshots = 0;
    final int now = DateTime.now().millisecondsSinceEpoch;

    await _db.transaction((txn) async {
      for (final String table in const <String>[
        'collection_entries',
        'sealed_products',
        'wanted_cards',
        'alerts',
      ]) {
        final List<Map<String, Object?>> incoming =
            archive.tables[table] ?? const <Map<String, Object?>>[];
        if (incoming.isEmpty) continue;
        final Map<String, Map<String, Object?>> mine =
            <String, Map<String, Object?>>{
              for (final Map<String, Object?> row in await txn.query(table))
                rowKeyOf(table, row): row,
            };
        for (final Map<String, Object?> row in incoming) {
          final Map<String, Object?>? have = mine[rowKeyOf(table, row)];
          if (have == null) {
            await txn.insert(
              table,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            added++;
            continue;
          }
          final int theirs = _quantityIn(row);
          final int ours = _quantityIn(have);
          if (theirs <= ours) continue;
          // Only the count moves, and only upwards. The binder, the note, the
          // purchase price and the created-at stamp on this phone are the
          // collector's own record of the thing, and a second device's silence
          // about them is not a reason to replace them.
          await txn.update(
            table,
            <String, Object?>{
              'quantity': theirs,
              if (table == 'collection_entries') ...<String, Object?>{
                'updated_at': now,
                if (have['purchase_price'] == null &&
                    row['purchase_price'] != null)
                  'purchase_price': row['purchase_price'],
                if (have['purchase_date'] == null &&
                    row['purchase_date'] != null)
                  'purchase_date': row['purchase_date'],
                if (have['for_trade'] != 1 && row['for_trade'] == 1)
                  'for_trade': 1,
              },
            },
            where: 'id = ?',
            whereArgs: <Object?>[have['id']],
          );
          raised++;
        }
      }

      // Price history is the one thing nothing can reconstruct, so every point
      // the other device recorded is kept. A day this phone already has is left
      // exactly as it is.
      //
      // What is missing is worked out by reading the stored keys first rather
      // than by counting insert return values: price_history is a WITHOUT ROWID
      // table, and sqflite reports 0 for every insert into one of those whether
      // it stored the row or not. That difference is a merge which says it added
      // eight hundred price points against one which added them and said
      // nothing.
      history += await _addMissing(
        txn,
        'price_history',
        archive.tables['price_history'] ?? const <Map<String, Object?>>[],
      );
      snapshots += await _addMissing(
        txn,
        'portfolio_snapshots',
        archive.tables['portfolio_snapshots'] ?? const <Map<String, Object?>>[],
      );
    });

    return MergeReport(
      addedRows: added,
      raisedRows: raised,
      pricePoints: history,
      snapshots: snapshots,
    );
  }

  /// Inserts the rows of [table] whose identity is not already stored, and
  /// answers how many that was.
  ///
  /// Rows that are already there are left exactly as they are, which for a
  /// price point means the day this phone recorded keeps the price this phone
  /// recorded rather than the other device's version of it.
  static Future<int> _addMissing(
    DatabaseExecutor txn,
    String table,
    List<Map<String, Object?>> incoming,
  ) async {
    if (incoming.isEmpty) return 0;
    final Set<String> stored = <String>{
      for (final Map<String, Object?> row in await txn.query(table))
        rowKeyOf(table, row),
    };
    var added = 0;
    for (final Map<String, Object?> row in incoming) {
      final String key = rowKeyOf(table, row);
      if (stored.contains(key)) continue;
      await txn.insert(table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
      stored.add(key);
      added++;
    }
    return added;
  }

  static int _quantityIn(Map<String, Object?> row) {
    final Object? value = row['quantity'];
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? 1;
  }
}
