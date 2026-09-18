import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/data/backup/backup_schedule.dart';
import 'package:arcanum/data/security/secret_store.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// User preferences, backed by SharedPreferences.
///
/// Kept deliberately small and synchronous to read: the values are loaded once
/// during bootstrap and then held in memory.
///
/// Anything that belongs to a single game is namespaced by that game's id, so
/// switching games never leaks one game's settings into the other.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs, this._secrets);

  final SharedPreferences _prefs;

  /// Where the two credentials live: the phone's keystore, not the preferences.
  final SecretStore _secrets;

  /// The credentials themselves, held in memory so the getters stay synchronous.
  final Map<String, String> _secretValues = <String, String>{};

  /// True when the keystore refused to store a credential and it had to be kept
  /// in the plain preferences file instead. Settings says so rather than
  /// implying a protection the phone did not give.
  bool _secretFallback = false;

  /// Whether a credential had to be kept outside the keystore.
  bool get secretStorageDegraded => _secretFallback;

  /// The credentials Arcanum holds, and the preference key each one used to live
  /// under. The names are the store's, not the preferences': a keystore entry
  /// outlives the setting it belongs to.
  static const _secretKeys = <String, String>{
    'backup_token': _kBackupToken,
    'justtcg_key': _kJustTcgKey,
  };

  static const _kThemeMode = 'theme_mode';
  static const _kCurrency = 'currency';
  static const _kHistoryEndpoint = 'history_endpoint';
  static const _kPokemonHistoryEndpoint = 'pokemon_history_endpoint';
  static const _kJustTcgKey = 'justtcg_key';
  static const _kAutoSnapshot = 'auto_snapshot';
  static const _kServerCatalog = 'server_catalog';
  static const _kConditionAdjust = 'condition_adjust';
  static const _kActiveGame = 'active_game';
  static const _kOnboarded = 'onboarded';
  static const _kLastSnapshotPrefix = 'last_snapshot_';

  /// One stored preference by its raw key, for the backup service.
  ///
  /// A backup carries a short named list of preferences - endpoints and display
  /// choices, never credentials - so it reads and writes them by key rather
  /// than growing a getter and setter pair per field on this class.
  Object? rawPreference(String key) => _prefs.get(key);

  /// Writes one preference back, preserving its type.
  Future<void> writeRawPreference(String key, Object? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else if (value is bool) {
      await _prefs.setBool(key, value);
    } else if (value is int) {
      await _prefs.setInt(key, value);
    } else if (value is double) {
      await _prefs.setDouble(key, value);
    } else {
      await _prefs.setString(key, value.toString());
    }
    notifyListeners();
  }

  static const _kBackupEndpoint = 'backup_endpoint';
  static const _kBackupToken = 'backup_token';
  static const _kLockEnabled = 'lock_enabled';
  static const _kDeviceLabel = 'device_label';
  static const _kLastBackupAt = 'last_backup_at';
  static const _kAutoBackupCadence = 'auto_backup_cadence';
  static const _kLastAutoBackupAt = 'last_auto_backup_at';
  static const _kLastAutoBackupOk = 'last_auto_backup_ok';
  static const _kLastAutoBackupNote = 'last_auto_backup_note';

  /// Reads the preferences and the keystore.
  ///
  /// [secrets] exists for tests and for the background isolate; the app itself
  /// takes the real keystore.
  static Future<AppSettings> load({SecretStore? secrets}) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings._(
      prefs,
      secrets ?? const KeystoreSecretStore(),
    );
    await settings._adoptSecrets();
    return settings;
  }

  /// Moves the credentials into the keystore, for installs that had them in the
  /// preferences file.
  ///
  /// Runs on every load and is idempotent: a value already in the keystore wins,
  /// and only a value that is genuinely absent there is taken from the
  /// preferences - and then deleted from them. A store that throws is not fatal:
  /// the value stays where it was, the app keeps working, and
  /// [secretStorageDegraded] records that the protection was not available.
  Future<void> _adoptSecrets() async {
    for (final MapEntry<String, String> entry in _secretKeys.entries) {
      try {
        final String? stored = await _secrets.read(entry.key);
        if (stored != null && stored.isNotEmpty) {
          _secretValues[entry.key] = stored;
          // A copy left in the preferences by an older build is removed, because
          // keeping it would defeat the point of the move.
          if (_prefs.containsKey(entry.value)) {
            await _prefs.remove(entry.value);
          }
          continue;
        }
        final String? legacy = _prefs.getString(entry.value);
        if (legacy == null || legacy.isEmpty) continue;
        await _secrets.write(entry.key, legacy);
        _secretValues[entry.key] = legacy;
        await _prefs.remove(entry.value);
      } catch (_) {
        _secretFallback = true;
        final String? legacy = _prefs.getString(entry.value);
        if (legacy != null && legacy.isNotEmpty) {
          _secretValues[entry.key] = legacy;
        }
      }
    }
  }

  /// Writes one credential where it belongs, falling back loudly.
  Future<void> _storeSecret(String key, String value) async {
    _secretValues[key] = value;
    final String preferenceKey = _secretKeys[key]!;
    try {
      if (value.isEmpty) {
        await _secrets.delete(key);
      } else {
        await _secrets.write(key, value);
      }
      if (_prefs.containsKey(preferenceKey)) {
        await _prefs.remove(preferenceKey);
      }
    } catch (_) {
      // The phone would not take it. Keeping it in the preferences is worse than
      // the keystore and much better than losing the collector's token, and
      // Settings says which of the two happened.
      _secretFallback = true;
      await _prefs.setString(preferenceKey, value);
    }
  }

  // ------------------------------------------------------------------ theme

  /// The user's theme choice. Defaults to dark, which is the app's native
  /// presentation.
  ThemeMode get themeMode {
    switch (_prefs.getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }

  set themeMode(ThemeMode m) {
    _prefs.setString(_kThemeMode, m.name);
    notifyListeners();
  }

  // ------------------------------------------------------------------- game

  /// Which game the app is currently showing.
  ///
  /// Every catalogue, collection, portfolio and price series in the UI is scoped
  /// to this value; switching it swaps the entire app over.
  CardGame get activeGame => CardGame.fromId(_prefs.getString(_kActiveGame));

  set activeGame(CardGame game) {
    if (activeGame == game) return;
    _prefs.setString(_kActiveGame, game.id);
    notifyListeners();
  }

  /// Games the user has opened at least once, most recent first.
  ///
  /// Used to order the game switcher so the common case is one tap.
  List<CardGame> get recentGames {
    final raw = _prefs.getStringList('recent_games') ?? const <String>[];
    final games = raw.map(CardGame.fromId).toList();
    if (!games.contains(activeGame)) games.insert(0, activeGame);
    for (final g in CardGame.values) {
      if (!games.contains(g)) games.add(g);
    }
    return games;
  }

  /// Records that a game was opened, for the switcher's ordering.
  void noteGameOpened(CardGame game) {
    final raw = _prefs.getStringList('recent_games') ?? <String>[];
    raw.remove(game.id);
    raw.insert(0, game.id);
    _prefs.setStringList('recent_games', raw.take(8).toList());
    notifyListeners();
  }

  // --------------------------------------------------------------- pricing

  /// Display currency. Prices arrive in USD; this only affects presentation.
  String get currency => _prefs.getString(_kCurrency) ?? 'USD';

  set currency(String v) {
    _prefs.setString(_kCurrency, v);
    notifyListeners();
  }

  /// Base URL of the Arcanum Sync companion serving price history.
  ///
  /// The companion is hosted behind TLS and answers from any network, so trends
  /// work away from home rather than only on the private tailnet. It is still
  /// only a convenience: the app is fully functional without it, because
  /// MTGStocks and TCGdex answer directly and the app records its own daily
  /// snapshots regardless.
  static const defaultHistoryEndpoint = 'https://zapp.sytes.net/arcanum';

  /// The endpoint earlier builds shipped with, kept so that installs which
  /// never changed it are moved onto the hosted one instead of being left
  /// pointing at a desktop that is usually asleep.
  static const legacyHistoryEndpoint = 'http://100.90.30.95:8787';

  String get historyEndpoint {
    final String? stored = _prefs.getString(_kHistoryEndpoint)?.trim();
    if (stored == null || stored.isEmpty) return defaultHistoryEndpoint;
    // Only the value Arcanum itself shipped is migrated. Anything typed by hand
    // is the collector's own service and is never rewritten.
    if (stored == legacyHistoryEndpoint) return defaultHistoryEndpoint;
    return stored;
  }

  set historyEndpoint(String v) {
    _prefs.setString(_kHistoryEndpoint, v.trim());
    notifyListeners();
  }

  /// Base URL of the companion serving Pokémon price history.
  ///
  /// Defaults to the same service as Magic: one companion holds both databases
  /// and works out which to consult from the id alone, so asking it for a
  /// Pokémon printing is the same request as asking it for a Magic one.
  static const defaultPokemonHistoryEndpoint = defaultHistoryEndpoint;

  String get pokemonHistoryEndpoint {
    final String stored =
        _prefs.getString(_kPokemonHistoryEndpoint)?.trim() ?? '';
    return stored.isEmpty ? defaultPokemonHistoryEndpoint : stored;
  }

  set pokemonHistoryEndpoint(String v) {
    _prefs.setString(_kPokemonHistoryEndpoint, v.trim());
    notifyListeners();
  }

  /// Where backups are pushed, and the token that authorises it.
  ///
  /// A dedicated endpoint rather than reusing a history one: history is open
  /// and read-only, while the backup route is the only thing on the companion
  /// that writes, and it is the only one that needs a secret. Pointing one at
  /// the other would conflate two very different trust levels.
  static const defaultBackupEndpoint = defaultHistoryEndpoint;

  String get backupEndpoint {
    final String stored = _prefs.getString(_kBackupEndpoint)?.trim() ?? '';
    return stored.isEmpty ? defaultBackupEndpoint : stored;
  }

  set backupEndpoint(String v) {
    _prefs.setString(_kBackupEndpoint, v.trim());
    notifyListeners();
  }

  /// The shared secret the companion's backup routes require.
  ///
  /// Empty means the app never tries to write, which is also what the server
  /// does when it has no token file of its own: both ends default to refusing
  /// rather than to an unauthenticated write path.
  String get backupToken => _secretValues['backup_token'] ?? '';

  set backupToken(String v) {
    unawaited(_storeSecret('backup_token', v.trim()));
    notifyListeners();
  }

  /// When a backup was last uploaded, so Settings can say how stale it is.
  DateTime? get lastBackupAt {
    final ms = _prefs.getInt(_kLastBackupAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  set lastBackupAt(DateTime? d) {
    if (d == null) {
      _prefs.remove(_kLastBackupAt);
    } else {
      _prefs.setInt(_kLastBackupAt, d.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  // ------------------------------------------------- automatic backup

  /// How often the app backs itself up on its own.
  ///
  /// Off until the collector asks for it: an app that starts uploading to a
  /// server without being told to is an app that has decided something on the
  /// collector's behalf.
  BackupCadence get backupCadence =>
      BackupCadence.fromCode(_prefs.getString(_kAutoBackupCadence));

  set backupCadence(BackupCadence cadence) {
    _prefs.setString(_kAutoBackupCadence, cadence.code);
    notifyListeners();
  }

  /// When the automatic backup last ran, whether it succeeded or not.
  DateTime? get lastAutoBackupAt {
    final ms = _prefs.getInt(_kLastAutoBackupAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// True when that run uploaded, false when it failed, null when it has never
  /// run. Three states rather than two, because "never tried" and "tried and
  /// failed" want different sentences in Settings.
  bool? get lastAutoBackupOk {
    final v = _prefs.getBool(_kLastAutoBackupOk);
    return _prefs.containsKey(_kLastAutoBackupAt) ? (v ?? false) : null;
  }

  /// Why the last run failed, for a sentence the collector can act on.
  String get lastAutoBackupNote => _prefs.getString(_kLastAutoBackupNote) ?? '';

  /// Records the outcome of one automatic run.
  ///
  /// Written from the background isolate, which has its own copy of the
  /// preferences; the app re-reads them on resume so the two do not drift.
  void recordAutoBackup({required bool ok, String note = '', DateTime? at}) {
    _prefs.setInt(
      _kLastAutoBackupAt,
      (at ?? DateTime.now()).millisecondsSinceEpoch,
    );
    _prefs.setBool(_kLastAutoBackupOk, ok);
    if (note.isEmpty) {
      _prefs.remove(_kLastAutoBackupNote);
    } else {
      _prefs.setString(_kLastAutoBackupNote, note);
    }
  }

  /// Re-reads the preferences from disk.
  ///
  /// SharedPreferences caches per isolate, so anything the background backup
  /// wrote is invisible to a running app until this is called.
  Future<void> reload() async {
    await _prefs.reload();
    notifyListeners();
  }

  String get justTcgKey => _secretValues['justtcg_key'] ?? '';

  set justTcgKey(String v) {
    unawaited(_storeSecret('justtcg_key', v.trim()));
    notifyListeners();
  }

  // --------------------------------------------------------------- security

  /// Whether Arcanum asks for the device's own authentication when it opens.
  ///
  /// Off by default: this is a collection and a price list, and an app that
  /// locks itself the first time it is opened is an app that gets deleted.
  /// Turning it on requires one successful authentication, so it can never be
  /// switched on for a phone whose owner could not then get back in.
  bool get lockEnabled => _prefs.getBool(_kLockEnabled) ?? false;

  set lockEnabled(bool v) {
    _prefs.setBool(_kLockEnabled, v);
    notifyListeners();
  }

  /// What this device calls itself in a backup's filename.
  ///
  /// Two devices uploading under the same name is the one thing that makes a
  /// second phone invisible: the server would keep both archives and the app
  /// could not tell which of them was its own. The default is generated once,
  /// from the clock and a random draw, and stays put afterwards.
  String get deviceLabel {
    final String stored = (_prefs.getString(_kDeviceLabel) ?? '').trim();
    if (stored.isNotEmpty) return stored;
    final int seed = DateTime.now().microsecondsSinceEpoch;
    final String tail = '${seed.toRadixString(36)}0000'.substring(0, 4);
    final String generated = 'arcanum-$tail';
    _prefs.setString(_kDeviceLabel, generated);
    return generated;
  }

  set deviceLabel(String v) {
    final String clean = v.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
    _prefs.setString(_kDeviceLabel, clean.isEmpty ? 'arcanum' : clean);
    notifyListeners();
  }

  /// Whether to record a daily price snapshot when the app opens.
  bool get autoSnapshot => _prefs.getBool(_kAutoSnapshot) ?? true;

  set autoSnapshot(bool v) {
    _prefs.setBool(_kAutoSnapshot, v);
    notifyListeners();
  }

  /// Whether this build reads the card catalogue from Arcanum's own server
  /// rather than from the card providers.
  ///
  /// Off until it is asked for, and only ever asked for in a browser: the
  /// switch that writes it is not drawn anywhere else, because a phone has no
  /// account to read the catalogue through and has to work with the radio off.
  /// It is the rollback for the whole migration - a browser that turns it off
  /// is back on the provider path without a release.
  bool get serverCatalog => _prefs.getBool(_kServerCatalog) ?? false;

  set serverCatalog(bool v) {
    _prefs.setBool(_kServerCatalog, v);
    notifyListeners();
  }

  /// Apply condition-based discounts when valuing a collection.
  bool get conditionAdjust => _prefs.getBool(_kConditionAdjust) ?? true;

  set conditionAdjust(bool v) {
    _prefs.setBool(_kConditionAdjust, v);
    notifyListeners();
  }

  /// When this game's prices were last snapshotted.
  DateTime? lastSnapshotFor(CardGame game) {
    final ms = _prefs.getInt('$_kLastSnapshotPrefix${game.id}');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Records that a snapshot was taken for a game.
  void setLastSnapshot(CardGame game, DateTime? d) {
    final key = '$_kLastSnapshotPrefix${game.id}';
    if (d == null) {
      _prefs.remove(key);
    } else {
      _prefs.setInt(key, d.millisecondsSinceEpoch);
    }
    notifyListeners();
  }

  bool get onboarded => _prefs.getBool(_kOnboarded) ?? false;

  set onboarded(bool v) {
    _prefs.setBool(_kOnboarded, v);
    notifyListeners();
  }

  /// True when at least one provider serves this game.
  ///
  /// Must agree with [PriceHistoryService.providersFor], because the settings
  /// screen uses it to tell the user whether trends have a source. Every game
  /// is served by the companion now - Magic from the MTGJSON slice and the
  /// other three from their daily samplers - so the question is only whether
  /// that companion is configured at all.
  bool hasHistoryProvider(CardGame game) {
    if (justTcgKey.isNotEmpty) return true;
    if (game == CardGame.mtg) return historyEndpoint.isNotEmpty;
    return pokemonHistoryEndpoint.isNotEmpty;
  }
}
