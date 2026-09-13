import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/db/history_dao.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/quant/quant.dart';

/// A provider of historical daily prices for a single printing.
///
/// Neither Scryfall nor the Pokémon TCG API publishes price history, so real
/// trend analysis needs one of these. Arcanum ships several and merges whatever
/// is available, in priority order.
abstract interface class PriceHistorySource {
  /// Stable identifier, also used as the `source` column value.
  String get id;

  /// Human readable name shown in Settings.
  String get label;

  /// Which games this provider can serve.
  Set<CardGame> get supportedGames;

  /// Whether the source is currently usable.
  bool get isConfigured;

  /// Fetches up to [days] of daily closes for one printing.
  ///
  /// [cardName] and [externalId] are optional hints for providers keyed by
  /// something other than the catalogue's own id.
  ///
  /// Implementations must never throw for a simple "no data" outcome; they
  /// return an empty list instead.
  Future<List<PricePoint>> fetch(
    String cardId, {
    required CardFinish finish,
    int days = 400,
    String? cardName,
    String? externalId,
  });
}

/// Normalises a HTTP body into a decoded JSON value.
///
/// Dio only auto-decodes when the server advertises a JSON content type, and
/// several of the sources here do not: GitHub serves the TCGdex price archive as
/// `text/plain`, so the body arrives as a raw [String]. Decoding defensively
/// means a change of content type can never silently produce an empty series.
Object? decodeJsonBody(Object? body) {
  if (body is String) {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
  return body;
}

/// Parses the compact wire format shared by Arcanum Sync and the app's exporter.
///
/// ```json
/// { "id": "<cardId>", "updated": "2026-09-11",
///   "series": { "nonfoil": [[1780358400, 1.23], ...], "foil": [...] } }
/// ```
List<PricePoint> parseHistoryPack(
  Object? body, {
  required CardFinish finish,
  required int days,
}) {
  if (body is! Map) return const [];
  final series = body['series'];
  if (series is! Map) return const [];
  final key = finish.code;
  final raw = series[key] ??
      (finish != CardFinish.nonfoil ? series['foil'] : null) ??
      series['nonfoil'];
  if (raw is! List) return const [];

  final cutoff = DateTime.now().subtract(Duration(days: days));
  final points = <PricePoint>[];
  for (final item in raw) {
    double? price;
    DateTime? date;
    if (item is List && item.length >= 2) {
      final t = item[0];
      final p = item[1];
      if (t is num) {
        date = DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true).toLocal();
      }
      if (t is String) date = DateTime.tryParse(t);
      if (p is num) price = p.toDouble();
    } else if (item is Map) {
      final t = item['t'] ?? item['date'];
      final p = item['p'] ?? item['price'];
      if (t is num) {
        date = DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true).toLocal();
      }
      if (t is String) date = DateTime.tryParse(t);
      if (p is num) price = p.toDouble();
    }
    if (date == null || price == null || price <= 0) continue;
    if (date.isBefore(cutoff)) continue;
    points.add(PricePoint(DateTime(date.year, date.month, date.day), price));
  }
  points.sort((a, b) => a.date.compareTo(b.date));
  return points;
}

/// A backfill pack served by the optional Arcanum Sync companion service.
class BackfillPackSource implements PriceHistorySource {
  BackfillPackSource({
    required this.baseUrl,
    this.serveGame = CardGame.mtg,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 12),
              headers: const {'Accept': 'application/json'},
            ));

  /// Root of the companion service, e.g. `http://100.90.30.95:8787`.
  final String baseUrl;

  /// Which game this instance serves.
  final CardGame serveGame;
  final Dio _dio;

  /// The label these points are stored under.
  ///
  /// Magic keeps `backfill` because its database is rebuilt from MTGJSON and
  /// that is what every stored Magic row already says. Everything else is
  /// served by a daily sampler, and since the companion now samples four games
  /// rather than one, the label names the source rather than a game that is no
  /// longer the only one using it. `pokemon_backfill` stays in the history
  /// DAO's priority list so rows written before this still merge correctly.
  @override
  String get id => serveGame == CardGame.mtg ? 'backfill' : 'companion';

  @override
  String get label => 'Arcanum Sync (${serveGame.shortLabel})';

  @override
  Set<CardGame> get supportedGames => {serveGame};

  @override
  bool get isConfigured => baseUrl.trim().isNotEmpty;

  @override
  Future<List<PricePoint>> fetch(
    String cardId, {
    required CardFinish finish,
    int days = 400,
    String? cardName,
    String? externalId,
  }) async {
    if (!isConfigured) return const [];
    try {
      final res = await _dio.get<dynamic>(
        '${baseUrl.replaceAll(RegExp(r'/+\$'), '')}/v1/history/$cardId.json',
        options: Options(responseType: ResponseType.json),
      );
      return parseHistoryPack(
        decodeJsonBody(res.data),
        finish: finish,
        days: days,
      );
    } on DioException {
      // A missing pack is a normal outcome, not an error worth surfacing.
      return const [];
    } catch (_) {
      return const [];
    }
  }
}

