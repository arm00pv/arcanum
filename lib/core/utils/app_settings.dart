import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// User preferences, backed by SharedPreferences.
///
/// Kept deliberately small and synchronous to read: the values are loaded once
/// during bootstrap and then held in memory.
///
/// Anything that belongs to a single game is namespaced by that game's id, so
/// switching games never leaks one game's settings into the other.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static const _kThemeMode = 'theme_mode';
  static const _kCurrency = 'currency';
  static const _kHistoryEndpoint = 'history_endpoint';
  static const _kPokemonHistoryEndpoint = 'pokemon_history_endpoint';
  static const _kJustTcgKey = 'justtcg_key';
  static const _kAutoSnapshot = 'auto_snapshot';
  static const _kConditionAdjust = 'condition_adjust';
  static const _kActiveGame = 'active_game';
  static const _kOnboarded = 'onboarded';
  static const _kLastSnapshotPrefix = 'last_snapshot_';

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

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

  String get justTcgKey => _prefs.getString(_kJustTcgKey) ?? '';

  set justTcgKey(String v) {
    _prefs.setString(_kJustTcgKey, v.trim());
    notifyListeners();
  }

  /// Whether to record a daily price snapshot when the app opens.
  bool get autoSnapshot => _prefs.getBool(_kAutoSnapshot) ?? true;

  set autoSnapshot(bool v) {
    _prefs.setBool(_kAutoSnapshot, v);
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
  /// screen uses it to tell the user whether trends have a source. Yu-Gi-Oh! has
  /// no provider at all - neither JustTCG nor either self-hosted endpoint
  /// carries it - so a key left over from another game must not make the app
  /// claim one is configured.
  bool hasHistoryProvider(CardGame game) {
    if (game == CardGame.yugioh) return false;
    if (justTcgKey.isNotEmpty) return true;
    if (game == CardGame.mtg) return historyEndpoint.isNotEmpty;
    return pokemonHistoryEndpoint.isNotEmpty;
  }
}
