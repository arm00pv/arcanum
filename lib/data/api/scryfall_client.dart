// Pure-Dart client for the Scryfall MTG API.
//
// VERIFIED ENDPOINTS (every one of these was actually requested while writing
// this file, and every field name below comes from a real response body):
//
//   GET  https://api.scryfall.com/sets
//        -> {object:"list", has_more:false, data:[1049 Set objects]}
//   GET  https://api.scryfall.com/cards/search?q=set%3Atla&order=set&unique=prints
//        -> {object:"list", total_cards:394, has_more:true, next_page:"...",
//            data:[175 Card objects]}
//   GET  https://api.scryfall.com/cards/search?...&page=2      (175 more)
//   GET  https://api.scryfall.com/cards/search?q=oracleid%3A<uuid>&unique=prints
//   GET  https://api.scryfall.com/cards/:id
//   GET  https://api.scryfall.com/cards/:code/:number     (404 body:
//        {object:"error", code:"not_found", status:404, details:"..."})
//   POST https://api.scryfall.com/cards/collection
//        body {"identifiers":[{"set":"tla","collector_number":"27"}]}
//        -> {object:"list", not_found:[...], data:[...]}
//
// Documentation: https://scryfall.com/docs/api , /sets , /cards , /cards/search ,
// /cards/collection , /cards/id , /cards/collector , /lists , /errors ,
// /rate-limits
//
// RATE LIMITS - the published numbers matter and are NOT uniform:
//   /cards/search, /cards/named, /cards/random, /cards/collection -> 2/second (500 ms)
//   every other method                                            -> 10/second (100 ms)
//   /cards/manifest                                               -> 10/minute
// A single serialised queue enforces the correct gap per endpoint, so this
// client cannot exceed either limit no matter how many callers fire at once.
// HTTP 429 is honoured (Retry-After, capped) with exponential backoff + jitter,
// as the docs require ("It is not acceptable to ignore HTTP 429 responses").

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'scryfall_models.dart';

export 'scryfall_models.dart';

/// Base URL of the Scryfall API. HTTPS only.
const String kScryfallBaseUrl = 'https://api.scryfall.com';

/// Default User-Agent. Scryfall *requires* a descriptive User-Agent and will
/// reject or throttle requests without one.
const String kScryfallDefaultUserAgent =
    'Arcanum/1.0 (+https://github.com/arcanum)';

/// Default Accept header. Scryfall requires the header to be present.
const String kScryfallDefaultAccept = 'application/json';

/// Minimum gap between requests to "slow" endpoints (10 requests/second).
const Duration kScryfallRequestGap = Duration(milliseconds: 100);

/// Minimum gap between requests to /cards/search and /cards/collection
/// (2 requests/second).
const Duration kScryfallSearchRequestGap = Duration(milliseconds: 500);

/// Maximum number of card identifiers accepted by POST /cards/collection.
const int kScryfallMaxCollectionIdentifiers = 75;

/// Default size of the in-memory card LRU cache.
const int kScryfallDefaultCacheSize = 500;

/// Error thrown by [ScryfallClient] when a request cannot be completed.
class ScryfallException implements Exception {
  const ScryfallException(
    this.message, {
    this.statusCode,
    this.uri,
    this.code,
    this.cause,
  });

  /// Human readable description (Scryfall's `details` when it sent one).
  final String message;

  /// HTTP status code, when the failure came from an HTTP response.
  final int? statusCode;

  /// The URI that failed.
  final Uri? uri;

  /// Scryfall's machine readable error code, e.g. `not_found`.
  final String? code;

  /// The underlying error, when there was one.
  final Object? cause;

  /// True for HTTP 404 / `not_found` responses.
  bool get isNotFound => statusCode == 404 || code == 'not_found';

  /// True when Scryfall asked us to slow down (HTTP 429).
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('ScryfallException: $message');
    if (statusCode != null) {
      buffer.write(' (HTTP $statusCode');
      if (code != null) {
        buffer.write(', $code');
      }
      buffer.write(')');
    } else if (code != null) {
      buffer.write(' ($code)');
    }
    if (uri != null) {
      buffer.write(' [$uri]');
    }
    return buffer.toString();
  }
}

