import 'dart:async';

import 'package:dio/dio.dart';

import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Gundam Card Game card data, served by gcgapi.
///
/// gcgapi is the first source of this game that is not TCGplayer's catalogue
/// under someone else's mirror. Gundam was catalogued by tcgcsv, which is a
/// redistribution of TCGplayer and reads in a browser only through Arcanum's own
/// relay, and two consequences of that were the web build's worst case: the Sets
/// tab was empty until a set had been opened, and there was no search at all.
/// gcgapi publishes the publisher's own English card database - names, rules
/// text, colour, level, cost, attack, hit points, the zone a unit deploys to, the
/// pilot that links to it and one art URL per printing - from a host that names
/// the asking origin, so a browser can ask it directly.
///
/// Six properties of the source shape the code here. Every one of them was
/// measured against the live API rather than read off a document.
///
/// **The id is forwarded, and it has to be.** A card's id is the provider's own
/// 'product_id', verbatim. The printed number cannot be the id: 1,912 products
/// carry 1,148 distinct card numbers, because an alternate art is a product of
/// its own with the same number printed on it - GD01-005, GD01-005_p1,
/// GD01-005_p2, GD01-005_p3 and GD01-005_p4 are five arts of one card, two of
/// them sharing a rarity. 'product_id' is unique across the whole catalogue
/// (1,912 of 1,912) and every one of them begins with its own card number, which
/// is the property [collectorNumber] and the scan path rely on.
///
/// **A card number is not a set.** An alternate art is filed under whichever set
/// the provider files it in, and that is not always the set the number names:
/// EXB-001_p7 is listed in SC01. The payload's own 'set_code' is the set it was
/// filed under, which is the set a row belongs to, and a card's set code is that
/// value folded - see the note on folding below.
///
/// **The page size is the provider's, not the caller's.** 'limit' is capped at
/// 250 server-side and a larger value answers 250 rows rather than refusing, and
/// 'offset' pages through the filtered list. A set is therefore read page by
/// page; the largest set, GD01, is 254 products. That cap is why [_pageSize] is
/// a constant here rather than the caller's limit: asking for a set in one
/// request is not something this API can be asked to do.
///
/// **The set list is one request, and it publishes a real card count.** 28 sets,
/// each with its own 'card_count', which is the number of products the set's own
/// filter returns - so a set is complete exactly when that count matches the
/// rows stored. Nothing about a set's release is published: 'released_at' is
/// null for every set, which is a real loss against tcgcsv and is recorded in
/// the report that accompanies this file rather than papered over with a guessed
/// date.
///
/// **There is search, and it covers rules text as well as names.** 'name'
/// matches a card's name and 'effect' matches the text a card carries; both are
/// case-insensitive substring matches and both were asked live ('?name=zaku'
/// answers 39 products, '?effect=repair' answers 74). This is the whole of the
/// "no search across the game" complaint: tcgcsv has no search endpoint at all,
/// and this client answers one without downloading a set.
///
/// **A bare hyphen is the provider's way of writing "nothing here".** 213 cards
/// carry "-" as their whole rules text, 1,115 link to no pilot, 807 deploy to no
/// zone, 409 carry no trait and 6 have no block icon. A hyphen stored as rules
/// text or as a trait is a value the app would show, search and list, so every
/// text field goes through [_text], which reads a bare hyphen as absent.
///
/// **No price is quoted anywhere in a card object, and no TCGplayer product id
/// either.** [refreshPrices] therefore answers nothing rather than inventing a
/// number, and [extras] deliberately carries no 'tcgplayerId': the app reads
/// that key as the join key for price history, and a Bandai product id under it
/// would send the app looking for prices under a key no provider knows. Gundam's
/// prices still come from the tcgcsv client, which is kept for exactly this
/// reason alongside the fallback it already is.
///
/// **The codes are folded, and the fold is not a no-op here.** Every other layer
/// of the app stores, queries and compares a set code in lower case - the sets
/// table, CatalogRepository.cardsInSet, CatalogDao.isCatalogued - so TcgSet.code
/// is the provider's 'set_code' folded to letters and digits, while the
/// provider's own spelling is kept in TcgSet.id and is what a request names. The
/// filter is case-insensitive (verified live), so the folded code is a usable
/// query too and no lookup table is needed; a payload's own 'set_code' is folded
/// the same way, which makes the set-download path and the by-id path derive the
/// same string - the one place Pokemon's two paths genuinely differ.
class GundamCatalog extends CardCatalog {
  GundamCatalog({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 12),
              // The page size is bounded by the provider, so the largest
              // response is about 300 KB - a 250-product page of rules text.
              receiveTimeout: const Duration(seconds: 40),
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'Arcanum/1.0 (+https://github.com/arm00pv/arcanum)',
              },
            ),
          );

  static const _base = 'https://api.gcgapi.com/v1';

  /// The page size the provider will honour, and the largest it will honour.
  ///
  /// 'limit=500' answers 250 rows and reports its own limit in '_meta' rather
  /// than refusing, so asking for more than this buys nothing and costs a
  /// request that looks like it did more than it did.
  static const _pageSize = 250;

  /// Retries per request before giving up on a single call.
  static const _maxRetries = 3;

  /// Upper bound on the printings one search returns.
  ///
  /// The provider honours the limit it is asked for, so this is a politeness
  /// ceiling rather than a workaround: a name like "Gundam" matches 518
  /// products, and a search screen is choosing between the first few dozen.
  static const _maxSearchResults = 100;

  final Dio _dio;

  @override
  CardGame get game => CardGame.gundam;

  @override
  String get sourceName => 'gcgapi';

  // ------------------------------------------------------------------- sets

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final List<dynamic> raw;
    try {
      final Response<dynamic> res = await _retry(
        () => _dio.get<dynamic>('/sets'),
      );
      raw = _rows(res.data);
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach gcgapi',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final sets = <TcgSet>[];
    // One request carries every set, so a tick means "this set has been read"
    // rather than "this set has been downloaded".
    onProgress?.call(0, raw.length);
    for (final item in raw) {
      if (item is! Map) continue;
      final providerCode = _string(item['set_code']);
      if (providerCode == null) continue;
      final code = _slug(providerCode);
      if (code.isEmpty) continue;
      final name = _string(item['set_name']) ?? providerCode;
      sets.add(
        TcgSet(
          game: CardGame.gundam,
          // The provider's own spelling, which is what a request names.
          id: providerCode,
          // Folded, because that is the form every read path of the app
          // compares a code in - see the class comment.
          code: code,
          name: name,
          setType: _setTypeFor(code, name),
          // The provider publishes no release date for any set. A date here
          // would be invented, and the sets table sorts on that column, so an
          // invented one would order the shelf wrongly rather than harmlessly.
          cardCount: _int(item['card_count']) ?? 0,
        ),
      );
      onProgress?.call(sets.length, raw.length);
    }
    return sets;
  }

  /// Classifies a set from the two things the provider states about it.
  ///
  /// There is no taxonomy flag in the set list, so the type is read off the code
  /// and the name, exactly as the other catalogues read theirs: the promotional
  /// runs are numbered RP, EXBP and EXRP and are named "Promotion card" and
  /// "Other Product Card"; the starter decks are numbered ST01 to ST14 and the
  /// deck-build box is SC01; everything else - the booster sets, the two "Basic
  /// Cards" runs, the beta edition and the trial run T - is a retail expansion.
  /// A set-type filter is only worth offering if the split means something, and
  /// this is the split the provider's own naming describes.
  static String _setTypeFor(String code, String name) {
    final upper = code.toUpperCase();
    final lower = name.toLowerCase();
    if (upper.startsWith('RP') ||
        upper.startsWith('EXBP') ||
        upper.startsWith('EXRP') ||
        lower.contains('promotion') ||
        lower.contains('promo') ||
        lower.contains('other product')) {
      return 'promo';
    }
    if (upper.startsWith('ST') ||
        upper.startsWith('SC') ||
        upper.startsWith('SD') ||
        lower.startsWith('starter') ||
        lower.startsWith('structure') ||
        lower.startsWith('deck') ||
        lower.startsWith('intro')) {
      return 'starter';
    }
    return 'expansion';
  }

  // ------------------------------------------------------------------ cards

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final code = _slug(setCode);
    if (code.isEmpty) return const <TcgCard>[];

    final cards = <TcgCard>[];
    var offset = 0;
    var expected = 0;
    onProgress?.call(0, 0);

    while (true) {
      final Response<dynamic> res;
      try {
        res = await _retry(
          () => _dio.get<dynamic>(
            '/cards',
            queryParameters: <String, Object?>{
              // The provider's filter is case-insensitive, so the folded code
              // the app stores is a usable query and needs no lookup table.
              'set_code': code,
              'limit': '$_pageSize',
              'offset': '$offset',
            },
          ),
        );
      } on DioException catch (e) {
        // A set the provider does not know is an empty set rather than an
        // error, in the same spirit as the other catalogues: the screen should
        // say there is nothing rather than that something went wrong.
        if (e.response?.statusCode == 404) return const <TcgCard>[];
        throw CatalogException(
          e.message ?? 'Could not reach gcgapi',
          statusCode: e.response?.statusCode,
          source: sourceName,
        );
      }

      final rows = _rows(res.data);
      final meta = res.data is Map ? (res.data as Map)['_meta'] : null;
      if (meta is Map) expected = _int(meta['total']) ?? expected;
      for (final row in rows) {
        if (row is! Map) continue;
        final card = _cardFromJson(row, setCode: code);
        if (card != null) cards.add(card);
      }
      onProgress?.call(cards.length, expected == 0 ? cards.length : expected);

      // A short page is the last page. The offset test is kept as well because
      // a set whose size is an exact multiple of the page size answers one
      // empty page after its last full one, and a set already known to be
      // complete should not cost that request.
      offset += _pageSize;
      if (rows.length < _pageSize) break;
      if (expected > 0 && offset >= expected) break;
    }

    // The interface promises collector-number order and the provider's order is
    // by card number within a page but not across pages; the number and the id
    // are the sort, so the result does not depend on the order the pages
    // happened to arrive in.
    final ordered = <TcgCard>[...cards]
      ..sort((a, b) {
        final byNumber = a.collectorNumberSortKey.compareTo(
          b.collectorNumberSortKey,
        );
        if (byNumber != 0) return byNumber;
        final byPrinted = a.collectorNumber.compareTo(b.collectorNumber);
        if (byPrinted != 0) return byPrinted;
        return a.id.compareTo(b.id);
      });
    return ordered;
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    if (id.trim().isEmpty) return null;
    try {
      final res = await _retry(() => _dio.get<dynamic>('/cards/$id'));
      final data = res.data;
      final body = data is Map ? data['data'] : null;
      if (body is! Map) return null;
      return _cardFromJson(body);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw CatalogException(
        e.message ?? 'Could not reach gcgapi',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
  }

  // fetchCardsByIds is deliberately not overridden. The interface's own body
  // asks for one id at a time, and that is the right shape here: gcgapi has a
  // set filter and no ids filter, and a card's set cannot be derived from its id
  // - an alternate art is filed under a set its number does not name - so there
  // is no grouping that would answer a list of ids honestly. One request per id
  // is the true cost, and the server path is what a browser reads a signed-in
  // collection from.

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    // Two filters, because the provider keeps a card's name and its rules in
    // different fields: 'name' matches the name, 'effect' matches the text a
    // card carries, which is where "repair" or "when paired" is actually
    // answerable. Name matches lead, for the reason the Pokemon catalogue gives
    // - someone typing a card's name wants the card, not the twenty cards whose
    // text mentions it - and the two lists are deduplicated by id.
    final capped = limit.clamp(1, _maxSearchResults);
    final hits = <Map<dynamic, dynamic>>[];
    for (final field in const <String>['name', 'effect']) {
      for (final row in await _searchList(field, query, capped)) {
        if (row is Map) hits.add(row);
      }
    }

    final cards = <TcgCard>[];
    final seen = <String>{};
    for (final hit in hits) {
      final id = _string(hit['product_id']);
      if (id == null || !seen.add(id)) continue;
      final card = _cardFromJson(hit);
      if (card == null) continue;
      cards.add(card);
      if (cards.length >= capped) break;
    }
    return cards;
  }

  /// One list query against gcgapi, or nothing when it cannot be answered.
  ///
  /// A search is a convenience: a provider that is down, rate limiting or
  /// unhappy with a filter must narrow the results, never raise into the UI.
  Future<List<dynamic>> _searchList(
    String field,
    String query,
    int limit,
  ) async {
    if (query.trim().isEmpty) return const <dynamic>[];
    try {
      final res = await _retry(
        () => _dio.get<dynamic>(
          '/cards',
          queryParameters: <String, Object?>{field: query, 'limit': '$limit'},
        ),
      );
      return _rows(res.data);
    } on DioException {
      return const <dynamic>[];
    }
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    // Alternate arts are products of their own with no shared id to ask about,
    // so the repository's local cache - keyed by the oracle id every card here
    // carries, which folds the art variants of one card onto one key - is what
    // answers "every printing of this card".
    return const <TcgCard>[];
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    // A gcgapi card object quotes no price of any kind, so there is nothing to
    // re-read and no request worth making. Answering nothing leaves whatever
    // prices a card already carries in place, which is what the caller does with
    // an empty answer.
    return const <TcgCard>[];
  }

  // --------------------------------------------------------------- requests

  /// The 'data' array every gcgapi route answers with.
  ///
  /// '/sets' and '/cards' answer under an envelope carrying '_meta' and 'data';
  /// anything else - an error body, an empty answer - is an empty list rather
  /// than an exception here, because every caller has already decided what an
  /// empty answer means.
  static List<dynamic> _rows(Object? data) {
    if (data is Map) {
      final rows = data['data'];
      if (rows is List) return rows;
    }
    if (data is List) return data;
    return const <dynamic>[];
  }

  /// Retries transient failures with backoff.
  Future<Response<dynamic>> _retry(
    Future<Response<dynamic>> Function() call,
  ) async {
    var attempt = 0;
    while (true) {
      try {
        return await call();
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        final retryable = status == null || status == 429 || status >= 500;
        if (!retryable || attempt >= _maxRetries) rethrow;
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  // ---------------------------------------------------------------- mapping

  /// Builds one card from a gcgapi card object.
  ///
  /// [setCode] is the set being downloaded, which is the set a row of a set
  /// download belongs to; a card reached by its own id has no such context and
  /// takes the set code from the payload's own 'set_code', folded. Those two are
  /// the same string for every card the provider publishes - the payload's
  /// 'set_code' is the set it was filed under, which is the set it was asked for
  /// - so unlike the Pokemon catalogue the two paths derive the same row here.
  ///
  /// Returns null for an object with no 'product_id', as the other catalogues
  /// do: such a row cannot be opened, priced, deduplicated or fetched again.
  TcgCard? _cardFromJson(Map<dynamic, dynamic> data, {String? setCode}) {
    final id = _string(data['product_id']);
    if (id == null) return null;

    final number = _string(data['card_number']) ?? '';
    final payloadCode = _slug(_string(data['set_code']) ?? '');
    final code = setCode ?? payloadCode;
    final name = _string(data['name']) ?? '';
    final type = _string(data['card_type']) ?? '';
    final color = _string(data['color']) ?? '';
    final setName = _string(data['set_name']) ?? code.toUpperCase();
    final image = _string(data['image_url']);

    return TcgCard(
      game: CardGame.gundam,
      // The provider's own product id, verbatim. This is the line the whole
      // id-parity claim rests on: nothing is derived, appended or re-cased, and
      // the variant arts stay apart because the id is the product rather than
      // the number printed on it.
      id: id,
      setCode: code,
      setName: setName,
      name: name,
      // The number the card prints, minus the set prefix the set code already
      // carries: the app stores the position inside the set, which is what its
      // number search parses out of "GD01-001" and what a binder sorts by. The
      // full printed number is kept in extras.
      collectorNumber: _collectorNumberOf(number),
      rarity: _string(data['rarity']) ?? 'unknown',
      typeLine: _typeLine(data),
      oracleText: _text(data['effect']),
      // The play cost, which is the number a card costs to play and what the
      // app sorts and filters by. A card with no cost of its own leaves this
      // null rather than costing zero.
      cmc: _num(data['cost'])?.toDouble(),
      colors: <String>[if (color.isNotEmpty) color],
      colorIdentity: <String>[if (color.isNotEmpty) color],
      // A printing filed under a promotional run is a promotional card, exactly
      // as the tcgcsv adapter reads it: the provider states it as the set's own
      // name and code, and the flag travels with the card because the card is
      // what a screen has in hand.
      promo: _setTypeFor(code, setName) == 'promo',
      // One art URL per printing, at one size. It is asked for through
      // CardArt.host because Bandai's art host sends no Access-Control-Allow-
      // Origin, which is the same problem tcgcsv's CDN has and is answered the
      // same way.
      imageUris: <String, String>{
        if (image != null && image.isNotEmpty) 'normal': CardArt.host(image),
      },
      // The provider publishes no oracle identity, so a card is grouped by what
      // a collector would call it: its name and what kind of card it is. The art
      // variants of one card share both - GD01-005 and its four parallels are
      // all "Unicorn Gundam (Unicorn Mode)", UNIT - so they group, while a
      // Leader and a Unit printed under one name do not.
      oracleId: '${TcgCard.normaliseName(name)}|${_slug(type)}',
      extras: <String, Object?>{
        // Note what is NOT here: 'tcgplayerId'. The app reads that key as the
        // join key for price history, and gcgapi publishes no TCGplayer product
        // id, so a Bandai product id under it would be a number the app looked
        // prices up with and never found.
        'productId': id,
        'printedNumber': number,
        if (type.isNotEmpty) 'cardType': type,
        if (color.isNotEmpty) 'color': color,
        for (final field in const <String>[
          'zone',
          'trait',
          'link',
          'source_title',
          'block_icon',
        ])
          if (_text(data[field]) case final String value)
            _extraKey(field): value,
        for (final field in const <String>['level', 'ap', 'hp'])
          if (_int(data[field]) case final int value) field: value,
        if (_string(data['detail_url']) case final String url) 'detailUrl': url,
      },
    );
  }

  /// The type line, with the game's own extra fields appended.
  ///
  /// Gundam prints the card type, its trait in brackets, the level it can be
  /// deployed at and the zone it deploys to. The type line is what the app
  /// searches and shows, so what the provider states about a card is joined into
  /// it rather than left in fields nothing reads - and it is composed the way
  /// the tcgcsv adapter composed it for this game, so a card's line does not
  /// change shape when the source does.
  static String? _typeLine(Map<dynamic, dynamic> data) {
    final type = _string(data['card_type']) ?? '';
    final trait = _text(data['trait']) ?? _traits(data);
    final level = _int(data['level']);
    final zone = _text(data['zone']);
    final parts = <String>[
      if (type.isNotEmpty) type,
      if (trait.isNotEmpty) trait,
      if (level != null) 'Level $level',
      if (zone != null && zone.isNotEmpty) zone,
    ];
    final line = parts.join(' - ');
    return line.isEmpty ? null : line;
  }

  /// The trait list, for the cards the provider states as a list rather than as
  /// the bracketed string the card prints.
  static String _traits(Map<dynamic, dynamic> data) {
    final raw = data['traits'];
    if (raw is! List) return '';
    return raw
        .map(_text)
        .whereType<String>()
        .where((t) => t.trim().isNotEmpty)
        .join(' / ');
  }

  /// A provider field name as the extras key the app reads it under.
  static String _extraKey(String field) {
    switch (field) {
      case 'source_title':
        return 'sourceTitle';
      case 'block_icon':
        return 'blockIcon';
      default:
        return field;
    }
  }

  /// The position within the set, from the number the provider prints.
  ///
  /// gcgapi writes the number as the card prints it - GD01-001 - and the digits
  /// at the end are the position, exactly as the tcgcsv adapter read the same
  /// number for the same game. The full printed string is kept in extras.
  static String _collectorNumberOf(String printed) {
    final first = printed.trim().split(RegExp(r'\s+')).first;
    final beforeSlash = first.split('/').first;
    final match = RegExp(r'(\d+)$').firstMatch(beforeSlash);
    return match?.group(1) ?? beforeSlash;
  }

  /// Lower-cases a provider value and keeps only letters and digits, so it can
  /// sit in a set code and match what a card prints.
  static String _slug(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String? _string(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// A text field of a card object, with the provider's own "nothing here"
  /// taken out of it.
  ///
  /// gcgapi writes a bare hyphen where a card has no such thing, and a hyphen
  /// stored as rules text, a zone or a trait is a value the app would show,
  /// search and list. Nothing is what the card actually says, so nothing is what
  /// is stored.
  static String? _text(Object? raw) {
    final text = _string(raw);
    return text == '-' ? null : text;
  }

  static int? _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  static num? _num(Object? raw) {
    if (raw is num) return raw;
    return num.tryParse(raw?.toString().trim() ?? '');
  }
}
