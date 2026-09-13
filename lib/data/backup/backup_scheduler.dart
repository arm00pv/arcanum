import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'package:arcanum/data/backup/backup_schedule.dart';
import 'package:arcanum/data/backup/backup_worker.dart';

/// Keeps Android's background scheduler in step with the collector's choice.
///
/// Android, not the app, decides when the work actually runs. Doze, battery
/// saver, and a phone that has sat untouched for a day all push it back, and
/// none of them tell the app it happened - which is why the app also runs a
/// catch-up backup on launch. The two together are what make the promise hold:
/// the scheduler covers the phone that is never opened, and the catch-up covers
/// the scheduler being deferred.
abstract final class BackupScheduler {
  /// The name Android files the work under. One name, so changing the cadence
  /// replaces the schedule rather than stacking a second one behind it.
  static const String uniqueName = 'arcanum-auto-backup';

  /// True on the one platform this is written for.
  ///
  /// The plugin has desktop and web implementations, but Arcanum ships on
  /// Android and a schedule that cannot run is worse than an honest absence.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Prepares the plugin. Called once at startup, before anything is scheduled.
  static Future<void> start() async {
    if (!isSupported) return;
    try {
      await Workmanager().initialize(autoBackupCallbackDispatcher);
    } catch (error) {
      debugPrint('[backup] the scheduler would not start: $error');
    }
  }

  /// Registers, re-registers or cancels the periodic backup.
  ///
  /// Called at startup and whenever the cadence changes. Replacing rather than
  /// keeping matters: Android ignores a new frequency while an old request with
  /// the same name is pending, so a collector moving from weekly to daily would
  /// otherwise still be waiting a week.
  static Future<void> apply(BackupCadence cadence) async {
    if (!isSupported) return;
    try {
      if (!cadence.isOn) {
        await Workmanager().cancelByUniqueName(uniqueName);
        return;
      }
      await Workmanager().registerPeriodicTask(
        uniqueName,
        kAutoBackupTask,
        frequency: cadence.every,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
      );
    } catch (error) {
      debugPrint('[backup] could not schedule the automatic backup: $error');
    }
  }
}
