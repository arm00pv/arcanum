import 'package:dio/dio.dart';

import 'package:arcanum/data/history/price_history_source.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/sealed_product.dart';

/// One sealed product a price list knows about.
class SealedOffer {
  /// Creates an offer.
  const SealedOffer({
    required this.name,
    required this.category,
    this.productId = '',
    this.market,
    this.low,
    this.mid,
    this.asOf,
  });

  /// The product's name, as the price list has it.
  final String name;

  /// What kind of product it is, guessed from the name.
  final SealedCategory category;

  /// The price list's own id, used to keep a holding attached to its product.
  final String productId;

  /// What it is selling for.
  final double? market;

  /// The lowest asking price.
  final double? low;

  /// The middle asking price.
  final double? mid;

  /// When those figures were published.
  final DateTime? asOf;

  /// Whether the list carries a price for it at all.
  bool get isPriced => market != null && market! > 0;

  @override
  String toString() => 'SealedOffer($name, market=$market)';
}

/// Somewhere sealed product prices can be looked up.
///
/// An interface because the lookup is a convenience, not the feature: a collector
/// who has no companion must still be able to record a box and what they paid
/// for it, and a test must be able to answer without a network.
abstract interface class SealedPriceSource {
  /// Products and prices for one set, dearest first.
  ///
  /// Returns an empty list rather than throwing when nothing can be found: a set
  /// with no sealed product, a companion that is asleep and a set code that does
  /// not exist are all the same answer to the caller - type it in yourself.
  Future<List<SealedOffer>> forSet(CardGame game, String setCode);
}

/// Reads sealed product from the collector's own companion.
///
/// The companion fetches the set's product list and prices once, caches it, and
/// answers with both joined; the app never talks to the price list directly, so
/// the phone carries no key, no schedule and no rate limit of its own.
class CompanionSealedSource implements SealedPriceSource {
  /// Creates the source. [endpoint] is the companion base URL.
  CompanionSealedSource({required this.endpoint, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 25),
              headers: const <String, String>{'Accept': 'application/json'},
            ),
          );

  /// The base URL of the collector's companion.
  final String endpoint;

  final Dio _dio;

  @override
  Future<List<SealedOffer>> forSet(CardGame game, String setCode) async {
    final base = endpoint.trim();
    if (base.isEmpty || setCode.trim().isEmpty) return const <SealedOffer>[];
    try {
      // Trailing slashes are dropped rather than trusted: the endpoint is typed
      // by hand in Settings and a doubled slash is a 404 nobody can explain.
      final root = base.replaceAll(RegExp(r'/+$'), '');
      final res = await _dio.get<dynamic>(
        '$root/v1/sealed',
        queryParameters: <String, dynamic>{
          'game': game.id,
          'set': setCode.trim(),
        },
      );
      return parseSealedOffers(res.data);
    } on DioException {
      return const <SealedOffer>[];
    } catch (_) {
      return const <SealedOffer>[];
    }
  }
}

/// Turns a companion response into offers.
///
/// Written defensively, in the same spirit as the price-history packs: a change
/// of content type, a name that has moved or a body that is not what was
/// expected produces an empty list rather than an exception in a settings sheet.
List<SealedOffer> parseSealedOffers(Object? body) {
  final decoded = decodeJsonBody(body);
  if (decoded is! Map) return const <SealedOffer>[];
  final raw = decoded['products'] ?? decoded['results'];
  if (raw is! List) return const <SealedOffer>[];
  final asOfRaw = decoded['asOf'] ?? decoded['updated'];
  final DateTime? asOf = asOfRaw is num
      ? DateTime.fromMillisecondsSinceEpoch(asOfRaw.toInt() * 1000)
      : (asOfRaw is String ? DateTime.tryParse(asOfRaw) : null);

  final offers = <SealedOffer>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final name = (item['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) continue;
    offers.add(
      SealedOffer(
        name: name,
        category: SealedCategory.guess(name),
        productId: (item['productId'] ?? item['id'] ?? '').toString(),
        market: _money(item['market'] ?? item['marketPrice']),
        low: _money(item['low'] ?? item['lowPrice']),
        mid: _money(item['mid'] ?? item['midPrice']),
        asOf: asOf,
      ),
    );
  }
  offers.sort((a, b) {
    final av = a.market ?? -1;
    final bv = b.market ?? -1;
    return bv.compareTo(av);
  });
  return offers;
}

double? _money(Object? value) {
  if (value is num) {
    final v = value.toDouble();
    return v > 0 ? v : null;
  }
  if (value is String) {
    final v = double.tryParse(value.trim());
    return v != null && v > 0 ? v : null;
  }
  return null;
}
