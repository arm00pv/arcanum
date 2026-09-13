import 'dart:convert';
import 'dart:io';

/// One backup of everything the collector created, as a single JSON document.
///
/// What is in it, and what deliberately is not, is the whole design:
///
/// **The collection and its history are in.** Entries, purchase prices,
/// binders, notes, price alerts, portfolio snapshots, the wants list and the
/// daily price snapshots Arcanum recorded itself. Those exist nowhere else - the companion
/// serves prices, not holdings - so losing them loses the collection.
///
/// **The catalogue is not.** Sets and cards are megabytes of re-downloadable
/// data, and the same decision applies to price rows that came from a provider:
/// they can be fetched again, and including them would turn a small archive
/// into a large one that is mostly cache.
///
/// **Secrets are not.** The JustTCG key and the backup token are credentials
/// for third-party services, and a backup that quietly carries them turns every
/// copy of that file into a copy of the credentials. A restore asks for them
/// again instead.
class BackupArchive {
  BackupArchive({
    required this.created,
    required this.appVersion,
    required this.tables,
    required this.settings,
  });

  /// Identifies the format so a file that is not one of ours is refused.
  static const format = 'arcanum-backup';

  /// Bumped when the shape changes in a way an older app cannot read.
  static const version = 1;

  /// The rows that hold the collector's own data, by table name.
  ///
  /// Only these are written and only these are replaced on restore; the
  /// catalogue and any price row a provider supplied are left alone. The order
  /// matters on restore, not on backup.
  static const userTables = <String>[
    'collection_entries',
    'wanted_cards',
    'alerts',
    'portfolio_snapshots',
    'price_history',
    'meta',
  ];

  /// Price rows the app recorded itself, which are the ones worth keeping.
  ///
  /// Everything else in that table arrived from a provider and can be fetched
  /// again, so only these sources are exported.
  static const ownHistorySources = <String>['snapshot', 'manual'];

  /// Preference keys carried across a restore.
  ///
  /// The two endpoints are how the app talks to the collector's own companion;
  /// losing them on a new phone would silently move the app back to the hosted
  /// default and hide the fact that history had stopped arriving. Credentials
  /// are not here - see the class doc.
  static const carriedPreferences = <String>[
    'history_endpoint',
    'pokemon_history_endpoint',
    'backup_endpoint',
    'currency',
    'theme_mode',
    'condition_adjust',
    'auto_snapshot',
  ];

  final DateTime created;
  final String appVersion;

  /// Row lists keyed by table name.
  final Map<String, List<Map<String, Object?>>> tables;

  /// Preference keys and their stored values.
  final Map<String, Object?> settings;

  /// How many rows of each table the archive holds.
  Map<String, int> get counts => {
    for (final entry in tables.entries) entry.key: entry.value.length,
  };

  int get totalRows =>
      tables.values.fold<int>(0, (sum, rows) => sum + rows.length);

  Map<String, Object?> toJson() => <String, Object?>{
    'format': format,
    'version': version,
    'created': created.toUtc().toIso8601String(),
    'app': appVersion,
    'counts': counts,
    'tables': tables,
    'settings': settings,
  };

  /// Reads an archive, or explains why the document is not one.
  ///
  /// Never partially accepts: a file that is not an Arcanum backup, or one
  /// written by a newer app, is refused outright rather than half-applied to a
  /// collection that cannot be un-restored.
  static BackupArchive fromJson(Object? raw) {
    if (raw is! Map) {
      throw const BackupFormatException('That file is not an Arcanum backup.');
    }
    if (raw['format'] != format) {
      throw const BackupFormatException('That file is not an Arcanum backup.');
    }
    final int fileVersion = (raw['version'] as num?)?.toInt() ?? 0;
    if (fileVersion > version) {
      throw BackupFormatException(
        'That backup was written by a newer version of Arcanum '
        '(format $fileVersion, this app reads $version).',
      );
    }
    final rawTables = raw['tables'];
    if (rawTables is! Map) {
      throw const BackupFormatException('That backup holds no data.');
    }

    final tables = <String, List<Map<String, Object?>>>{};
    for (final name in userTables) {
      final rows = rawTables[name];
      if (rows == null) continue;
      if (rows is! List) {
        throw BackupFormatException(
          'That backup has an unreadable "$name" section.',
        );
      }
      tables[name] = <Map<String, Object?>>[
        for (final row in rows)
          if (row is Map) row.map((k, v) => MapEntry(k.toString(), v)),
      ];
    }

    final rawSettings = raw['settings'];
    final settings = <String, Object?>{
      if (rawSettings is Map)
        for (final entry in rawSettings.entries)
          entry.key.toString(): entry.value,
    };

    final created = DateTime.tryParse(raw['created']?.toString() ?? '')
        ?.toUtc();

    return BackupArchive(
      created: created ?? DateTime.now().toUtc(),
      appVersion: raw['app']?.toString() ?? 'unknown',
      tables: tables,
      settings: settings,
    );
  }

  /// The archive as the bytes that travel: gzipped JSON.
  List<int> encode() => gzip.encode(utf8.encode(jsonEncode(toJson())));

  /// Reads the bytes that arrive back.
  static BackupArchive decode(List<int> bytes) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(gzip.decode(bytes)));
    } on Object catch (error) {
      throw BackupFormatException('That backup could not be read ($error).');
    }
    return fromJson(decoded);
  }
}

/// A backup that is not one, or not one this app can read.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}