/// MTGStocks — a free, keyless source of *deep* daily Magic price history.
///
/// Its undocumented JSON API is keyed by MTGStocks' own print id, so a Scryfall
/// id has to be resolved once through the name autocomplete and is then cached
/// forever in the local database. In exchange it offers daily series reaching
/// back to 2012 — an order of magnitude deeper than anything else freely
/// available — with separate non-foil and foil curves.
///
/// This endpoint is unofficial: it can change without notice, so callers must
/// treat an empty result as normal.
class MtgStocksHistorySource implements PriceHistorySource {
  MtgStocksHistorySource({required HistoryDao cache, Dio? dio})
      : _cache = cache,
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {
                'Accept': 'application/json',
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 17) AppleWebKit/537.36 Arcanum/1.0',
              },
            ));

  static const _base = 'https://api.mtgstocks.com';

  /// Upper bound on print lookups performed while resolving one card.
  static const _maxCandidates = 10;

  final HistoryDao _cache;
  final Dio _dio;

  @override
  String get id => 'mtgstocks';

  @override
  String get label => 'MTGStocks';

  @override
  Set<CardGame> get supportedGames => const {CardGame.mtg};

  @override
  bool get isConfigured => true;

  static String _cacheKey(String cardId) => 'mtgstocks_id:$cardId';

  /// Finds the MTGStocks print id whose `scryfallId` matches, caching both
  /// positive and negative answers so a miss is never retried.
  Future<int?> resolvePrintId(String scryfallId, String? cardName) async {
    final cached = await _cache.metaValue(_cacheKey(scryfallId));
    if (cached != null) {
      if (cached == 'none') return null;
      final parsed = int.tryParse(cached);
      if (parsed != null) return parsed;
    }
    final name = cardName?.trim();
    if (name == null || name.isEmpty) return null;

    // Double-faced cards are named "Front // Back"; MTGStocks indexes the front
    // face, so try both forms.
    final names = <String>{name};
    if (name.contains('//')) names.add(name.split('//').first.trim());

    final candidates = <int>[];
    for (final n in names) {
      try {
        final res = await _dio.get<dynamic>('/search/autocomplete/${Uri.encodeComponent(n)}');
        final data = decodeJsonBody(res.data);
        if (data is! List) continue;
        for (final item in data) {
          if (item is! Map) continue;
          if ((item['type']?.toString() ?? '') != 'print') continue;
          final id = item['id'];
          if (id is num) candidates.add(id.toInt());
        }
      } catch (_) {
        // Fall through to the next spelling.
      }
      if (candidates.isNotEmpty) break;
    }

    for (final id in candidates.take(_maxCandidates)) {
      try {
        final res = await _dio.get<dynamic>('/prints/$id');
        final data = decodeJsonBody(res.data);
        if (data is Map && data['scryfallId'] == scryfallId) {
          await _cache.setMetaValue(_cacheKey(scryfallId), '$id');
          return id;
        }
      } catch (_) {
        continue;
      }
    }
    await _cache.setMetaValue(_cacheKey(scryfallId), 'none');
    return null;
  }

  @override
  Future<List<PricePoint>> fetch(
    String cardId, {
    required CardFinish finish,
    int days = 400,
    String? cardName,
    String? externalId,
  }) async {
    try {
      final printId = await resolvePrintId(cardId, cardName);
      if (printId == null) return const [];
      final res = await _dio.get<dynamic>('/prints/$printId/prices');
      final data = decodeJsonBody(res.data);
      if (data is! Map) return const [];

      // `market` reflects completed sales and is the closest analogue to
      // Scryfall's `usd`; `avg` is the listing average and is used only as a
      // fallback for thinly traded cards.
      final keys = finish == CardFinish.nonfoil
          ? const ['market', 'avg']
          : const ['market_foil', 'foil'];

      for (final key in keys) {
        final raw = data[key];
        if (raw is! List || raw.isEmpty) continue;
        final cutoff = DateTime.now().subtract(Duration(days: days));
        final points = <PricePoint>[];
        for (final item in raw) {
          if (item is! List || item.length < 2) continue;
          final ms = item[0];
          final price = item[1];
          if (ms is! num || price is! num) continue;
          final p = price.toDouble();
          if (p <= 0) continue;
          final d = DateTime.fromMillisecondsSinceEpoch(ms.toInt()).toLocal();
          final day = DateTime(d.year, d.month, d.day);
          if (day.isBefore(cutoff)) continue;
          points.add(PricePoint(day, p));
        }
        if (points.length < 5) continue;
        points.sort((a, b) => a.date.compareTo(b.date));
        return points;
      }
      return const [];
    } catch (_) {
      // Unofficial endpoint: any failure is simply "no data available".
      return const [];
    }
  }
}

