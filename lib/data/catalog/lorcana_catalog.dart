import 'dart:async';

import 'package:dio/dio.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Disney Lorcana TCG card data, served by Lorcast.
///
/// Lorcast was chosen for the same reason TCGdex and YGOPRODeck were: it is
/// free and keyless with no deprecation clock. Its card objects are also
/// unusually complete - one `/sets/{set}/cards` response carries a whole set
/// with ink, stats, rarity, art and current prices - so, as with Yu-Gi-Oh!, a
/// set costs one request rather than one request per card.
///
/// Three properties of the source shape the code here.
///
/// **Names repeat and the subtitle is the identity.** Lorcana prints a dozen
/// different cards called Elsa; `version` is the only thing telling them apart,
/// so the catalogue builds "Elsa – Concerned Sister" and normalises *that* into
/// the oracle id. Grouping printings by the bare name would collapse unrelated
/// cards into one "other printings" list.
///
/// **Lorcast serves no JPEG.** Every `image_uris.digital` URL is AVIF, which
/// Flutter cannot be relied on to decode, so art is taken from TCGplayer's CDN
/// - keyed by the `tcgplayer_id` a card carries - and Lorcast's own URL is used
/// only for the printings that have no TCGplayer product at all.
///
/// **Prices and stats are per card, not per printing.** Prices arrive as
/// decimal *strings* under `usd` and `usd_foil`, which is exactly the pair of
/// finishes Lorcana physically prints, so the mapping onto [CardFinish] is
/// direct.
class LorcanaCatalog extends CardCatalog {
  LorcanaCatalog({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 12),
              // A large set - 242 cards - is roughly 300 KB in one response.
              receiveTimeout: const Duration(seconds: 40),
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'Arcanum/1.0 (+https://github.com/arcanum)',
              },
            ),
          );

  static const _base = 'https://api.lorcast.com/v0';

  /// TCGplayer's product CDN, which serves the same art as JPEG.
  static const _imageCdn = 'https://tcgplayer-cdn.tcgplayer.com/product';

  /// How many card requests run at once.
  static const _concurrency = 8;

  /// Retries per request before giving up on a single call.
  static const _maxRetries = 3;

  /// Upper bound on the printings one search will return.
  ///
  /// Lorcast answers search with full card objects rather than ids, so a hit
  /// costs nothing extra to resolve - but the endpoint returns one fixed page
  /// and ignores a `limit` parameter, so the ceiling a caller asks for is
  /// applied here instead.
  static const _maxSearchResults = 100;

  final Dio _dio;

  /// The provider's own spelling of every set code, keyed by its lowercase form.
  ///
  /// Lorcast addresses a set by a case-sensitive code - `P1` answers and `p1`
  /// does not - while every other layer of the app stores, queries and compares
  /// set codes in lowercase. Both cannot be true of one string, so the case the
  /// provider needs is kept here and the lowercase form is what the app sees.
  ///
  /// Filled from the set list, and fetched once on demand when a set is opened
  /// before that list has ever loaded.
  final Map<String, String> _canonicalCodes = <String, String>{};
  Future<void>? _codesInFlight;

  @override
  CardGame get game => CardGame.lorcana;

  @override
  String get sourceName => 'Lorcast';

  // ------------------------------------------------------------------- sets

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final List<dynamic> raw;
    try {
      final res = await _retry(() => _dio.get<dynamic>('/sets'));
      raw = _results(res.data);
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach Lorcast',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final sets = <TcgSet>[];
    // The set list is a single request that carries every set, so a tick means
    // "this set has been read", not "this set has been downloaded".
    onProgress?.call(0, raw.length);
    for (final item in raw) {
      if (item is! Map) continue;
      final code = _string(item['code']);
      if (code == null) continue;
      final name = item['name']?.toString() ?? code;
      final released = _string(item['released_at']);
      _canonicalCodes[code.toLowerCase()] = code;
      sets.add(
        TcgSet(
          game: CardGame.lorcana,
          // Lorcast addresses a set by id or by code, and the code is the short
          // handle the rest of the app stores and prints.
          id: _string(item['id']) ?? code,
          // Lowercase, because that is the casing every other layer stores and
          // queries. The provider's own spelling is kept in [_canonicalCodes] for
          // the requests that need it.
          code: code.toLowerCase(),
          name: name,
          setType: _setTypeFor(code, name),
          releasedAt: released == null ? null : DateTime.tryParse(released),
          // The list endpoint publishes no card count, and the only way to learn
          // one is to download the set, so a zero here means "not known" rather
          // than "empty" and is reported as such by the UI.
        ),
      );
      onProgress?.call(sets.length, raw.length);
    }
    return sets;
  }

  /// The provider's spelling of [code], whatever case the caller used.
  ///
  /// Answers the lowercase form unchanged when the set list has never been
  /// read, which is correct for the numbered sets and lets everything else fail
  /// as an unknown set rather than as a network error.
  Future<String> _canonicalCode(String code) async {
    final lower = code.toLowerCase();
    final known = _canonicalCodes[lower];
    if (known != null) return known;
    await _loadCodes();
    return _canonicalCodes[lower] ?? lower;
  }

  /// Reads the set list once, purely to learn the casing of its codes.
  ///
  /// A failure is swallowed: the caller falls back to the lowercase code, which
  /// still resolves every numbered set.
  Future<void> _loadCodes() {
    final pending = _codesInFlight;
    if (pending != null) return pending;
    final future = fetchAllSets().then((_) {}).catchError((Object _) {});
    _codesInFlight = future;
    return future;
  }

  /// Classifies a set from the two things Lorcast states about it.
  ///
  /// There is no taxonomy flag anywhere in the set list, so the type is read
  /// off the code and the name: the promo runs are numbered `P1`, `P2`, `P3`
  /// (with a `Q` series reserved alongside them), and the odd event set is a
  /// named promo instead - `cp`, "Challenge Promo". Everything else is a retail
  /// expansion. A set-type filter is only worth offering if the split means
  /// something, so this is the split the provider's own naming describes.
  static String _setTypeFor(String code, String name) {
    final upper = code.trim().toUpperCase();
    final isPromo =
        upper.startsWith('P') ||
        upper.startsWith('Q') ||
        name.toLowerCase().contains('promo');
    return isPromo ? 'promo' : 'expansion';
  }

  // ------------------------------------------------------------------ cards

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final Response<dynamic> res;
    // One request covers the whole set, so there is one unit of progress.
    onProgress?.call(0, 1);
    // The caller hands over the lowercase code the app stores; Lorcast wants
    // its own spelling of it, which is not always the same string.
    final canonical = await _canonicalCode(setCode);
    try {
      res = await _retry(() => _dio.get<dynamic>('/sets/$canonical/cards'));
    } on DioException catch (e) {
      // An unknown set is an empty set, not a failure: the caller asked for
      // something Lorcast does not hold, and the screen should say there is
      // nothing rather than that something went wrong. Anything else is a real
      // error and is typed like every other catalogue error, so the UI can
      // report it in the same words whichever game it came from.
      if (e.response?.statusCode == 404) return const [];
      throw CatalogException(
        e.message ?? 'Could not reach Lorcast',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final raw = _results(res.data);
    final cards = <TcgCard>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final card = _cardFromJson(item, fallbackSetCode: setCode.toLowerCase());
      if (card != null) cards.add(card);
    }

    // The interface promises collector-number order and Lorcast's own order is
    // not contractual, so the set is sorted here. The index tiebreak keeps the
    // sort stable: `24` and `24B` share a numeric prefix and must not swap
    // places from one download to the next.
    final ordered = [for (var i = 0; i < cards.length; i++) (i, cards[i])]
      ..sort((a, b) {
        final byNumber = a.$2.collectorNumberSortKey.compareTo(
          b.$2.collectorNumberSortKey,
        );
        return byNumber != 0 ? byNumber : a.$1.compareTo(b.$1);
      });

    onProgress?.call(1, 1);
    return [for (final (_, card) in ordered) card];
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    try {
      final res = await _retry(() => _dio.get<dynamic>('/cards/$id'));
      final data = res.data;
      if (data is! Map) return null;
      return _cardFromJson(data);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw CatalogException(
        e.message ?? 'Could not reach Lorcast',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final List<dynamic> raw;
    try {
      // The search endpoint answers with full card objects rather than ids, so
      // - unlike TCGdex, where every hit costs a detail call - a result is
      // showable the moment it arrives and no second request is made.
      final res = await _retry(
        () => _dio.get<dynamic>('/cards/search', queryParameters: {'q': query}),
      );
      raw = _results(res.data);
    } on DioException {
      // A search is a convenience: a provider that is down or rate limiting
      // must empty the results, never raise into the UI.
      return const [];
    }

    final ceiling = limit.clamp(1, _maxSearchResults);
    final cards = <TcgCard>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final card = _cardFromJson(item);
      if (card == null) continue;
      cards.add(card);
      // Relevance order is the provider's, so the first hits are the ones kept.
      if (cards.length >= ceiling) break;
    }
    return cards;
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    // Lorcast publishes no endpoint that answers "every printing of this card"
    // - reprints are scattered across sets with no shared id to query by - so
    // the repository falls back to the local cache, which keys reprints by the
    // oracle id this catalogue writes onto each card.
    return const [];
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const [];
    final out = <TcgCard>[];
    final queue = List<TcgCard>.from(cards);
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final card = queue.removeAt(0);
        final fresh = await fetchCardById(card.id);
        if (fresh != null) out.add(fresh);
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));
    return out;
  }

  // ---------------------------------------------------------------- mapping

  /// Builds one card from a Lorcast card object.
  ///
  /// Returns null for an object with no id: such a row cannot be opened, priced
  /// or deduplicated, and every endpoint that produces cards here filters it
  /// out rather than putting an unreachable row on screen.
  TcgCard? _cardFromJson(
    Map<dynamic, dynamic> data, {
    String? fallbackSetCode,
  }) {
    final id = _string(data['id']);
    if (id == null) return null;

    final name = _unquoted(data['name']?.toString() ?? '');
    final version = _unquoted(data['version']?.toString() ?? '');
    // Lorcana prints many different cards under one name and `version` is what
    // separates them, so the subtitle belongs in the name: a row reading only
    // "Elsa" is ambiguous between a dozen unrelated printings. The oracle id is
    // built from this same combined string, which is what keeps those printings
    // apart in the "other printings" list.
    final displayName = version.isEmpty ? name : '$name – $version';

    final set = data['set'];
    final setMap = set is Map ? set : const <dynamic, dynamic>{};
    // Lowercased for the same reason the set list is: the card's own response
    // carries the provider's spelling, and a card fetched by id has to land in
    // the same bucket as the set it was downloaded with.
    final setCode = (_string(setMap['code']) ?? fallbackSetCode ?? '')
        .toLowerCase();

    // `inks` is the full list - a handful of cards are two inks - while `ink`
    // is Lorcast's single-ink shorthand. The list wins, and the shorthand is
    // read only when the list is absent; a card with no ink at all, which the
    // promo runs contain, ends up with no colour rather than a guessed one and
    // lands in the game's uninked bucket downstream.
    final inks = _stringList(data['inks']);
    final single = _string(data['ink']);
    final colors = inks.isNotEmpty
        ? inks
        : (single == null ? const <String>[] : <String>[single]);

    final classifications = _stringList(data['classifications']);
    final legalities = data['legalities'];
    final released = _string(data['released_at']);
    final tcgplayerId = _string(data['tcgplayer_id']);

    final prices = data['prices'];
    final priceMap = prices is Map ? prices : const <dynamic, dynamic>{};

    return TcgCard(
      game: CardGame.lorcana,
      id: id,
      setCode: setCode,
      setName: _string(setMap['name']) ?? setCode,
      name: displayName,
      collectorNumber: data['collector_number']?.toString() ?? '',
      rarity: _rarityText(data['rarity']),
      typeLine: _typeLine(_stringList(data['type']), classifications),
      oracleText: _rulesText(data),
      artist: _joined(_stringList(data['illustrators'])),
      flavorText: _string(data['flavor_text']),
      cmc: (data['cost'] as num?)?.toDouble(),
      colors: colors,
      colorIdentity: colors,
      prices: TcgPrices(
        // Lorcana prints every card in both finishes, so both keys are always
        // written even when Lorcast quotes neither: a null says "no price
        // known" where a zero would say "worthless".
        byFinish: {
          CardFinish.nonfoil.code: _price(priceMap['usd']),
          CardFinish.foil.code: _price(priceMap['usd_foil']),
        },
      ),
      imageUris: _images(data, tcgplayerId),
      // Lorcana cards carry their own release date, so a card fetched by id or
      // returned by search is dated even though no set metadata was read with
      // it - unlike Pokémon, where the date only exists on the set.
      releasedAt: released == null ? null : DateTime.tryParse(released),
      oracleId: TcgCard.normaliseName(displayName),
      extras: {
        'inkwell': data['inkwell'] == true,
        'tcgplayerId': ?tcgplayerId,
        'strength': ?_int(data['strength']),
        'willpower': ?_int(data['willpower']),
        'lore': ?_int(data['lore']),
        'moveCost': ?_int(data['move_cost']),
        if (classifications.isNotEmpty) 'classifications': classifications,
        if (legalities is Map && legalities.isNotEmpty)
          'legalities': {
            for (final entry in legalities.entries)
              entry.key.toString(): entry.value,
          },
      },
    );
  }

  /// Builds the art URL set.
  ///
  /// Lorcast serves only AVIF - `image_uris.digital` is `.avif` at every size -
  /// and Flutter cannot be relied on to decode AVIF, so the JPEG on TCGplayer's
  /// CDN is used whenever the card carries the `tcgplayer_id` those URLs are
  /// keyed by. Lorcast's own URL is the fallback for the printings that do not,
  /// which in practice are the promos: they have no TCGplayer product at all,
  /// so an AVIF URL is the only art that exists for them and is the sole case
  /// in which one is ever handed out.
  static Map<String, String> _images(
    Map<dynamic, dynamic> data,
    String? tcgplayerId,
  ) {
    if (tcgplayerId != null) {
      final base = CardArt.host('$_imageCdn/$tcgplayerId');
      return {
        'small': '${base}_200w.jpg',
        'normal': '${base}_400w.jpg',
        'large': '${base}_in_1000x1000.jpg',
      };
    }

    final uris = data['image_uris'];
    final digital = uris is Map ? uris['digital'] : null;
    if (digital is Map) {
      final out = <String, String>{};
      for (final size in const ['small', 'normal', 'large']) {
        final url = _string(digital[size]);
        if (url != null) out[size] = CardArt.host(url);
      }
      if (out.isNotEmpty) return out;
    }
    return const {};
  }

  /// Composes the type line the way the card reads, e.g.
  /// `Character - Storyborn, Hero, Queen, Sorcerer` or `Action, Song`.
  ///
  /// Classifications only exist on characters, so the dash is written only when
  /// there is something on the far side of it.
  static String? _typeLine(List<String> types, List<String> classifications) {
    final joined = types.join(', ');
    if (classifications.isEmpty) return joined.isEmpty ? null : joined;
    final traits = classifications.join(', ');
    return joined.isEmpty ? traits : '$joined - $traits';
  }

  /// The card's rules text, with its keywords appended when it has any.
  ///
  /// A keyword such as "Evasive" or "Ward" is printed on the card but is not
  /// always spelled out in `text`, and search reads this field, so the keywords
  /// are joined onto the end rather than dropped.
  static String? _rulesText(Map<dynamic, dynamic> data) {
    final buffer = StringBuffer(data['text']?.toString().trim() ?? '');
    final keywords = _stringList(data['keywords']);
    if (keywords.isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(keywords.join(' · '));
    }
    final out = buffer.toString().trim();
    return out.isEmpty ? null : out;
  }

  /// Parses one of Lorcast's price strings, which arrive as decimal text.
  ///
  /// An absent or unparseable value becomes null rather than zero: a card the
  /// provider has no market for is unpriced, and showing it as $0.00 would sort
  /// it to the bottom of every value list and read as a real quote.
  static double? _price(Object? raw) {
    if (raw == null) return null;
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  /// Unwraps the two shapes Lorcast answers with.
  ///
  /// A set's cards arrive as a bare JSON array; the set list and search arrive
  /// in a `{"results": [...]}` envelope. Callers should not have to know which
  /// endpoint they called.
  static List<dynamic> _results(Object? data) {
    if (data is List) return data;
    if (data is Map) {
      final results = data['results'];
      if (results is List) return results;
    }
    return const <dynamic>[];
  }

  /// A trimmed string, or null when the field is absent or blank.
  static String? _string(Object? raw) {
    final text = raw?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  /// A display string with the provider's stray wrapping quotes removed.
  ///
  /// Twenty of Lorcast's 3,198 printings carry a subtitle that is quoted whole -
  /// the Format Coconut cards read `"Spectacular Singer"` - while others quote
  /// legitimately, as `Ursula's "Baby"` does. Only a pair that wraps the entire
  /// string is dropped, so a quoted phrase inside a subtitle survives.
  static String _unquoted(String raw) {
    final text = raw.trim();
    if (text.length < 2) return text;
    if (text.startsWith('"') && text.endsWith('"')) {
      return text.substring(1, text.length - 1).trim();
    }
    return text;
  }

  /// The rarity as a collector reads it.
  ///
  /// Lorcast spells one tier with an underscore - "Super_rare" is the only
  /// spelling the live data carries - and that string is shown verbatim on the
  /// rarity badge and used as a filter facet, so the separator is normalised
  /// here rather than left as a wire artefact in the UI.
  static String _rarityText(Object? raw) {
    final text = _string(raw);
    if (text == null) return 'unknown';
    return text
        .split('_')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
  }

  /// A whole number, or null when the field is absent or is not one.
  ///
  /// Lorcana's stats are null on the cards that have none - an Action has no
  /// strength, a Location has no lore - so a null here is a fact about the card
  /// rather than missing data.
  static int? _int(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString().trim() ?? '');
  }

  /// The non-empty string entries of a JSON list, in order.
  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return [for (final value in raw) ?_string(value)];
  }

  /// Joins a list for display, or null when there is nothing to join.
  static String? _joined(List<String> values) =>
      values.isEmpty ? null : values.join(', ');

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
}
