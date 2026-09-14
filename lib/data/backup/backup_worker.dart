import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:workmanager/workmanager.dart';

import 'package:arcanum/core/utils/app_settings.dart';
import 'package:arcanum/data/backup/backup_schedule.dart';
import 'package:arcanum/data/backup/backup_service.dart';
import 'package:arcanum/data/db/app_database.dart';

/// The name Android's scheduler knows the automatic backup by.
const String kAutoBackupTask = 'arcanumAutoBackup';

/// The entry point Android calls when a scheduled backup comes due.
///
/// This runs in an isolate of its own: no widget tree, no providers, nothing
/// already open. It therefore rebuilds the small amount it needs - preferences
/// and a read-only database handle - rather than reaching back into the app,
/// which is not running.
///
/// The entry point must stay a top-level function and must keep the
/// vm:entry-point pragma, or the tree shaker will remove the only thing the
/// background isolate ever calls.
@pragma('vm:entry-point')
void autoBackupCallbackDispatcher() {
  Workmanager().executeTask((String task, Map<String, dynamic>? input) async {
    if (task != kAutoBackupTask) return true;
    return runAutoBackup();
  });
}

/// Runs one automatic backup from the background isolate, and records how it
/// went.
///
/// Returns true when Android should consider the work done, and false only when
/// the companion could not be reached at all. That distinction is the whole
/// retry policy: a refused token or a missing server is a decision the collector
/// has to make and would be retried forever, while a connection that timed out
/// is worth trying again with a backoff.
Future<bool> runAutoBackup() async {
  final AppSettings settings;
  try {
    settings = await AppSettings.load();
  } catch (error) {
    debugPrint('[backup] no preferences in the background isolate: $error');
    return true;
  }

  if (!settings.backupCadence.isOn) return true;

  final AppDatabase database;
  try {
    database = await AppDatabase.openReadOnly();
  } catch (error) {
    // The database is created on first launch. A backup that fires before the
    // app has ever run has nothing to back up, which is not a failure.
    debugPrint('[backup] nothing to read yet: $error');
    settings.recordAutoBackup(
      ok: false,
      // The error goes in the note rather than only to a log nobody can read on
      // a release build: a scheduled backup that fails silently is the one
      // failure this feature exists to prevent.
      note: 'Could not read the collection database: $error',
    );
    return true;
  }

  try {
    return await runBackupWith(
      settings: settings,
      service: BackupService(database: database, settings: settings),
    );
  } finally {
    await database.close();
  }
}

/// Runs the catch-up backup when the last one is older than the cadence allows.
///
/// Android decides when scheduled work actually runs, and Doze, battery saver
/// and a phone left alone all push it back without saying so. This is the other
/// half of the promise: the first launch after a backup goes stale uploads one
/// then, using the connection the app already has open.
///
/// Returns true when a backup was actually attempted.
Future<bool> catchUpAutoBackup({
  required AppSettings settings,
  required BackupService service,
  DateTime? now,
}) async {
  final cadence = settings.backupCadence;
  if (!cadence.isOn) return false;
  if (!isBackupDue(
    last: settings.lastBackupAt,
    cadence: cadence,
    now: now ?? DateTime.now(),
  )) {
    return false;
  }
  await runBackupWith(settings: settings, service: service);
  return true;
}

/// Builds and uploads one archive, recording the outcome either way.
///
/// Shared by the scheduled run and the catch-up run so the two cannot drift
/// into reporting different things about the same failure.
Future<bool> runBackupWith({
  required AppSettings settings,
  required BackupService service,
}) async {
  if (!service.isConfigured) {
    settings.recordAutoBackup(
      ok: false,
      note: 'No backup server or token is set.',
    );
    return true;
  }

  try {
    final archive = await service.build(appVersion: await _appVersion());
    final result = await service.upload(
      archive,
      deviceLabel: settings.deviceLabel,
    );
    settings.recordAutoBackup(ok: true);
    debugPrint('[backup] uploaded ${result.bytes} bytes, ${result.kept} kept');
    return true;
  } on DioException catch (error) {
    // No response means the request never landed. A response - even a 401 -
    // is an answer, and repeating the question will not change it.
    final unreachable = error.response == null;
    settings.recordAutoBackup(
      ok: false,
      note: unreachable
          ? 'Could not reach the backup server.'
          : _explain(error.response?.statusCode),
    );
    debugPrint('[backup] automatic run failed: ${error.type} ${error.message}');
    return !unreachable;
  } catch (error) {
    settings.recordAutoBackup(ok: false, note: '$error');
    debugPrint('[backup] automatic run failed: $error');
    return true;
  }
}

/// What to tell the collector about a refusal.
///
/// The status code decides who has the problem. Blaming the token for a 500
/// sends them off to re-paste a secret that was never wrong.
String _explain(int? status) {
  if (status == null) return 'The backup server gave an odd answer.';
  if (status == 401 || status == 403) {
    return 'The server refused the backup ($status). Check the token.';
  }
  if (status == 503) {
    return 'The companion has backups switched off ($status) - it has no '
        'token file of its own.';
  }
  if (status >= 500) {
    return 'The backup server had a problem ($status). It will be tried '
        'again.';
  }
  return 'The server refused the backup ($status).';
}

/// The app's version, or an empty string when the platform will not say.
Future<String> _appVersion() async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return '';
  }
}