/// The community-published TCGdex price archive for Pokémon.
///
/// A free, keyless, MIT-licensed GitHub repository holding one JSON file per
/// card with a genuine daily series. It is a superb backfill source — roughly
/// two years of daily closes per card — but the scrape **stopped in September
/// 2024**, so it is a historical archive, not a live feed. Arcanum therefore
/// treats it as backfill only, and layers the user's own daily snapshots (plus
/// JustTCG when a key is supplied) on top for current data. The card detail
/// screen is explicit about this.
class TcgDexPriceHistorySource implements PriceHistorySource {
  TcgDexPriceHistorySource({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 25),
              headers: const {'Accept': 'application/json'},
            ));

  static const _base =
      'https://raw.githubusercontent.com/tcgdex/price-history/master/en';

  final Dio _dio;

  @override
  String get id => 'tcgdex_archive';

  @override
  String get label => 'TCGdex archive (to Sep 2024)';

  @override
  Set<CardGame> get supportedGames => const {CardGame.pokemon};

  @override
  bool get isConfigured => true;

  @override
  Future<List<PricePoint>> fetch(
    String cardId, {
    required CardFinish finish,
    int days = 400,
    String? cardName,
    String? externalId,
  }) async {
    // TCGdex card ids are "<setId>-<localId>", e.g. "base1-4".
    final dash = cardId.lastIndexOf('-');
    if (dash <= 0) return const [];
    final setId = cardId.substring(0, dash).toLowerCase();
    final localId = cardId.substring(dash + 1);
    if (setId.isEmpty || localId.isEmpty) return const [];

    try {
      final res = await _dio.get<dynamic>('$_base/$setId/$localId.tcgplayer.json');
      final data = decodeJsonBody(res.data);
      if (data is! Map) return const [];

      // Shape: {"data": {"<condition>-<grade>": {"history": {"YYYY-MM-DD":
      //   {"avg": cents, "count": n, "min": cents, "max": cents}}}}}
      // Values are in cents, and several condition buckets coexist.
      final buckets = data['data'];
      if (buckets is! Map) return const [];

      // Buckets are "<treatment>-<grade>". Prefer the best grade available in
      // the treatment that matches the finish being valued.
      final preferred = finish.isPremium
          ? const [
              'holo-nearmint',
              'holo-good',
              'holo-played',
              'holo-used',
              'normal-nearmint',
              'normal-good',
            ]
          : const [
              'normal-nearmint',
              'normal-good',
              'normal-played',
              'normal-used',
              'holo-nearmint',
              'holo-good',
            ];

      Map? history;
      for (final key in preferred) {
        final bucket = buckets[key];
        if (bucket is Map && bucket['history'] is Map) {
          history = bucket['history'] as Map;
          break;
        }
      }
      history ??= buckets.values
          .whereType<Map>()
          .map((b) => b['history'])
          .whereType<Map>()
          .firstOrNull;
      if (history == null || history.isEmpty) return const [];

      // The archive stopped updating in September 2024, so a window measured
      // back from *today* would discard the entire thing. The most recent [days]
      // observations are taken instead, which is what the caller actually wants
      // from a historical series.
      final points = <PricePoint>[];
      history.forEach((dateKey, value) {
        final date = DateTime.tryParse(dateKey.toString());
        if (date == null) return;
        double? cents;
        if (value is Map) {
          final avg = value['avg'];
          if (avg is num) cents = avg.toDouble();
        } else if (value is num) {
          cents = value.toDouble();
        }
        if (cents == null || cents <= 0) return;
        points.add(PricePoint(DateTime(date.year, date.month, date.day), cents / 100.0));
      });
      if (points.length < 5) return const [];
      points.sort((a, b) => a.date.compareTo(b.date));
      // Keep the tail: the series is daily, so the last [days] points are the
      // last [days] days of trading.
      if (points.length > days) {
        return points.sublist(points.length - days);
      }
      return points;
    } catch (_) {
      return const [];
    }
  }
}