/// One page of a `/cards/search` response.
///
/// Paging is deliberately exposed so a UI can stream results progressively:
/// pass `page:` to [ScryfallClient.searchCards], or consume
/// [ScryfallClient.searchAllPages] as a stream.
class ScryfallSearchResult {
  const ScryfallSearchResult({
    required this.cards,
    required this.hasMore,
    required this.totalCards,
    this.nextPage,
  });

  /// Cards on this page (Scryfall returns up to 175 at a time).
  final List<ScryfallCard> cards;

  /// True when there is a page beyond this one.
  final bool hasMore;

  /// Total number of cards the query matched across all pages.
  final int totalCards;

  /// Full URI of the next page, as returned by Scryfall.
  final String? nextPage;

  /// True when the query matched nothing.
  bool get isEmpty => cards.isEmpty;

  @override
  String toString() =>
      'ScryfallSearchResult(${cards.length}/$totalCards cards, hasMore: $hasMore)';
}

/// A card identifier for [ScryfallClient.fetchCollection].
typedef ScryfallCardIdentifier = ({String setCode, String collectorNumber});

/// Client for the Scryfall API.
///
/// Requests are serialised through a single queue with a per-endpoint minimum
/// gap, so a burst of concurrent calls still respects Scryfall's rate limits.
class ScryfallClient {
  ScryfallClient({
    Dio? dio,
    String userAgent = kScryfallDefaultUserAgent,
    String accept = kScryfallDefaultAccept,
    String baseUrl = kScryfallBaseUrl,
    this.requestGap = kScryfallRequestGap,
    this.searchRequestGap = kScryfallSearchRequestGap,
    this.maxRetries = 4,
    int cacheSize = kScryfallDefaultCacheSize,
  })  : _dio = dio ??
            _createDio(
              baseUrl: baseUrl,
              userAgent: userAgent,
              accept: accept,
            ),
        _baseUrl = _resolveBaseUrl(dio, baseUrl),
        _userAgent = userAgent,
        _accept = accept,
        _cardCache = _LruCache<String, ScryfallCard>(cacheSize);

  static final math.Random _random = math.Random();

  final Dio _dio;
  final String _baseUrl;
  final String _userAgent;
  final String _accept;
  /// Minimum gap enforced between requests to the 10/second endpoints
  /// (everything except search and collection).
  final Duration requestGap;

  /// Minimum gap enforced between requests to /cards/search and
  /// /cards/collection, which Scryfall limits to 2/second.
  final Duration searchRequestGap;

  /// How many times a retryable failure is retried before giving up.
  final int maxRetries;
  final _LruCache<String, ScryfallCard> _cardCache;

  /// Tail of the serialised request queue.
  Future<void> _queueTail = Future<void>.value();

  /// When the last request was *started* (rate limiting is measured
  /// start-to-start, which is exactly what "requests per second" means).
  DateTime? _lastRequestStartedAt;

  List<ScryfallSet>? _setsCache;
  Future<List<ScryfallSet>>? _setsInFlight;

  // -------------------------------------------------------------------------
  // Diagnostics / cache control
  // -------------------------------------------------------------------------

  /// Number of cards currently held in the LRU cache.
  int get cardCacheSize => _cardCache.length;

  /// True once [fetchAllSets] has completed at least once.
  bool get hasCachedSets => _setsCache != null;

  /// Empties the card LRU cache.
  void clearCache() => _cardCache.clear();

  /// Forgets the cached `/sets` response.
  void clearSetsCache() {
    _setsCache = null;
    _setsInFlight = null;
  }

