import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/backup/backup_archive.dart';
import 'package:arcanum/data/db/app_database.dart';

/// What the companion says about the backups it holds.
class BackupStatus {
  const BackupStatus({
    required this.enabled,
    required this.count,
    required this.latest,
    required this.bytes,
  });

  /// False when the server has no token file, which is its safe default: the
  /// read-only routes keep working and nothing can be written at all.
  final bool enabled;
  final int count;
  final DateTime? latest;
  final int bytes;

  static const unknown = BackupStatus(
    enabled: false,
    count: 0,
    latest: null,
    bytes: 0,
  );

  static BackupStatus fromJson(Object? raw) {
    if (raw is! Map) return unknown;
    return BackupStatus(
      enabled: raw['enabled'] == true,
      count: (raw['backups'] as num?)?.toInt() ?? 0,
      latest: DateTime.tryParse(raw['latest']?.toString() ?? '')?.toLocal(),
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
    );
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
  BackupService({required AppDatabase database, required AppSettings settings, Dio? dio})
      : _db = database.db,
        _settings = settings,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 60),
            ));

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
    );
  }

  /// Uploads one archive to the collector's companion.
  Future<BackupUpload> upload(
    BackupArchive archive, {
    String deviceLabel = '',
  }) async {
    final bytes = archive.encode();
    final res = await _dio.post<dynamic>(
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
    );
    final body = res.data is String ? jsonDecode(res.data as String) : res.data;
    final kept = body is Map ? (body['kept'] as num?)?.toInt() ?? 0 : 0;
    _settings.lastBackupAt = DateTime.now();
    return BackupUpload(bytes: bytes.length, kept: kept);
  }

  /// What the companion currently holds.
  Future<BackupStatus> status() async {
    try {
      final res = await _dio.get<dynamic>(
        '$_root/v1/backup/status',
        options: Options(headers: _authHeaders),
      );
      return BackupStatus.fromJson(res.data);
    } on DioException {
      return BackupStatus.unknown;
    }
  }

  /// Downloads the newest archive without applying it, so the collector can be
  /// told what is in it before anything changes on the phone.
  Future<BackupArchive> downloadLatest() async {
    final res = await _dio.get<List<int>>(
      '$_root/v1/backup/latest',
      options: Options(
        headers: _authHeaders,
        responseType: ResponseType.bytes,
      ),
    );
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw const BackupFormatException('The server sent no backup.');
    }
    return BackupArchive.decode(data);
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
          batch.insert(table, row, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await batch.commit(noResult: true);
      }
    });

    for (final entry in archive.settings.entries) {
      await _settings.writeRawPreference(entry.key, entry.value);
    }
  }
}