/// Hosted price-history API with a free tier (key required).
///
/// The only genuinely live per-card history for Pokémon, and a secondary option
/// for Magic. The free tier is rate limited (100 requests/day, 20 cards per
/// request), so the app uses it for targeted backfills rather than whole
/// collections.
class JustTcgHistorySource implements PriceHistorySource {
  JustTcgHistorySource({required this.apiKey, this.game = CardGame.mtg, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.justtcg.com/v1',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 20),
            ));

  final String apiKey;

  /// Which game this instance is querying.
  final CardGame game;
  final Dio _dio;

  @override
  String get id => 'justtcg';

  @override
  String get label => 'JustTCG';

  @override
  Set<CardGame> get supportedGames => {game};

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  Future<List<PricePoint>> fetch(
    String cardId, {
    required CardFinish finish,
    int days = 400,
    String? cardName,
    String? externalId,
  }) async {
    if (!isConfigured) return const [];
    final duration =
        days <= 7 ? '7d' : (days <= 30 ? '30d' : (days <= 90 ? '90d' : (days <= 180 ? '180d' : '1y')));
    try {
      // Magic is addressed by Scryfall id; Pokémon has no Scryfall id, so the
      // provider's own TCGplayer product id is used when the catalogue
      // supplied one.
      final params = <String, dynamic>{
        'include_price_history': true,
        'priceHistoryDuration': duration,
        if (game == CardGame.mtg && externalId == null) 'scryfallId': cardId,
        'tcgplayerId': ?externalId,
      };
      final res = await _dio.get<dynamic>(
        '/cards',
        queryParameters: params,
        options: Options(headers: {'x-api-key': apiKey}),
      );
      final data = decodeJsonBody(res.data);
      if (data is! Map) return const [];
      final list = data['data'];
      if (list is! List || list.isEmpty) return const [];
      final variants = (list.first is Map) ? (list.first as Map)['variants'] : null;
      if (variants is! List) return const [];

      // Prefer the variant matching the requested finish.
      Map? chosen;
      for (final v in variants) {
        if (v is! Map) continue;
        final printing =
            (v['printing'] ?? v['finish'] ?? v['name'] ?? '').toString().toLowerCase();
        final wantsFoil = finish.isPremium;
        final isFoil = printing.contains('holo') ||
            printing.contains('foil') ||
            printing.contains('1st');
        if (wantsFoil == isFoil) {
          chosen = v;
          break;
        }
      }
      chosen ??= variants.whereType<Map>().firstOrNull;
      if (chosen == null) return const [];

      final history = chosen['priceHistory'];
      if (history is! List) return const [];
      final points = <PricePoint>[];
      for (final h in history) {
        if (h is! Map) continue;
        final t = h['t'];
        final p = h['p'];
        if (t is! num || p is! num) continue;
        final d = DateTime.fromMillisecondsSinceEpoch(t.toInt() * 1000, isUtc: true).toLocal();
        points.add(PricePoint(DateTime(d.year, d.month, d.day), p.toDouble()));
      }
      points.sort((a, b) => a.date.compareTo(b.date));
      return points;
    } on DioException {
      return const [];
    } catch (_) {
      return const [];
    }
  }
}

/// Encodes a series in the compact Arcanum Sync wire format.
///
/// Shared by the companion tooling and the export feature so the two can never
/// drift apart.
String encodeHistoryPack(String cardId, Map<CardFinish, List<PricePoint>> series) {
  final out = <String, dynamic>{
    'id': cardId,
    'updated': DateTime.now().toIso8601String().split('T').first,
    'series': {
      for (final e in series.entries)
        if (e.value.isNotEmpty)
          e.key.code: [
            for (final p in e.value)
              [p.date.millisecondsSinceEpoch ~/ 1000, double.parse(p.price.toStringAsFixed(4))],
          ],
    },
  };
  return jsonEncode(out);
}