  /// Closes the underlying [Dio] instance.
  void close({bool force = false}) => _dio.close(force: force);

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Fetches every Scryfall set, following `has_more` / `next_page`.
  ///
  /// The result is cached for the lifetime of this client (Scryfall only
  /// changes set data around releases). Pass `forceRefresh: true` to bypass
  /// the cache.
  ///
  /// Throws [ScryfallException] if the list cannot be completed - a partial
  /// set list would silently corrupt anything built on top of it.
  Future<List<ScryfallSet>> fetchAllSets({bool forceRefresh = false}) {
    if (!forceRefresh) {
      final List<ScryfallSet>? cached = _setsCache;
      if (cached != null) {
        return Future<List<ScryfallSet>>.value(cached);
      }
      final Future<List<ScryfallSet>>? inFlight = _setsInFlight;
      if (inFlight != null) {
        return inFlight;
      }
    }
    final Future<List<ScryfallSet>> request = _loadAllSets();
    _setsInFlight = request;
    return request.whenComplete(() {
      if (identical(_setsInFlight, request)) {
        _setsInFlight = null;
      }
    });
  }

  /// Fetches every printing in [setCode] (`set:<code> order:set unique:prints`),
  /// following all pages of the 175-card pagination.
  ///
  /// [onProgress] is called after every page with `(cardsLoadedSoFar, total)`,
  /// so a UI can render results progressively instead of waiting for the last
  /// page.
  ///
  /// Resilient by design: if a later page fails, the pages already fetched are
  /// still returned. Only a failure of the *first* page throws.
  Future<List<ScryfallCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final String code = setCode.trim().toLowerCase();
    if (code.isEmpty) {
      throw const ScryfallException('fetchCardsInSet requires a set code');
    }

    final List<ScryfallCard> cards = <ScryfallCard>[];
    Object? firstError;
    int total = 0;
    int page = 1;

    while (true) {
      final ScryfallSearchResult result;
      try {
        result = await searchCards(
          'set:$code',
          order: 'set',
          unique: false,
          page: page,
        );
      } on Object catch (error) {
        firstError = cards.isEmpty ? error : firstError;
        break;
      }

      total = result.totalCards;
      cards.addAll(result.cards);
      onProgress?.call(cards.length, total);

      if (!result.hasMore || result.cards.isEmpty) {
        break;
      }
      page += 1;
      if (page > _maxPages) {
        break;
      }
    }

    if (cards.isEmpty && firstError != null) {
      if (firstError is ScryfallException) {
        throw firstError;
      }
      throw ScryfallException(
        'Failed to load cards for set "$setCode"',
        cause: firstError,
      );
    }

