import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'package:arcanum/data/api/scryfall_client.dart';
import 'package:arcanum/domain/decks/deck_format.dart';

/// A format's banned list, and when it was taken.
class BanList {
  const BanList({required this.names, required this.fetchedAt});

  /// Banned card names. The list is by name, not by printing: a banning hits
  /// every version of the card, which is exactly how the format works.
  final Set<String> names;

  final DateTime? fetchedAt;

  bool get isEmpty => names.isEmpty;
}

/// Fetches and caches the banned lists Arcanum can check.
///
/// Scryfall can answer "what is banned in Commander" directly, and the answer
/// changes a few times a year, so it is fetched once and kept in the database
/// rather than shipped in the build: a list baked into an APK is wrong the
/// first time a card is banned and cannot be corrected without a release.
///
/// Only Magic is covered, because it is the only one of the four games with a
/// machine-readable list. The others say so rather than pretending.
class BanListService {
  BanListService({required Database db, ScryfallClient? client})
    : _db = db,
      _client = client ?? ScryfallClient();

  final Database _db;
  final ScryfallClient _client;

  /// How long a cached list is trusted before it is worth fetching again.
  static const maxAge = Duration(days: 7);

  static String _key(String formatId) => 'banlist:$formatId';

  /// The stored list, or null when this format's has never been fetched.
  Future<BanList?> cached(DeckFormat format) async {
    if (!format.checksBanList) return null;
    final rows = await _db.query(
      'meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[_key(format.id)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decode(rows.first['value'] as String?);
  }

  /// The stored list when it is fresh enough, otherwise a fetch.
  ///
  /// A fetch that fails does not clear a stored list: a stale ban list is worth
  /// far more than none, and a phone with no signal should still be able to
  /// tell its owner that a card is banned.
  Future<BanList?> get(DeckFormat format, {bool forceRefresh = false}) async {
    final stored = await cached(format);
    if (!forceRefresh &&
        stored != null &&
        stored.fetchedAt != null &&
        DateTime.now().difference(stored.fetchedAt!) < maxAge) {
      return stored;
    }
    try {
      final fresh = await fetch(format);
      return fresh ?? stored;
    } catch (_) {
      return stored;
    }
  }

  /// Asks Scryfall for the format's banned cards.
  Future<BanList?> fetch(DeckFormat format) async {
    final query = format.banListQuery;
    if (query == null) return null;

    final names = <String>{};
    await for (final page in _client.searchAllPages(query, maxPages: 4)) {
      for (final card in page.cards) {
        names.add(card.name);
        // A modal or split card is banned as a whole, and Scryfall lists it
        // under its full name; the front face is what a deck list carries.
        final front = card.name.split(' // ').first;
        if (front != card.name) names.add(front);
      }
    }
    if (names.isEmpty) return null;

    final list = BanList(names: names, fetchedAt: DateTime.now());
    await _db.insert('meta', <String, Object?>{
      'key': _key(format.id),
      'value': jsonEncode(<String, Object?>{
        'fetchedAt': list.fetchedAt!.toIso8601String(),
        'names': names.toList()..sort(),
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return list;
  }

  static BanList? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final names = (json['names'] as List?)?.whereType<String>().toSet();
      if (names == null || names.isEmpty) return null;
      return BanList(
        names: names,
        fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? ''),
      );
    } catch (_) {
      return null;
    }
  }
}
