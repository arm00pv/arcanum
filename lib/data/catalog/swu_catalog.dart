import 'package:dio/dio.dart';

import 'package:arcanum/core/utils/codes.dart';
import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// The Star Wars: Unlimited catalogue, from the publisher's own card database.
///
/// **Why this source.** Star Wars: Unlimited was one of the games catalogued only
/// through tcgcsv, which republishes TCGplayer's product catalogue: on the web
/// build those games had no Sets tab until a set was opened and no search at all.
/// Fantasy Flight publishes the game's English card database itself, and -
/// measured 2026-09-21 - it answers a browser directly: the JSON echoes
/// `Access-Control-Allow-Origin` back, and the card pictures on
/// `cdn.starwarsunlimited.com` carry `*`. This is the first game whose move needs
/// no relay of ours in the path, for its data or for its art.
///
/// **What it does not have.** No price of any kind: no key matching /price/i
/// appears anywhere in a 250-record page, and no TCGplayer product id, so
/// [refreshPrices] answers nothing and [extras] deliberately carries no
/// 'tcgplayerId' - the key the app reads as the price-history join key. No
/// release date either: the set records carry the CMS publish date, which is
/// months before the street date (Spark of Rebellion is published 2023-11-28 and
/// released 2024-03-08), and an invented date would order the sets shelf wrongly
/// rather than harmlessly.
///
/// **The page is heavy, and the numbers are not what they look like.** One page of
/// 250 records is 3.4 MB, because every record embeds its expansion, three art
/// objects, every localization and a styled HTML body; the whole game is 9,979
/// records and 135 MB. `cardNumber` on a variant record is not the number printed
/// on the card - a hyperspace Luke carries 1 where its base card carries 5 - so a
/// variant takes its collector number from the base record it points at with
/// `variantOf`, and its own serial is kept in extras. The 9,979 records carry
/// 3,022 base printings; the rest are the treatments a collector chases
/// (hyperspace, foil, prestige, showcase, weekly play, convention and judge
/// promos), and every one of them is stored, because a hyperspace card is a card
/// somebody owns.
///
/// The one thing dropped is tokens - `Token Upgrade`, `Token Unit`, `Credit Token`
/// and `Force Token`, 70 records that nothing holds and that would otherwise
/// appear in search as cards. Spark of Rebellion is 991 records and 254 bases, two
/// of them tokens: 252, which is the number printed on the cards.
class SwuCatalog extends CardCatalog {
  SwuCatalog({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 15),
              // A 250-record page is 3.4 MB and takes about half a second; the
              // ceiling is for the slow page rather than for the average one.
              receiveTimeout: const Duration(seconds: 60),
              headers: const <String, String>{
                'Accept': 'application/json',
                'User-Agent': _agent,
              },
            ),
          );

  /// Where the publisher's own card database answers.
  ///
  /// An undocumented, unversioned internal API: the paths were read out of the
  /// site's own requests rather than out of documentation, and it may change
  /// without notice. Everything this file relies on was measured on 2026-09-21
  /// and is stated where it is used.
  static const String _base = 'https://admin.starwarsunlimited.com/api/';

  static const String _agent =
      'Arcanum/1.0 (+https://github.com/arm00pv/arcanum)';

  /// The page size the source will honour, and the largest it will honour.
  ///
  /// Asking for 1000 answers 250 records rather than refusing, so a larger
  /// request buys nothing and only looks like it did more than it did.
  static const int _pageSize = 250;

  /// The most cards one search will return.
  static const int _maxSearchResults = 100;

  /// How many ids travel in one `\$in` filter.
  ///
  /// The filter is a query string rather than a body, and 40 ids of ten digits is
  /// about 700 characters - inside every proxy's idea of a URL, and a small
  /// fraction of the source's own page size.
  static const int _idChunk = 40;

  /// Retries per request before giving up on a single call.
  static const int _maxRetries = 3;

  /// The gap kept between two requests.
  ///
  /// The source publishes no rate limit and asks for nothing, and it is somebody
  /// else's server: an import walks 40 pages of 3.4 MB and a set download walks
  /// four or five, so pacing costs a second or two in total.
  static const Duration _gap = Duration(milliseconds: 120);

  /// The card types that are not cards.
  ///
  /// A token is printed on the same sheet as everything else and is listed by the
  /// publisher alongside the cards, but nothing holds one in a binder and no
  /// collector records one: a search that answered with Shield and Experience
  /// would be answering with the wrong things.
  static const Set<String> _tokens = <String>{
    'Token Upgrade',
    'Token Unit',
    'Credit Token',
    'Force Token',
  };

  /// The filter that leaves base printings of cards, and nothing else.
  ///
  /// Measured on Spark of Rebellion: 991 records, 254 with no `variantOf`, 252
  /// once the four token types are excluded - which is the set size printed on the
  /// cards.
  static const Map<String, dynamic> _baseOnly = <String, dynamic>{
    'filters[variantOf][\$null]': 'true',
    'filters[type][name][\$notIn][0]': 'Token Upgrade',
    'filters[type][name][\$notIn][1]': 'Token Unit',
    'filters[type][name][\$notIn][2]': 'Credit Token',
    'filters[type][name][\$notIn][3]': 'Force Token',
  };

  final Dio _dio;

  @override
  CardGame get game => CardGame.starWarsUnlimited;

  @override
  String get sourceName => 'FFG';
  // ------------------------------------------------------------------- sets

  /// Every set the publisher lists, with the number of cards printed in it.
  ///
  /// **The list is one small request; the counts are one small request each.**
  /// `card-expansions` answers 27 sets in 7 KB with their code, name and a CMS
  /// ordering value, and carries no card count of any kind. Asking the card list
  /// to count is the only way to a count, so each set is counted with a
  /// one-record read of its own whose pagination envelope carries the total: 27
  /// requests of about 10 KB, against the 135 MB it would cost to fold the set
  /// list - and the counts - out of the card list itself.
  ///
  /// What is counted is the set's **base printings**: the records that are not a
  /// version of another card and not a token. That is the number printed on the
  /// cards and the number a player knows - 252 for Spark of Rebellion, where the
  /// same filter answers 991 for every record in the set. The completion bar on
  /// the set screen does not use this number: it counts the binder slots the app
  /// holds, and those collapse a card's treatments onto one slot, because that is
  /// what a binder does.
  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final Map<String, dynamic> listing = await _list(
      'card-expansions',
      <String, dynamic>{'locale': 'en', 'pagination[pageSize]': '100'},
    );

    final List<({String providerCode, String name})> named =
        <({String providerCode, String name})>[];
    for (final Object? item in _rowsOf(listing)) {
      final Map<String, dynamic>? attributes = _attributesOf(item);
      if (attributes == null) continue;
      final String? providerCode = _string(attributes['code']);
      if (providerCode == null) continue;
      named.add((
        providerCode: providerCode,
        name: _string(attributes['name']) ?? providerCode,
      ));
    }
    if (named.isEmpty) return const <TcgSet>[];

    // One tick per set as its count is read: the first request carries every name
    // and the rest carry one number each, so a screen can say how far along the
    // list is.
    onProgress?.call(0, named.length);
    final List<TcgSet> sets = <TcgSet>[];
    for (final ({String providerCode, String name}) entry in named) {
      sets.add(
        TcgSet(
          game: CardGame.starWarsUnlimited,
          // The publisher's own spelling, which is what a request names.
          id: entry.providerCode,
          // Folded, because that is the form every read path of the app compares
          // a code in.
          code: Codes.fold(entry.providerCode),
          name: entry.name,
          setType: _setTypeFor(entry.providerCode, entry.name),
          cardCount: await _baseCount(entry.providerCode),
        ),
      );
      onProgress?.call(sets.length, named.length);
      if (sets.length < named.length) await Future<void>.delayed(_gap);
    }
    return sets;
  }

  /// How many base printings one set holds, from its own pagination envelope.
  Future<int> _baseCount(String providerCode) async {
    final Map<String, dynamic> envelope = await _list(
      'card-list',
      _cardsQuery(expansion: providerCode, pageSize: 1, extra: _baseOnly),
    );
    return _totalOf(envelope);
  }

  /// Classifies a set from the two things the publisher states about it.
  ///
  /// There is no taxonomy field, so the type is read off the code and the name,
  /// exactly as the Gundam catalogue reads it. Unlimited's product line is small
  /// and its naming is explicit: the convention, judge, event, gift, promo and
  /// movie runs are named for what they are, and the weekly-play runs are named
  /// for the set they belong to. Everything else is a retail expansion, which is
  /// what a code like SOR, SHD, TWI, JTL, LOF, SEC, LAW, ASH or HMW names.
  static String _setTypeFor(String providerCode, String name) {
    final String upper = providerCode.toUpperCase();
    final String lower = name.toLowerCase();
    // The name is read before the code, and the weekly-play runs are why: JTLP
    // is "Jump to Lightspeed Weekly Play" and its code begins with J, while
    // LOFP, SECP and LAWP are the same kind of run under codes that begin with
    // L, S and L. Reading the code first typed one of the four as a promo run
    // and the other three as weekly play, which is one kind of set split in two
    // by the first letter of its code.
    if (lower.contains('weekly play')) return 'weekly';
    if (lower.contains('intro battle')) return 'starter';
    if (lower.contains('promo') ||
        lower.contains('convention') ||
        lower.contains('judge') ||
        lower.contains('exclusive') ||
        lower.contains('prize') ||
        lower.contains('event pack') ||
        lower.contains('gamegenic')) {
      return 'promo';
    }
    if (upper.startsWith('P') || upper.startsWith('J') || upper.startsWith('C')) {
      return 'promo';
    }
    return 'expansion';
  }

  // ------------------------------------------------------------------ cards

  /// Every printing of one set, token records left out.
  ///
  /// The set is named by the folded code the app keeps and sent as the
  /// publisher's own spelling, which is the upper case of it: every code this
  /// game prints is letters and digits with nothing between them (SOR, TWI, C24,
  /// ASH), so the fold the app applies on the way in is undone by upper-casing,
  /// and no set needs a lookup table to be asked about.
  ///
  /// Paged, because a set is 4 or 5 pages: Secrets of Power is 1,197 records and
  /// Spark of Rebellion 991. [onProgress] reports records read against the total
  /// the source states, which is the number of *records* in the set rather than
  /// the number of cards, so the last tick is short by the tokens it skips.
  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final String code = setCode.trim().toUpperCase();
    if (code.isEmpty) return const <TcgCard>[];

    final List<TcgCard> cards = <TcgCard>[];
    var page = 1;
    while (true) {
      final Map<String, dynamic> envelope = await _list(
        'card-list',
        _cardsQuery(expansion: code, page: page),
      );
      final List<Object?> rows = _rowsOf(envelope);
      final int total = _totalOf(envelope);
      for (final Object? row in rows) {
        final TcgCard? card = _card(row);
        if (card != null) cards.add(card);
      }
      onProgress?.call(cards.length, total);
      // A short page is the last page. The count is not the test: it counts
      // records and this method has dropped some of them.
      if (rows.length < _pageSize || page > 80) break;
      page++;
      await Future<void>.delayed(_gap);
    }
    return cards;
  }

  /// One printing by its own id, which is the publisher's `cardUid`.
  @override
  Future<TcgCard?> fetchCardById(String id) async {
    final String uid = id.trim();
    if (uid.isEmpty) return null;
    final Map<String, dynamic> envelope = await _list(
      'card-list',
      <String, dynamic>{
        'locale': 'en',
        'pagination[pageSize]': '1',
        'filters[cardUid][\$eq]': uid,
      },
    );
    for (final Object? row in _rowsOf(envelope)) {
      final TcgCard? card = _card(row);
      if (card != null) return card;
    }
    return null;
  }

  /// Several printings by id, in batches of [_idChunk].
  ///
  /// `filters[cardUid][$in][0..n]` answers a whole batch in one request - measured
  /// at three ids in one read - which is what a browser signing in needs: it holds
  /// a list of ids out of its own SQLite and none of the cards behind them, and one
  /// request per id is hundreds of requests for one screen.
  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    final Map<String, TcgCard> found = <String, TcgCard>{};
    final List<String> wanted = <String>[
      for (final String id in ids)
        if (id.trim().isNotEmpty) id.trim(),
    ];
    for (var start = 0; start < wanted.length; start += _idChunk) {
      final int end = start + _idChunk < wanted.length
          ? start + _idChunk
          : wanted.length;
      final List<String> chunk = wanted.sublist(start, end);
      final Map<String, dynamic> query = <String, dynamic>{
        'locale': 'en',
        'pagination[pageSize]': _idChunk.toString(),
      };
      for (var i = 0; i < chunk.length; i++) {
        query['filters[cardUid][\$in][$i]'] = chunk[i];
      }
      final Map<String, dynamic> envelope = await _list('card-list', query);
      for (final Object? row in _rowsOf(envelope)) {
        final TcgCard? card = _card(row);
        if (card != null) found[card.id] = card;
      }
      if (end < wanted.length) await Future<void>.delayed(_gap);
    }
    return found;
  }
  // ----------------------------------------------------------------- search

  /// Free-text search over the card's name, its subtitle and its rules text.
  ///
  /// `filters[$or][n][field][$containsi]` is one request over three fields -
  /// measured: "luke" answers 65 records, and "shield token" answers 417 out of
  /// the rules text. A name, a subtitle and a sentence of a card's text are the
  /// three things a collector types, and this is the first catalogue of this game
  /// that can answer any of them.
  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <TcgCard>[];
    final int wanted = limit < _maxSearchResults ? limit : _maxSearchResults;
    final Map<String, dynamic> envelope = await _list(
      'card-list',
      <String, dynamic>{
        'locale': 'en',
        'pagination[pageSize]': wanted.toString(),
        'filters[\$or][0][title][\$containsi]': q,
        'filters[\$or][1][subtitle][\$containsi]': q,
        'filters[\$or][2][text][\$containsi]': q,
      },
    );
    return _cardsOf(envelope);
  }

  /// The printings a collector number names, answered by the source.
  ///
  /// The default in [CardCatalog] answers nothing, because a source that can only
  /// be asked in words answers a number with noise. This one can be asked in
  /// numbers: `filters[cardNumber][$eq]=5` is a filter the source applies, so
  /// "SOR 005" is two fields of one request rather than a scan of the cache.
  ///
  /// A variant answers to its base card's number - that is what the catalogue
  /// stores - so typing 5 finds Luke Skywalker and its hyperspace printing both,
  /// which is what a collector typing a number is asking for. The first set code
  /// the parse offered that answers anything wins, and a bare number is asked
  /// without a set, which is the one case where the answer is every set's.
  @override
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) async {
    // Every number this game prints is digits and nothing else - 001 to 503 - so
    // a number with anything after it is not a number this game has, and the
    // answer is nothing rather than the number with the letters cut off it.
    final Match? digits = RegExp(r'^[0-9]+$').firstMatch(query.number);
    if (digits == null) return const <TcgCard>[];
    final int number = int.parse(digits.group(0)!);

    final List<String?> codes = <String?>[
      for (final String candidate in query.codeCandidates)
        candidate.trim().toUpperCase(),
      if (query.standalone) null,
    ];
    for (final String? code in codes) {
      final Map<String, dynamic> envelope = await _list(
        'card-list',
        _cardsQuery(expansion: code, number: number, pageSize: limit),
      );
      final List<TcgCard> cards = _cardsOf(envelope);
      if (cards.isNotEmpty) return cards;
      await Future<void>.delayed(_gap);
    }
    return const <TcgCard>[];
  }

  /// Nothing, because the app groups this game's printings itself.
  ///
  /// Every printing of one card points at its base with `variantOf`, and the
  /// catalogue stores that link as the row's oracle id, so the local cache already
  /// answers "every printing of this card" by grouping on it. The source has no
  /// route that would answer it better, and a second one would be a second answer
  /// to keep in step.
  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    // No price is published anywhere in a card record, so there is nothing to
    // re-read and no request worth making. Answering nothing leaves whatever
    // prices a card already carries in place, which is what the caller does with
    // an empty answer.
    return const <TcgCard>[];
  }

  // --------------------------------------------------------------- requests

  /// The query for one read of the card list.
  static Map<String, dynamic> _cardsQuery({
    String? expansion,
    int? number,
    int pageSize = _pageSize,
    int page = 1,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => <String, dynamic>{
    'locale': 'en',
    'pagination[pageSize]': pageSize.toString(),
    'pagination[page]': page.toString(),
    'filters[expansion][code][\$eq]': ?expansion,
    'filters[cardNumber][\$eq]': ?number?.toString(),
    ...extra,
  };

  /// One read of the source, with the envelope it answers under.
  ///
  /// Every route answers `{data, meta}` on success and `{data: null, error}` on
  /// failure, so a refused request is turned into a [CatalogException] here rather
  /// than being read as an empty list somewhere above: an empty list is a real
  /// answer from this source, and the two must not look alike.
  Future<Map<String, dynamic>> _list(
    String path,
    Map<String, dynamic> query,
  ) async {
    try {
      final Response<dynamic> response = await _retry(
        () => _dio.get<dynamic>(path, queryParameters: query),
      );
      final Object? body = response.data;
      if (body is! Map) {
        throw CatalogException(
          'the card database answered with something other than an object',
          statusCode: response.statusCode,
          source: sourceName,
        );
      }
      final Map<String, dynamic> envelope = Map<String, dynamic>.from(body);
      final Object? error = envelope['error'];
      if (error is Map) {
        throw CatalogException(
          _string(error['message']) ?? 'the card database refused the request',
          statusCode: _int(error['status']) ?? response.statusCode,
          source: sourceName,
        );
      }
      return envelope;
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach the Star Wars: Unlimited card database',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
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
        final int? status = e.response?.statusCode;
        final bool retryable = status == null || status == 429 || status >= 500;
        if (!retryable || attempt >= _maxRetries) rethrow;
        attempt++;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  /// The rows of one answer, and the number of rows the source says it has.
  static List<Object?> _rowsOf(Map<String, dynamic> envelope) {
    final Object? data = envelope['data'];
    return data is List ? data : const <Object?>[];
  }

  /// The total behind an answer, from its pagination envelope.
  static int _totalOf(Map<String, dynamic> envelope) {
    final Object? meta = envelope['meta'];
    if (meta is! Map) return 0;
    final Object? pagination = meta['pagination'];
    if (pagination is! Map) return 0;
    return _int(pagination['total']) ?? 0;
  }

  /// Every row of an answer, mapped, with the ones that are not cards left out.
  List<TcgCard> _cardsOf(Map<String, dynamic> envelope) {
    final List<TcgCard> cards = <TcgCard>[];
    for (final Object? row in _rowsOf(envelope)) {
      final TcgCard? card = _card(row);
      if (card != null) cards.add(card);
    }
    return cards;
  }
  // ---------------------------------------------------------------- mapping

  /// Builds one card from a record of the publisher's card list.
  ///
  /// Returns null for a record that is not a card: no id, no expansion, or a
  /// token. Everything else about the record is a mapping rather than a decision,
  /// and the two decisions worth stating are the id and the collector number.
  ///
  /// **The id is the publisher's `cardUid`, verbatim.** It is unique over the
  /// whole game - 9,729 records of the walk carried 9,729 distinct values - and it
  /// is what survives a reprint: `cardId` is null on most records and names a
  /// related card where it is set (61 distinct values over 250 records) and
  /// `validationId` repeats (228 over 250), so neither of those is an id at all.
  ///
  /// **The collector number is the base card's.** A hyperspace, foil, prestige,
  /// showcase or promo record carries a `cardNumber` of its own that counts
  /// something other than the card - hyperspace Luke is 1 where Luke is 5, and
  /// hyperspace IG-88 is 278 where IG-88 is 12 - so a record that points at a base
  /// with `variantOf` takes the base's number, which is the one printed on the
  /// card. It also makes the app's binder slots come out right: a slot is a
  /// (name, number) pair, so a collector who owns Luke owns that slot whichever
  /// treatment they hold.
  TcgCard? _card(Object? row) {
    final Map<String, dynamic>? attributes = _attributesOf(row);
    if (attributes == null) return null;
    final String? uid = _string(attributes['cardUid']);
    if (uid == null) return null;

    final String typeName = _string(_relation(attributes['type'])?['name']) ?? '';
    if (_tokens.contains(typeName)) return null;

    final Map<String, dynamic>? expansion = _relation(attributes['expansion']);
    final String? providerCode = _string(expansion?['code']);
    if (providerCode == null) return null;
    final String setName =
        _string(expansion?['name']) ?? providerCode.toUpperCase();

    // The base card this record is a treatment of, when it is one: its id is the
    // row's grouping key and its number is the row's collector number.
    final Map<String, dynamic>? base = _relation(attributes['variantOf']);
    final String? baseUid = _string(base?['cardUid']);
    final int? printedNumber =
        _int(base?['cardNumber']) ?? _int(attributes['cardNumber']);

    final String title = _string(attributes['title']) ?? '';
    final String? subtitle = _string(attributes['subtitle']);
    final List<String> variants = _names(attributes['variantTypes']);
    final List<String> aspects = _names(attributes['aspects']);
    final List<String> traits = _names(attributes['traits']);
    final List<String> arenas = _names(attributes['arenas']);
    final List<String> keywords = _names(attributes['keywords']);
    final bool foil = variants.any(
      (String name) => name.toLowerCase().contains('foil'),
    );
    final String? art = _art(attributes);

    return TcgCard(
      game: CardGame.starWarsUnlimited,
      // The publisher's own id, verbatim - see the method comment.
      id: uid,
      setCode: Codes.fold(providerCode),
      setName: setName,
      // The name as the game prints it: a card's subtitle is half of what it is
      // called - "Luke Skywalker, Faithful Friend" - and the app shows one name
      // per card. It is also what keeps two leaders of the same name apart in a
      // binder slot.
      name: subtitle == null ? title : '$title, $subtitle',
      collectorNumber: printedNumber == null
          ? ''
          : printedNumber.toString().padLeft(3, '0'),
      rarity: _string(_relation(attributes['rarity'])?['name']) ?? 'unknown',
      typeLine: _typeLine(attributes),
      oracleText: _oracleText(attributes),
      // The play cost, which is what a card costs to play and what the app sorts
      // and filters by. A card with no cost of its own leaves this null rather
      // than costing zero.
      cmc: _num(attributes['cost'])?.toDouble(),
      colors: aspects,
      colorIdentity: aspects,
      artist: _string(attributes['artist']),
      foil: foil,
      nonfoil: !foil,
      // A printing filed under a promotional run is a promotional card, exactly
      // as the Gundam catalogue reads it - and here the set is not the only place
      // it is stated: prerelease, judge, prize-wall and movie promos sit inside a
      // retail set and are named in the printing's own variant types.
      promo:
          _setTypeFor(providerCode, setName) == 'promo' ||
          variants.any(
            (String name) =>
                name.contains('Promo') ||
                name.contains('Judge') ||
                name.contains('Prize'),
          ),
      // One art URL per printing, at one size. The publisher's CDN sends
      // Access-Control-Allow-Origin, so a browser reads it as it is and no relay
      // of ours is in the path; CardArt.host is the same call every catalogue
      // makes, and it leaves a host it does not know alone.
      imageUris: <String, String>{
        if (art case final String url) 'normal': CardArt.host(url),
      },
      // The base card's id when this record is a treatment of one, so the art
      // variants of one card group together - and the record's own id otherwise,
      // which is what a card that is its own base is grouped by.
      oracleId: baseUid ?? uid,
      extras: <String, Object?>{
        // Note what is NOT here: 'tcgplayerId'. The app reads that key as the
        // join key for price history, and this source publishes no TCGplayer
        // product id, so a Fantasy Flight id under it would be a number the app
        // looked prices up with and never found.
        'cardUid': uid,
        'setCode': providerCode,
        'serial': ?_string(attributes['serialCode']),
        'printedNumber': ?printedNumber,
        'variantOf': ?baseUid,
        if (variants.isNotEmpty) 'variantTypes': variants,
        'subtitle': ?subtitle,
        if (traits.isNotEmpty) 'traits': traits,
        if (arenas.isNotEmpty) 'arenas': arenas,
        if (keywords.isNotEmpty) 'keywords': keywords,
        // The combat numbers, and the two a unit upgrade states instead of
        // them. A card that does not have one is a card that does not print
        // one, so the key is absent rather than zero.
        for (final String field in const <String>[
          'power',
          'hp',
          'upgradePower',
          'upgradeHp',
        ])
          if (_num(attributes[field]) != null) field: _num(attributes[field])!,
        if (attributes['unique'] is bool) 'unique': attributes['unique'],
        if (attributes['hyperspace'] == true) 'hyperspace': true,
        if (attributes['showcase'] == true) 'showcase': true,
      },
    );
  }
  /// The type line, as the app shows and searches it.
  ///
  /// The publisher states a card's type, the second type a leader has once it is
  /// deployed, and the arena it is played into, in three relations. The type line
  /// is what the app shows under a name and what a text search reads, so the three
  /// are joined into it rather than left in fields nothing reads.
  static String? _typeLine(Map<String, dynamic> attributes) {
    final String type = _string(_relation(attributes['type'])?['name']) ?? '';
    final String deployed = _string(_relation(attributes['type2'])?['name']) ?? '';
    final List<String> arenas = _names(attributes['arenas']);
    final List<String> parts = <String>[
      if (type.isNotEmpty) type,
      if (deployed.isNotEmpty && deployed != type) deployed,
      ...arenas,
    ];
    final String line = parts.join(' - ');
    return line.isEmpty ? null : line;
  }

  /// The rules text, with the two boxes a leader prints beside it.
  ///
  /// A leader prints an epic action and a deploy box above its rules text, and a
  /// unit with a deploy box prints one too. They are the card's text as far as a
  /// collector is concerned - and as far as a search over text is concerned - so
  /// they are joined into the field the app searches, in the order the card prints
  /// them.
  static String? _oracleText(Map<String, dynamic> attributes) {
    final List<String> parts = <String>[];
    for (final String field in const <String>[
      'epicAction',
      'deployBox',
      'text',
      'rules',
    ]) {
      final String? value = _text(attributes[field]);
      if (value != null) parts.add(value);
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// The picture the app draws for one record.
  ///
  /// A leader's own art is landscape - 418x300 for the leader side, with the
  /// deployed unit on the other face at 300x418 - and every card in the app is
  /// drawn at the game's portrait ratio. So a landscape card is drawn from its
  /// other face when it has one: the same card, the same character, and nothing
  /// cropped off the sides, which is what a landscape picture in a portrait tile
  /// would be.
  ///
  /// **The flag is not a leader flag, and the sample says so.** 88 records of the
  /// committed sample are landscape: 56 Leaders and 32 Bases. Every leader has the
  /// second face; a base is a landscape card with no other face at all (no base
  /// is printed portrait), so it is drawn from the only art it has and the crop is
  /// the one thing about a base that cannot be helped.
  static String? _art(Map<String, dynamic> attributes) {
    final String? front = _image(attributes['artFront']);
    final String? back = _image(attributes['artBack']);
    if (attributes['artFrontHorizontal'] == true && back != null) return back;
    return front ?? back;
  }

  /// The full-size URL of one art object, which is the size the app draws at.
  static String? _image(Object? raw) => _string(_relation(raw)?['url']);

  /// The names of a relation that holds a list, in the order given.
  static List<String> _names(Object? raw) {
    if (raw is! Map) return const <String>[];
    final Object? data = raw['data'];
    if (data is! List) return const <String>[];
    return <String>[
      for (final Object? item in data)
        if (_string(_attributesOf(item)?['name']) case final String name) name,
    ];
  }

  /// The attributes of a record or a relation, whichever shape the source used.
  ///
  /// Every route answers rows as `{id, attributes}` and relations as
  /// `{data: {id, attributes}}`, so both arrive here. A map with no `attributes`
  /// and no `data` is taken as attributes itself, which is what a test that builds
  /// one record by hand would hand over.
  static Map<String, dynamic>? _attributesOf(Object? raw) {
    if (raw is! Map) return null;
    final Object? inner = raw['attributes'];
    if (inner is Map) return Map<String, dynamic>.from(inner);
    if (raw.containsKey('data')) return null;
    return Map<String, dynamic>.from(raw);
  }

  /// The attributes of a relation, or null when the relation is empty.
  static Map<String, dynamic>? _relation(Object? raw) {
    if (raw is! Map) return null;
    return _attributesOf(raw['data']);
  }

  static String? _string(Object? raw) {
    final String text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// A text field with the source's own "nothing here" taken out of it.
  ///
  /// An empty field is null rather than an empty string, and null is what a
  /// caller decides about: a card with no epic action has no line, where an empty
  /// string would be a line with nothing on it.
  static String? _text(Object? raw) => _string(raw);

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