    cards.sort(_byCollectorNumber);
    return List<ScryfallCard>.unmodifiable(cards);
  }

  /// Fetches a single card by its Scryfall UUID. Returns null on HTTP 404.
  Future<ScryfallCard?> fetchCardById(String id) async {
    final String key = 'id:${id.trim()}';
    final ScryfallCard? cached = _cardCache.get(key);
    if (cached != null) {
      return cached;
    }
    final Uri uri = Uri.parse(
      '$_baseUrl/cards/${Uri.encodeComponent(id.trim())}',
    );
    try {
      final ScryfallCard card = ScryfallCard.fromJson(
        await _requestJson('GET', uri, gap: requestGap),
      );
      _remember(card);
      return card;
    } on ScryfallException catch (error) {
      if (error.isNotFound) {
        return null;
      }
      rethrow;
    }
  }

  /// Fetches a single printing by set code and collector number.
  /// Returns null on HTTP 404.
  Future<ScryfallCard?> fetchCardBySetAndNumber(
    String setCode,
    String number,
  ) async {
    final String code = setCode.trim().toLowerCase();
    final String collectorNumber = number.trim();
    final String key = 'print:$code/$collectorNumber';
    final ScryfallCard? cached = _cardCache.get(key);
    if (cached != null) {
      return cached;
    }
    final Uri uri = Uri.parse(
      '$_baseUrl/cards/${Uri.encodeComponent(code)}'
      '/${Uri.encodeComponent(collectorNumber)}',
    );
    try {
      final ScryfallCard card = ScryfallCard.fromJson(
        await _requestJson('GET', uri, gap: requestGap),
      );
      _remember(card);
      return card;
    } on ScryfallException catch (error) {
      if (error.isNotFound) {
        return null;
      }
      rethrow;
    }
  }

  /// Runs one page of a fulltext search.
  ///
  /// [unique] maps to Scryfall's rollup strategy: `true` -> `unique=cards`,
  /// `false` -> `unique=prints`.
  Future<ScryfallSearchResult> searchCards(
    String query, {
    String order = 'name',
    bool unique = true,
    int page = 1,
    String? dir,
    bool includeExtras = false,
  }) async {
    final Uri uri = Uri.parse('$_baseUrl/cards/search').replace(
      queryParameters: <String, String>{
        'q': query,
        'order': order,
        'unique': unique ? 'cards' : 'prints',
        'page': '$page',
        if (dir != null && dir.isNotEmpty) 'dir': dir,
        if (includeExtras) 'include_extras': 'true',
      },
    );
    final Map<String, dynamic> json = await _requestJson(
      'GET',
      uri,
      gap: searchRequestGap,
    );
    final _ListPage parsed = _ListPage.parse(json);
    return ScryfallSearchResult(
      cards: List<ScryfallCard>.unmodifiable(
        parsed.items.map(ScryfallCard.fromJson),
      ),
      hasMore: parsed.hasMore,
      totalCards: parsed.totalCards,
      nextPage: parsed.nextPage,
    );
  }

  /// Streams every page of a search, one [ScryfallSearchResult] at a time, so
  /// results can be rendered as they arrive.
  ///
  /// Stops early (without throwing) if a later page fails; a failure of the
  /// first page is rethrown.
  Stream<ScryfallSearchResult> searchAllPages(
    String query, {
    String order = 'name',
    bool unique = true,
    int startPage = 1,
    int? maxPages,
  }) async* {
    int page = startPage < 1 ? 1 : startPage;
    int emitted = 0;
    while (true) {
      final ScryfallSearchResult result = await searchCards(
        query,
        order: order,
        unique: unique,
        page: page,
      );
      yield result;
      emitted += 1;
      if (!result.hasMore || result.cards.isEmpty) {
        break;
      }
      if (maxPages != null && emitted >= maxPages) {
        break;
      }
      page += 1;
      if (page > _maxPages) {
        break;
      }
    }
  }

  /// Resolves a collection of printings via `POST /cards/collection`.
  ///
  /// Identifiers are chunked into groups of [kScryfallMaxCollectionIdentifiers]
  /// (75), the documented maximum. Missing printings are simply absent from the
  /// result - Scryfall reports them in its `not_found` array, which is not an
  /// error.
  ///
  /// A failing chunk does not discard the chunks that already succeeded; if
  /// *every* chunk fails, the last error is thrown.
  Future<List<ScryfallCard>> fetchCollection(
    List<ScryfallCardIdentifier> ids,
  ) async {
    if (ids.isEmpty) {
      return const <ScryfallCard>[];
    }

    final Uri uri = Uri.parse('$_baseUrl/cards/collection');
    final List<ScryfallCard> cards = <ScryfallCard>[];
    Object? lastError;
    bool anySucceeded = false;

    for (
      int start = 0;
      start < ids.length;
      start += kScryfallMaxCollectionIdentifiers
    ) {
      final int end = math.min(
        start + kScryfallMaxCollectionIdentifiers,
        ids.length,
      );
      final List<Map<String, String>> identifiers = <Map<String, String>>[
        for (final ScryfallCardIdentifier id in ids.sublist(start, end))
          <String, String>{
            'set': id.setCode.trim().toLowerCase(),
            'collector_number': id.collectorNumber.trim(),
          },
      ];

      try {
        final Map<String, dynamic> json = await _requestJson(
          'POST',
          uri,
          body: jsonEncode(<String, Object?>{'identifiers': identifiers}),
          gap: searchRequestGap,
        );
        anySucceeded = true;
        final Object? data = json['data'];
        if (data is List) {
          for (final Object? item in data) {
            if (item is Map) {
              final ScryfallCard card = ScryfallCard.fromJson(
                _asJsonMap(item),
              );
              cards.add(card);
              _remember(card);
            }
          }
        }
      } on Object catch (error) {
        lastError = error;
      }
    }

    if (!anySucceeded && lastError != null) {
      if (lastError is ScryfallException) {
        throw lastError;
      }
      throw ScryfallException(
        'POST /cards/collection failed',
        uri: uri,
        cause: lastError,
      );
    }
    return List<ScryfallCard>.unmodifiable(cards);
  }

  /// Fetches every printing that shares [oracleId] (i.e. all reprints of the
  /// same card), newest first.
  ///
  /// Same resilience rule as [fetchCardsInSet]: partial results are returned,
  /// only a first-page failure throws.
  Future<List<ScryfallCard>> fetchCardsByOracleId(String oracleId) async {
    final String id = oracleId.trim();
    if (id.isEmpty) {
      throw const ScryfallException('fetchCardsByOracleId requires an oracle id');
    }

    final List<ScryfallCard> cards = <ScryfallCard>[];
    Object? firstError;
    int page = 1;

    while (true) {
      final ScryfallSearchResult result;
      try {
        result = await searchCards(
          'oracleid:$id',
          order: 'released',
          unique: false,
          page: page,
        );
      } on Object catch (error) {
        firstError = cards.isEmpty ? error : firstError;
        break;
      }

      cards.addAll(result.cards);
      if (!result.hasMore || result.cards.isEmpty) {
        break;
      }
      page += 1;
      if (page > _maxPages) {
        break;
      }
    }

    if (cards.isEmpty && firstError != null) {
      if (firstError is ScryfallException) {
        throw firstError;
      }
      throw ScryfallException(
        'Failed to load printings for oracle id "$oracleId"',
        cause: firstError,
      );
    }
    return List<ScryfallCard>.unmodifiable(cards);
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Hard stop for runaway pagination (Scryfall pages are 175 cards, so this
  /// still allows ~100k cards).
  static const int _maxPages = 600;

  static Dio _createDio({
    required String baseUrl,
    required String userAgent,
    required String accept,
  }) {
    return Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 30),
        responseType: ResponseType.json,
        headers: <String, dynamic>{
          'User-Agent': userAgent,
          'Accept': accept,
        },
      ),
    );
  }

  static String _resolveBaseUrl(Dio? dio, String fallback) {
    final String? injected = dio?.options.baseUrl;
    final String raw = (injected != null && injected.trim().isNotEmpty)
        ? injected
        : fallback;
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  static int _byCollectorNumber(ScryfallCard a, ScryfallCard b) {
    final int byKey =
        a.collectorNumberSortKey.compareTo(b.collectorNumberSortKey);
    if (byKey != 0) {
      return byKey;
    }
    return a.collectorNumber.compareTo(b.collectorNumber);
  }

  void _remember(ScryfallCard card) {
    if (card.id.isNotEmpty) {
      _cardCache.put('id:${card.id}', card);
    }
    if (card.setCode.isNotEmpty && card.collectorNumber.isNotEmpty) {
      _cardCache.put('print:${card.setCode}/${card.collectorNumber}', card);
    }
  }

  Future<List<ScryfallSet>> _loadAllSets() async {
    final List<ScryfallSet> sets = <ScryfallSet>[];
    Uri? next = Uri.parse('$_baseUrl/sets');
    int page = 0;

    while (next != null) {
      page += 1;
      final Map<String, dynamic> json;
      try {
        json = await _requestJson('GET', next, gap: requestGap);
      } on ScryfallException catch (error) {
        throw ScryfallException(
          'Could not load the Scryfall set list (page $page of ${next.path}): '
          '${error.message}',
          statusCode: error.statusCode,
          uri: error.uri,
          code: error.code,
          cause: error.cause,
        );
      }

      final _ListPage parsed = _ListPage.parse(json);
      for (final Map<String, dynamic> item in parsed.items) {
        sets.add(ScryfallSet.fromJson(item));
      }

      if (!parsed.hasMore) {
        break;
      }
      final String? nextPage = parsed.nextPage;
      if (nextPage == null || nextPage.isEmpty) {
        break;
      }
      next = Uri.parse(nextPage);
      if (page > _maxPages) {
        break;
      }
    }

    if (sets.isEmpty) {
      throw const ScryfallException(
        'The Scryfall set list came back empty',
        uri: null,
      );
    }

    final List<ScryfallSet> result = List<ScryfallSet>.unmodifiable(sets);
    _setsCache = result;
    return result;
  }

  /// Serialises [action] behind every request already queued, so only one HTTP
  /// request is ever in flight.
  Future<T> _serialise<T>(Future<T> Function() action) {
    final Future<T> result = _queueTail.then((void _) => action());
    _queueTail = result.then<void>(
      (T value) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  /// Blocks until at least [gap] has passed since the previous request started.
  Future<void> _respectRateLimit(Duration gap) async {
    final DateTime? previous = _lastRequestStartedAt;
    if (previous != null && gap > Duration.zero) {
      final Duration elapsed = DateTime.now().difference(previous);
      final Duration remaining = gap - elapsed;
      if (remaining > Duration.zero) {
        await Future<void>.delayed(remaining);
      }
    }
    _lastRequestStartedAt = DateTime.now();
  }

  /// Performs one request with rate limiting and retry handling.
  ///
  /// Retries: HTTP 429 (honouring `Retry-After`), any 5xx, and the transient
  /// transport failures (connection/send/receive timeouts, connection errors),
  /// up to [maxRetries] times with exponential backoff plus jitter.
  Future<Map<String, dynamic>> _requestJson(
    String method,
    Uri uri, {
    Object? body,
    required Duration gap,
  }) {
    return _serialise(() async {
      int attempt = 0;
      while (true) {
        await _respectRateLimit(gap);
        try {
          final Response<Object?> response = await _dio.requestUri<Object?>(
            uri,
            data: body,
            options: Options(
              method: method,
              responseType: ResponseType.json,
              contentType: body == null ? null : Headers.jsonContentType,
              headers: <String, dynamic>{
                'User-Agent': _userAgent,
                'Accept': _accept,
              },
            ),
          );
          return _decodeJsonObject(response.data, uri);
        } on DioException catch (error, stackTrace) {
          if (!_isRetryable(error) || attempt >= maxRetries) {
            Error.throwWithStackTrace(_toScryfallException(error, uri), stackTrace);
          }
          attempt += 1;
          await Future<void>.delayed(
            _backoffDelay(
              attempt,
              statusCode: error.response?.statusCode,
              retryAfter: _retryAfter(error.response),
            ),
          );
        }
      }
    });
  }

  bool _isRetryable(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final int status = error.response?.statusCode ?? 0;
        return status == 429 || status >= 500;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return false;
    }
  }

  /// Exponential backoff with jitter: 700 ms, 1.4 s, 2.8 s, 5.6 s (+ up to
  /// 250 ms of jitter), or Scryfall's `Retry-After` when it sent one.
  Duration _backoffDelay(
    int attempt, {
    int? statusCode,
    Duration? retryAfter,
  }) {
    if (retryAfter != null && retryAfter > Duration.zero) {
      return retryAfter;
    }
    final int baseMs = statusCode == 429 ? 1000 : 700;
    final int exponential = baseMs * (1 << (attempt - 1));
    final int capped = math.min(exponential, 8000);
    return Duration(milliseconds: capped + _random.nextInt(250));
  }

  Duration? _retryAfter(Response<Object?>? response) {
    final String? raw = response?.headers.value('retry-after');
    if (raw == null) {
      return null;
    }
    final int? seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds <= 0) {
      return null;
    }
    // Scryfall's 429 penalty is 30 s; never wait longer than that for one retry.
    return Duration(seconds: math.min(seconds, 30));
  }

  ScryfallException _toScryfallException(DioException error, Uri uri) {
    final Response<Object?>? response = error.response;
    final int? status = response?.statusCode;

    String? code;
    String? details;
    final Map<String, dynamic>? body = _tryJsonObject(response?.data);
    if (body != null) {
      final Object? rawCode = body['code'];
      final Object? rawDetails = body['details'];
      if (rawCode != null) {
        code = rawCode.toString();
      }
      if (rawDetails != null) {
        details = rawDetails.toString();
      }
    }

    return ScryfallException(
      details ?? _describeDioError(error, status, uri),
      statusCode: status,
      uri: uri,
      code: code,
      cause: error,
    );
  }

  String _describeDioError(DioException error, int? status, Uri uri) {
    if (status != null) {
      return 'Scryfall returned HTTP $status for $uri';
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return 'Timed out connecting to $uri';
      case DioExceptionType.sendTimeout:
        return 'Timed out sending the request to $uri';
      case DioExceptionType.receiveTimeout:
        return 'Timed out waiting for a response from $uri';
      case DioExceptionType.connectionError:
        return 'Could not reach the Scryfall API at $uri '
            '(check the network connection)';
      case DioExceptionType.badCertificate:
        return 'TLS certificate rejected for $uri';
      case DioExceptionType.cancel:
        return 'The request to $uri was cancelled';
      case DioExceptionType.badResponse:
        return 'Scryfall returned an unexpected response for $uri';
      case DioExceptionType.transformTimeout:
        return 'Timed out transforming the response from $uri';
      case DioExceptionType.unknown:
        return 'Request to $uri failed: ${error.message ?? error.error}';
    }
  }

  Map<String, dynamic> _decodeJsonObject(Object? data, Uri uri) {
    if (data is Map) {
      return _asJsonMap(data);
    }
    if (data is String) {
      final Map<String, dynamic>? decoded = _tryJsonObject(data);
      if (decoded == null) {
        throw ScryfallException(
          'Expected a JSON object from $uri',
          uri: uri,
        );
      }
      return decoded;
    }
    if (data is List<int>) {
      return _decodeJsonObject(utf8.decode(data), uri);
    }
    throw ScryfallException(
      'Unexpected response body of type ${data.runtimeType} from $uri',
      uri: uri,
    );
  }

  static Map<String, dynamic> _asJsonMap(Map<Object?, Object?> data) {
    return data.map<String, dynamic>(
      (Object? key, Object? value) =>
          MapEntry<String, dynamic>(key.toString(), value),
    );
  }

  static Map<String, dynamic>? _tryJsonObject(Object? data) {
    if (data is Map) {
      return _asJsonMap(data);
    }
    if (data is String) {
      final String trimmed = data.trim();
      if (trimmed.isEmpty) {
        return null;
      }
      try {
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return _asJsonMap(decoded);
        }
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

/// A parsed Scryfall "List object" page.
class _ListPage {
  const _ListPage({
    required this.items,
    required this.hasMore,
    required this.totalCards,
    required this.nextPage,
  });

  factory _ListPage.parse(Map<String, dynamic> json) {
    final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    final Object? data = json['data'];
    if (data is List) {
      for (final Object? item in data) {
        if (item is Map) {
          items.add(ScryfallClient._asJsonMap(item));
        }
      }
    }
    final Object? rawTotal = json['total_cards'];
    final int total = rawTotal is int
        ? rawTotal
        : (rawTotal is num ? rawTotal.toInt() : items.length);
    final Object? rawNext = json['next_page'];
    return _ListPage(
      items: items,
      hasMore: json['has_more'] == true,
      totalCards: total,
      nextPage: rawNext is String && rawNext.isNotEmpty ? rawNext : null,
    );
  }

  final List<Map<String, dynamic>> items;
  final bool hasMore;
  final int totalCards;
  final String? nextPage;
}

/// A tiny insertion-ordered LRU cache built on Dart's [Map] (a LinkedHashMap,
/// which preserves insertion order and lets us evict the oldest entry).
class _LruCache<K, V> {
  _LruCache(this.maximumSize);

  final int maximumSize;
  final Map<K, V> _entries = <K, V>{};

  int get length => _entries.length;

  V? get(K key) {
    final V? value = _entries.remove(key);
    if (value == null) {
      return null;
    }
    _entries[key] = value; // Re-insert as most recently used.
    return value;
  }

  void put(K key, V value) {
    if (maximumSize <= 0) {
      return;
    }
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maximumSize) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() => _entries.clear();
}
