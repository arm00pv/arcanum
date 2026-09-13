/// How often Arcanum backs itself up without being asked.
///
/// The cadences are coarse on purpose. A collection changes when a card is
/// scanned or a delivery arrives, which is a handful of times a week, and a
/// backup every hour would be the same twenty-eight kilobytes uploaded
/// twenty-four times a day to a machine in the collector's spare room.
enum BackupCadence {
  off('off', 'Off', Duration.zero),
  daily('daily', 'Every day', Duration(hours: 24)),
  threeDays('three_days', 'Every three days', Duration(hours: 72)),
  weekly('weekly', 'Every week', Duration(days: 7));

  const BackupCadence(this.code, this.label, this.every);

  /// Stable code stored in preferences.
  final String code;

  /// What the collector sees.
  final String label;

  /// The gap between runs.
  final Duration every;

  /// True when the app should schedule anything at all.
  bool get isOn => this != BackupCadence.off;

  static BackupCadence fromCode(String? code) {
    for (final cadence in BackupCadence.values) {
      if (cadence.code == code) return cadence;
    }
    return BackupCadence.off;
  }
}

/// How late a backup has to be before the app runs one itself.
///
/// Without a grace period a daily backup would run on every single launch: the
/// scheduler fires at some unpredictable hour, so the gap between two runs is
/// never exactly twenty-four hours and a strict comparison would be true for
/// most of the day.
const Duration kBackupGrace = Duration(hours: 3);

/// True when the last backup is old enough to be worth replacing.
///
/// A collection that has never been backed up is always due. This drives the
/// catch-up run on launch, which is what actually keeps the promise when
/// Android has deferred the scheduled work - Doze, battery saver and a phone
/// that has not been unlocked in a day all postpone it, and none of them tell
/// the app.
bool isBackupDue({
  required DateTime? last,
  required BackupCadence cadence,
  required DateTime now,
}) {
  if (!cadence.isOn) return false;
  if (last == null) return true;
  return now.difference(last) >= cadence.every + kBackupGrace;
}

/// When the next backup is expected, or null when none is scheduled.
///
/// A schedule that has never run is reported as due now rather than as a time
/// in the past, because "next backup: three days ago" is not a sentence.
DateTime? nextBackupAt({
  required DateTime? last,
  required BackupCadence cadence,
  required DateTime now,
}) {
  if (!cadence.isOn) return null;
  if (last == null) return now;
  final due = last.add(cadence.every);
  return due.isBefore(now) ? now : due;
}
