import 'package:dio/dio.dart';

import 'package:arcanum/core/utils/codes.dart';
import 'package:arcanum/core/utils/collector_query.dart';
import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// The Digimon Card Game catalogue, from Heroicc's card database.
///
/// **Why this source.** Digimon was one of the games catalogued only through
/// tcgcsv, which republishes TCGplayer's product catalogue: on the web build those
/// games had no Sets tab until a set was opened and no search at all. Heroicc is a
/// community database built from Bandai's own card data, and - measured 2026-09-21 -
/// it answers a browser directly: every route sends `Access-Control-Allow-Origin: *`.
/// Its set list is the first of the remaining candidates that carries a real card
/// count *and a release date* per set in one request, and its ids separate the
/// alternate arts, which is the property that decides whether a holding survives a
/// move.
///
/// **What the source is, in the numbers.** 93 English releases, 7,618 cards, 3,331 of
/// them a parallel printing with an id of its own (`BT5-007_P1` to `_P4` beside
/// `BT5-007`). A release names its cards by id and nothing more, so a set download is
/// one request for the ids and one per card - which is how the Pokemon catalogue
/// already reads its own source. A card, reached by its id, names the release it is
/// filed under, so the two paths derive one row.
///
/// **What it does not have.** No price of any kind, so [refreshPrices] answers
/// nothing and [extras] deliberately carries no 'tcgplayerId' - the key the app reads
/// as the price-history join key.
///
/// **Its terms are the one thing about it that is not a technical question**, and
/// they have been read and answered rather than left standing. The data is licensed
/// CC BY-NC-SA 4.0: non-commercial, which this app is, and share-alike, which the copy
/// in Arcanum's own catalogue carries. The attribution the licence asks for is in the
/// app's own acknowledgements, and the shared catalogue holds the game for the same
/// reason it holds Gundam and Star Wars: Unlimited - a Sets tab that can list every
/// release without opening one, and a search that answers offline. See
/// docs/catalogue-import-digimon.md.
///
/// **And one clause of those terms touches the screen**: "you must not cover, crop,
/// or clip off the copyright or artist name on card images". Arcanum's tiles draw the
/// whole card at the game's own ratio, so nothing is cropped - the grid was fixed for
/// exactly that reason - and the quantity badge an owned card carries sits in the
/// top-right corner above the card's own copyright and artist line, so it covers
/// neither. That was checked against the placement in `card_thumbnail.dart` rather
/// than assumed.
class DigimonCatalog extends CardCatalog {
  DigimonCatalog({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 45),
              headers: const <String, String>{
                'Accept': 'application/vnd.api+json, application/json',
                'User-Agent': _agent,
              },
            ),
          );

  /// Where Heroicc answers.
  static const String _base = 'https://api.heroi.cc';

  static const String _agent =
      'Arcanum/1.0 (+https://github.com/arm00pv/arcanum)';

  /// The most cards one search returns, which is the source's own page size.
  static const int _maxSearchResults = 60;

  /// Retries per request before giving up on a single call.
  static const int _maxRetries = 3;

  /// The gap kept between two requests.
  ///
  /// The source is one hobbyist's server with no published rate limit and an
  /// explicit request to identify yourself and to cache. A set download is one
  /// request per card, so the gap is the difference between a polite walk and a
  /// hundred requests in a second.
  static const Duration _gap = Duration(milliseconds: 90);

  /// The rarity codes this game prints, as the words collectors read.
  ///
  /// The source states a code and nothing else - C, U, R, SR, SEC, UR and P - and
  /// the code is what a collector says out loud for this game, so it is kept in
  /// [extras] under 'rarityCode' where the app already looks for one, and the word
  /// is what the row's rarity carries.
  static const Map<String, String> _rarities = <String, String>{
    'C': 'Common',
    'U': 'Uncommon',
    'R': 'Rare',
    'SR': 'Super Rare',
    'UR': 'Ultra Rare',
    'SEC': 'Secret Rare',
    'P': 'Promo',
  };

  final Dio _dio;

  /// The folded code of every release the source lists, to its own spelling.
  ///
  /// Filled on the first set download and kept for the life of the catalogue, which
  /// is one request per session for a mapping that cannot change while the app is
  /// open.
  Map<String, String>? _slugs;

  @override
  CardGame get game => CardGame.digimon;

  @override
  String get sourceName => 'Heroicc';
  // ------------------------------------------------------------------- sets

  /// Every release the source lists, with its card count and its release date.
  ///
  /// One request, 93 releases, 22 KB: the language object's `included` array carries
  /// each release as an id and a `meta` holding its name, the number of card entries
  /// it lists and - for 87 of the 93 - the date it went on sale. That is the first
  /// source of the four that answers a set list this completely, and the date is why
  /// this game's Sets tab can sort by newest properly rather than falling back to the
  /// name order the other dateless games use.
  ///
  /// A release's `meta.cards` counts *entries*, not distinct cards: the counts sum to
  /// 7,685 while the game holds 7,541 distinct card ids, because 142 promotional
  /// cards are listed by two releases each. That is the source's own number and it is
  /// what the tile shows; what a set holds is a different fact and the app's binder
  /// slots are counted from the rows it has.
  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final Map<String, dynamic> envelope = await _get('/releases/en');
    final List<Object?> releases = _includedOf(envelope);
    final List<TcgSet> sets = <TcgSet>[];
    onProgress?.call(0, releases.length);
    for (final Object? item in releases) {
      final TcgSet? set = _set(item);
      if (set != null) sets.add(set);
      onProgress?.call(sets.length, releases.length);
    }
    return sets;
  }

  /// Classifies a release from the two things the source states about it.
  ///
  /// There is no genre in the set list - the release's own route carries one, and
  /// reading it would cost 93 requests - so the type is read off the code and the
  /// name, exactly as the Gundam and Star Wars: Unlimited catalogues read theirs. The
  /// split that matters to a collector is starters against boosters against
  /// everything else: ST-01 to ST-22 and the deck boxes are starters, BT / EX / RB /
  /// AD are the retail boosters, and the promotional, tournament, binder and
  /// limited-pack runs are the rest.
  static String _setTypeFor(String providerCode, String name) {
    final String code = providerCode.toLowerCase();
    final String lower = name.toLowerCase();
    if (code.startsWith('st-') || lower.contains('start deck')) return 'starter';
    if (code.startsWith('bt') ||
        code.startsWith('ex-') ||
        code.startsWith('rb-') ||
        code.startsWith('ad-') ||
        lower.contains('booster')) {
      return 'expansion';
    }
    return 'promo';
  }

  /// One release of the set list, as a [TcgSet].
  static TcgSet? _set(Object? item) {
    if (item is! Map) return null;
    final String? id = _string(item['id']);
    if (id == null || !id.startsWith('/releases/en/')) return null;
    final String providerCode = id.substring('/releases/en/'.length);
    if (providerCode.isEmpty) return null;
    final Map<String, dynamic> meta = _mapOf(item['meta']) ?? <String, dynamic>{};
    final String name = _string(meta['name']) ?? providerCode;
    return TcgSet(
      game: CardGame.digimon,
      // The source's own spelling, which is what a request names.
      id: providerCode,
      // Folded, because that is the form every read path of the app compares a
      // code in: `bt-08` becomes `bt08`, which is also what the card prints.
      code: Codes.fold(providerCode),
      name: name,
      setType: _setTypeFor(providerCode, name),
      releasedAt: _date(meta['date']),
      cardCount: _int(meta['cards']) ?? 0,
    );
  }

  // ------------------------------------------------------------------ cards

  /// Every card of one release: one request for the ids, one per card.
  ///
  /// A release answers its cards as ids - `{"type": "card", "id":
  /// "/cards/en/BT5-007_P3"}` - and there is no route that answers several cards at
  /// once (measured: `/cards/en` as a collection is a 404, and `?include=cards` is
  /// ignored). So a set is one request plus one per card, paced: 138 cards for
  /// NEW AWAKENING, 667 entries for the largest promotional run. It is the same
  /// shape the Pokemon catalogue already has, where every card is one request, and
  /// the progress a screen reports is cards read rather than pages.
  ///
  /// [onProgress] is given (cards so far, cards the release lists) - both from the
  /// ids, so the bar knows its length before the first card arrives.
  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final String providerCode = await slugFor(setCode);
    if (providerCode.isEmpty) return const <TcgCard>[];
    final Map<String, dynamic> envelope = await _get('/releases/en/$providerCode');
    final List<String> ids = <String>[
      for (final Object? item in _includedOf(envelope))
        if (_cardIdOf(item) case final String id) id,
    ];
    // The release's own name, from the release's own answer: a card reached
    // alone takes the release from its payload, and a card in a set download is
    // handed the release it was downloaded as part of.
    final String? releaseName = _string(
      _mapOf(_mapOf(envelope['data'])?['attributes'])?['name'],
    );
    final List<TcgCard> cards = <TcgCard>[];
    onProgress?.call(0, ids.length);
    for (final String id in ids) {
      try {
        final TcgCard? card = await fetchCardById(
          id,
          setCode: providerCode,
          setName: releaseName,
        );
        if (card != null) cards.add(card);
      } catch (_) {
        // A card that cannot be read costs that card and none of the ones behind
        // it: a set download that gave up on one 502 would leave the set half
        // stored, and the caller stores what arrived.
      }
      onProgress?.call(cards.length, ids.length);
      await Future<void>.delayed(_gap);
    }
    return cards;
  }

  /// One card by its own id.
  ///
  /// [setCode] is the release a set download is reading, and it is passed only so
  /// that the row agrees with the walk that asked for it. A card reached by its id
  /// alone takes the release from its own `relationships.releases` - the source
  /// states which release a card is filed under, and 7,541 of the 7,618 cards name
  /// one - and falls back to the set its printed number names when it names none,
  /// which is the 77 promotional cards the source files nowhere.
  @override
  Future<TcgCard?> fetchCardById(
    String id, {
    String? setCode,
    String? setName,
  }) async {
    final String clean = id.trim().replaceAll(RegExp(r'^/cards/en/'), '');
    if (clean.isEmpty) return null;
    final Map<String, dynamic> envelope;
    try {
      envelope = await _get('/cards/en/$clean');
    } on CatalogException catch (e) {
      // An id the source does not hold is a printing nobody knows rather than a
      // failure: the caller is filling in a row that already exists, and the row
      // keeps the placeholder it had.
      if (e.statusCode == 404) return null;
      rethrow;
    }
    final Object? data = envelope['data'];
    return _card(
      data,
      setCode: setCode,
      setName: setName,
      included: _includedOf(envelope),
    );
  }

  /// Several cards by id, one request each, paced.
  ///
  /// The source has no batch route, so this is [CardCatalog]'s own default with the
  /// pacing the source's terms ask for. A browser signing in asks about hundreds of
  /// printings it has never seen, and the repository bounds that to what the
  /// collection actually holds.
  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    final Map<String, TcgCard> found = <String, TcgCard>{};
    for (final String id in ids) {
      if (id.trim().isEmpty) continue;
      try {
        final TcgCard? card = await fetchCardById(id);
        if (card != null) found[card.id] = card;
      } catch (_) {
        // One id the source cannot answer for is one row that keeps its
        // placeholder; the ids behind it still have an answer coming.
      }
      await Future<void>.delayed(_gap);
    }
    return found;
  }

  /// Free-text search over the name and the number.
  ///
  /// `/search?q=` answers 60 cards at a time with a `total-cards` count beside them
  /// - measured: "agumon" is 154 cards, 60 to a page - and it matches a name or a
  /// number, which is the two things a collector types. Rules text is not searched
  /// by the source, and pretending otherwise here would answer with nothing.
  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <TcgCard>[];
    final int wanted = limit < _maxSearchResults ? limit : _maxSearchResults;
    final Map<String, dynamic> envelope = await _get(
      '/search',
      query: <String, dynamic>{'q': q},
    );
    final List<TcgCard> cards = <TcgCard>[];
    for (final Object? item in _dataOf(envelope)) {
      final TcgCard? card = _card(item);
      if (card != null) cards.add(card);
      if (cards.length >= wanted) break;
    }
    return cards;
  }

  /// The printings a collector number names, answered by the source's search.
  ///
  /// A number is what this source's search matches on: "BT8-022" answers one card,
  /// and "BT5-007" answers all five printings of it, the parallel ones included.
  /// That is the address a number is, so the query is asked as typed and the answer
  /// is kept only where the printed number or the id really carries it - a search
  /// that matched a card's *notes* would otherwise answer with the wrong row.
  @override
  Future<List<TcgCard>> fetchCardsByNumber(
    CollectorQuery query, {
    int limit = 80,
  }) async {
    final String number = query.number.trim();
    if (number.isEmpty) return const <TcgCard>[];
    // The number as the card prints it, which is what the search matches: the
    // parse hands over the part after the set ("007") and the set it guessed
    // ("bt5"), and this game prints the two joined by a dash. A bare number
    // stands on its own and is asked as typed, which is the one case where the
    // answer is every set's - and then the filter is the number alone.
    final String? candidate =
        query.codeCandidates.isEmpty ? null : query.codeCandidates.first;
    final String printed = candidate == null
        ? number
        : '${candidate.toUpperCase()}-$number';
    final String wanted = Codes.fold(printed);
    final String wantedNumber = Codes.fold(number);
    final List<TcgCard> cards = await search(printed, limit: limit);
    return <TcgCard>[
      for (final TcgCard card in cards)
        if (candidate == null
            ? Codes.fold(card.collectorNumber) == wantedNumber
            : Codes.fold(
                    (card.extras['printedNumber'] ?? '').toString(),
                  ) ==
                  wanted)
          card,
    ];
  }

  /// Nothing, because the app groups this game's printings itself.
  ///
  /// A parallel printing's id is its base card's id plus a suffix - `BT5-007_P3`
  /// beside `BT5-007` - and the oracle id the catalogue stores is the base card's, so
  /// the local cache already answers "every printing of this card" by grouping on it.
  /// The source also states the group outright as `relationships.alternate-arts`, and
  /// that is where the rule comes from rather than a second answer to keep in step.
  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async =>
      const <TcgCard>[];

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    // No price is published anywhere in a card record, so there is nothing to
    // re-read and no request worth making. Answering nothing leaves whatever prices
    // a card already carries in place, which is what the caller does with an empty
    // answer.
    return const <TcgCard>[];
  }
  /// The source's own spelling of a set code the app has folded.
  ///
  /// A screen holds a set's *code* - `bt08`, because every read path of the app
  /// folds a code to lower case with its separators gone - while this source
  /// addresses a release by `bt-08`, and the two are not recoverable from each
  /// other: the folding throws away the dash *and* the version numbering of
  /// `bt01-03-v1-0`, which folds to `bt0103v10`. So the mapping is read from the
  /// set list, once per catalogue instance, and a code the list does not carry is
  /// passed through unchanged: a 404 from the source is a clearer answer than a
  /// silently empty set.
  ///
  /// This is the one thing a live check found that the unit tests could not: the
  /// tests hand the adapter the slug, because that is what a release is addressed
  /// by, and a screen hands it the code, because that is what a set row carries.
  Future<String> slugFor(String code) async {
    final String wanted = Codes.fold(code);
    if (wanted.isEmpty) return '';
    if (_slugs == null) {
      final Map<String, dynamic> envelope = await _get('/releases/en');
      _slugs = <String, String>{
        for (final Object? item in _includedOf(envelope))
          if (_releaseSlug(item) case final String slug) Codes.fold(slug): slug,
      };
    }
    return _slugs![wanted] ?? code.trim();
  }

  /// The release slug inside one entry of the set list, or null.
  static String? _releaseSlug(Object? item) {
    if (item is! Map) return null;
    final String? id = _string(item['id']);
    if (id == null || !id.startsWith('/releases/en/')) return null;
    final String slug = id.substring('/releases/en/'.length);
    return slug.isEmpty ? null : slug;
  }

  // --------------------------------------------------------------- requests

  /// One read of the source, as the JSON:API envelope it answers under.
  ///
  /// Success is `{data, included, links}`; a refusal is `{errors: [...]}` with the
  /// status. A refusal is turned into a [CatalogException] here rather than read as an
  /// empty answer somewhere above, because an empty answer is a real answer from this
  /// source - a release with no cards, a search with no hits - and the two must not
  /// look alike.
  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
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
      final Object? errors = envelope['errors'];
      if (errors is List && errors.isNotEmpty) {
        final Map<String, dynamic>? first = _mapOf(errors.first);
        throw CatalogException(
          _string(first?['detail']) ??
              _string(first?['title']) ??
              'the card database refused the request',
          statusCode: response.statusCode,
          source: sourceName,
        );
      }
      return envelope;
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach the Digimon card database',
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

  /// The rows of an answer: one route answers an array, the card route one object.
  static List<Object?> _dataOf(Map<String, dynamic> envelope) {
    final Object? data = envelope['data'];
    if (data is List) return data;
    if (data is Map) return <Object?>[data];
    return const <Object?>[];
  }

  /// What a route says beside the rows: releases, for the routes that name them.
  static List<Object?> _includedOf(Map<String, dynamic> envelope) {
    final Object? included = envelope['included'];
    return included is List ? included : const <Object?>[];
  }

  /// The card id inside one entry of a release's `included` array, or null.
  static String? _cardIdOf(Object? item) {
    if (item is! Map) return null;
    final String? id = _string(item['id']);
    if (id == null || !id.startsWith('/cards/en/')) return null;
    final String clean = id.substring('/cards/en/'.length);
    return clean.isEmpty ? null : clean;
  }

  // ---------------------------------------------------------------- mapping

  /// Builds one card from the source's card object.
  ///
  /// **The id is the source's own**, the id in its path: `BT8-022`, or `BT5-007_P3`
  /// for a parallel printing, which is a card of its own with a collector number and a
  /// price of its own. 3,331 of the game's 7,618 cards carry such a suffix, so an id
  /// derived from the printed number would collapse a quarter of the game onto half as
  /// many rows and silently merge a collector's two holdings into one.
  ///
  /// **The oracle id is the base card's**, which is the id with the parallel suffix
  /// taken off: the source states the grouping outright as `relationships.alternate-
  /// arts`, and `BT5-007` names `_P1` to `_P4` as its own. The app's "other printings"
  /// list and its binder slots both group on it.
  ///
  /// **The set code is the release the card is filed under**, taken from
  /// `relationships.releases` - 7,541 of 7,618 cards name one, 142 name two and 77
  /// name none - and falling back to the set its printed number names. The two are
  /// not always the same: a pre-release winner is printed BT5-007 and filed under
  /// bt-08, and it is filed there because that is where a collector finds it.
  TcgCard? _card(
    Object? data, {
    String? setCode,
    String? setName,
    List<Object?> included = const <Object?>[],
  }) {
    if (data is! Map) return null;
    final String? rawId = _string(data['id']);
    if (rawId == null || !rawId.startsWith('/cards/en/')) return null;
    final String id = rawId.substring('/cards/en/'.length);
    if (id.isEmpty) return null;
    final Map<String, dynamic>? attributes = _mapOf(data['attributes']);
    if (attributes == null) return null;

    final List<String> releases = _releasesOf(Map<String, dynamic>.from(data));
    // The card's own record decides the release, and the walk it arrived in is
    // only a fallback. That matters for the 142 cards the source files under two
    // releases - a premium parallel listed by its own promotion and by the binder
    // set it was reprinted in - because one card is one row here: the walk that
    // read it last would otherwise decide, so the same card would sit in a
    // different set depending on the order the releases happened to be walked in.
    // The first release a card names is the source's own answer, and it is the
    // order the by-id path has always used.
    final String providerCode = releases.isNotEmpty
        ? releases.first
        : (setCode ?? _codeOfNumber(attributes['number']));
    final String code = Codes.fold(providerCode);
    final String name = _string(attributes['name']) ?? '';
    final String number = _string(attributes['number']) ?? '';
    final String? rarityCode = _string(attributes['rarity']);
    final String? image = _string(attributes['image']);
    final List<String> colors = _names(attributes['color']);
    final String? category = _string(attributes['category']);
    final num? playCost =
        _num(attributes['play-cost']) ?? _num(attributes['use-cost']);
    final num? parallelId = _num(attributes['parallel-id']);

    return TcgCard(
      game: CardGame.digimon,
      // The source's own id, verbatim - see the method comment.
      id: id,
      setCode: code,
      // The release the row is filed under names itself in the card's own
      // envelope; the walk's own answer is only a fallback for a card whose
      // envelope does not carry the release it names.
      setName:
          _setNameOf(included, providerCode) ?? setName ?? code.toUpperCase(),
      name: name,
      collectorNumber: _collectorNumberOf(number),
      rarity: _rarities[rarityCode] ?? rarityCode ?? 'unknown',
      typeLine: _typeLine(attributes),
      oracleText: _oracleText(attributes),
      // The play cost, which is what a card costs to play and what the app sorts
      // and filters by; an option card states a use cost instead. A card with
      // neither leaves this null rather than costing zero.
      cmc: playCost?.toDouble(),
      colors: colors,
      colorIdentity: colors,
      // One art URL per printing, at one size. Heroicc's image host sends no
      // Access-Control-Allow-Origin, so a browser reads it through Arcanum's
      // relay - which CardArt.host applies on a web build only, leaving the
      // address a phone reads as the source's own.
      imageUris: <String, String>{
        if (image != null && image.isNotEmpty) 'normal': CardArt.host(image),
      },
      // The base card's id, so the parallel printings of one card group together
      // in the app exactly as the source's own alternate-arts relation does.
      oracleId: _baseIdOf(id),
      extras: <String, Object?>{
        // Note what is NOT here: 'tcgplayerId'. The app reads that key as the join
        // key for price history, and Heroicc publishes no TCGplayer product id, so
        // one under it would be a number the app looked prices up with and never
        // found.
        'number': number,
        'printedNumber': number,
        'rarityCode': ?rarityCode,
        'category': ?category,
        'parallelId': ?parallelId,
        if (releases.isNotEmpty) 'releases': releases,
        for (final String field in const <String>[
          'type',
          'form',
          'attribute',
          'level',
          'dp',
          'play-cost',
          'use-cost',
          'block-icon',
          'supplemental-rarity',
        ])
          if (attributes[field] != null) field: attributes[field],
      },
    );
  }

  /// The type line, as the app shows and searches it.
  ///
  /// The source states a card's category, its species, the level it sits at and the
  /// form it takes; the type line is what the app shows under a name, so they are
  /// joined into it rather than left in fields nothing reads.
  static String? _typeLine(Map<String, dynamic> attributes) {
    final String category = _string(attributes['category']) ?? '';
    final String species = _string(attributes['type']) ?? '';
    final String form = _string(attributes['form']) ?? '';
    final int? level = _int(attributes['level']);
    final List<String> parts = <String>[
      if (category.isNotEmpty) _categoryLabel(category),
      if (species.isNotEmpty) species,
      if (form.isNotEmpty) form,
      if (level != null) 'Lv.$level',
    ];
    final String line = parts.join(' - ');
    return line.isEmpty ? null : line;
  }

  /// The rules text, with the box a card prints under it.
  ///
  /// A Digimon card prints an inherited effect in its own box at the foot of the
  /// card, and a security effect on the reverse for the cards that have one. They are
  /// the card's text as far as a collector - and as far as a search over text - is
  /// concerned, so they are joined into the field the app searches, in the order the
  /// card prints them.
  static String? _oracleText(Map<String, dynamic> attributes) {
    final List<String> parts = <String>[];
    for (final String field in const <String>[
      'effect',
      'inherited-effect',
      'security-effect',
    ]) {
      final String? value = _string(attributes[field]);
      if (value != null) parts.add(value);
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// The releases a card is filed under, as the source's own codes.
  static List<String> _releasesOf(Map<String, dynamic> data) {
    final Map<String, dynamic>? relationships = _mapOf(data['relationships']);
    final Map<String, dynamic>? releases = _mapOf(relationships?['releases']);
    final Object? rows = releases?['data'];
    if (rows is! List) return const <String>[];
    return <String>[
      for (final Object? row in rows)
        if (row is Map)
          if (_string(row['id']) case final String id)
            if (id.startsWith('/releases/en/')) id.substring('/releases/en/'.length),
    ];
  }

  /// What the source calls the release [providerCode] names, from the answer's own
  /// `included` array - the object is embedded, so the name costs nothing.
  static String? _setNameOf(List<Object?> included, String providerCode) {
    final String wanted = '/releases/en/$providerCode';
    for (final Object? item in included) {
      if (item is! Map) continue;
      if (_string(item['id']) != wanted) continue;
      final Map<String, dynamic>? meta = _mapOf(item['meta']);
      final String? name = _string(meta?['name']);
      if (name != null) return name;
    }
    return null;
  }

  /// The card id without the parallel suffix: the base card this printing is one of.
  static String _baseIdOf(String id) {
    final int underscore = id.lastIndexOf('_');
    if (underscore <= 0) return id;
    final String suffix = id.substring(underscore + 1);
    if (suffix.isEmpty || suffix.length > 3) return id;
    return id.substring(0, underscore);
  }

  /// The position within the set, from the number the card prints.
  ///
  /// The source writes the number as the card prints it - BT8-022 - and the digits
  /// at the end are the position, exactly as the other catalogues read the same
  /// number. A number with no dash is kept whole rather than guessed at.
  static String _collectorNumberOf(String printed) {
    final String first = printed.trim().split(RegExp(r'\s+')).first;
    final int dash = first.lastIndexOf('-');
    if (dash < 0 || dash == first.length - 1) return first;
    return first.substring(dash + 1);
  }

  /// The set a printed number names, for a card the source files under no release.
  static String _codeOfNumber(Object? number) {
    final String printed = _string(number) ?? '';
    final int dash = printed.indexOf('-');
    if (dash <= 0) return printed.toLowerCase();
    return printed.substring(0, dash).toLowerCase();
  }

  /// The word the app shows for a category the source spells in lower case.
  static String _categoryLabel(String category) {
    switch (category) {
      case 'digimon':
        return 'Digimon';
      case 'digi-egg':
        return 'Digi-Egg';
      case 'tamer':
        return 'Tamer';
      case 'option':
        return 'Option';
      default:
        return category;
    }
  }

  /// The names of a field that holds a list of strings, in the order given.
  static List<String> _names(Object? raw) {
    if (raw is! List) return const <String>[];
    return <String>[
      for (final Object? item in raw)
        if (_string(item) case final String name) name,
    ];
  }

  static Map<String, dynamic>? _mapOf(Object? raw) {
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  static String? _string(Object? raw) {
    final String text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
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

  /// A release date, which the source writes as `2022-05-13` or does not write.
  static DateTime? _date(Object? raw) {
    final String? text = _string(raw);
    if (text == null) return null;
    return DateTime.tryParse(text);
  }
}
