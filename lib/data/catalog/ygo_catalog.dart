import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/api/ygo_models.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Yu-Gi-Oh! Trading Card Game card data, served by YGOPRODeck.
///
/// YGOPRODeck was chosen because it is free and keyless, and because its
/// cardinfo.php response is unusually generous: one request returns a card's
/// stats, text, artwork and current market prices, so - unlike Pokémon, which
/// needs a detail call per card - a whole set is catalogued in a single call and
/// there is nothing to enrich afterwards.
///
/// The API's shape forces four decisions worth knowing about.
///
/// **Printings are built here, not published.** The provider prices and
/// describes the *card*; the printings of that card sit alongside it in
/// card_sets. A catalogue of printings therefore has to be assembled: each
/// card_sets row becomes one [TcgCard] whose collector number comes from that
/// row's Konami code. The same card printed at two rarities inside one set
/// really is two rows, and both are kept.
///
/// **Sets are addressed by name.** The card query takes a set name through
/// `?cardset=<set name>` and answers HTTP 400 both for a code and for an unknown
/// name, so the set list is
/// kept in memory as the code-to-name index that a set download needs. Konami
/// also reuses set codes: the provider publishes 1,035 sets under 646 distinct
/// codes, and the app's `sets` table is keyed by code, so sets that share one
/// get a numeric suffix ("ys15", "ys15-2", ...) rather than overwriting each
/// other.
///
/// **Prices are per card, not per printing or finish.** card_prices holds one
/// figure per vendor for the card as a whole, in two currencies and with "0.00"
/// meaning "no market data". Only the USD figure is used as a value and it rides
/// on the non-foil finish, which is the finish the rest of the app values with;
/// the EUR figure and the other USD vendors are kept in [TcgPrices.secondary] so
/// they can be shown without ever being mistaken for the market price.
///
/// **There is no price history.** The provider answers "what is it worth today"
/// and nothing else, so Yu-Gi-Oh! trends come from the daily snapshots Arcanum
/// records itself.
///
/// Requests are throttled to ten starts a second even though the documented
/// ceiling is twenty: the limit could not be reproduced under test, the
/// documented penalty for breaching it is an hour-long ban, and a catalogue
/// download is a background cost the user never waits on twice.
class YgoCatalog implements CardCatalog {
  YgoCatalog({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _base,
              connectTimeout: const Duration(seconds: 12),
              // A large set is a megabyte of JSON in one response.
              receiveTimeout: const Duration(seconds: 30),
              headers: const {
                'Accept': 'application/json',
                'User-Agent': 'Arcanum/1.0 (+https://github.com/arcanum)',
              },
            ));

  static const _base = 'https://db.ygoprodeck.com/api/v7';

  /// How many requests run at once.
  static const _concurrency = 4;

  /// Retries per request before giving up on a single call.
  static const _maxRetries = 3;

  /// Floor on the gap between two request *starts*, i.e. ten a second.
  static const _minRequestGap = Duration(milliseconds: 100);

  /// The one set type every Yu-Gi-Oh! set carries.
  ///
  /// cardsets.php publishes no taxonomy - not even a booster/starter-deck flag -
  /// so the app is told the truth it has rather than a guess: one type, one
  /// chip in the filter row. Splitting "Starter Deck" from "Booster" by string
  /// matching on the name would mislabel the tins and the promos.
  static const _setType = 'set';

  final Dio _dio;

  /// The set list once it has been read, keyed in publication order.
  List<_YgoSet>? _sets;

  /// The in-flight set list request, so concurrent callers share one call.
  Future<List<_YgoSet>>? _loadingSets;

  @override
  CardGame get game => CardGame.yugioh;

  @override
  String get sourceName => 'YGOPRODeck';

  // ------------------------------------------------------------------- sets

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    // Every set arrives in this one response, so there is no per-set work to
    // report and [onProgress] has nothing to say beyond "in flight".
    final sets = await _ensureSets();
    return [for (final set in sets) _tcgSetOf(set)];
  }

  /// Reads and indexes the set list, memoised for the life of the catalogue.
  Future<List<_YgoSet>> _ensureSets() async {
    final loaded = _sets;
    if (loaded != null) return loaded;
    final inFlight = _loadingSets;
    if (inFlight != null) return inFlight;

    final future = _loadSets();
    _loadingSets = future;
    try {
      final sets = await future;
      _sets = sets;
      return sets;
    } finally {
      _loadingSets = null;
    }
  }

  Future<List<_YgoSet>> _loadSets() async {
    final Response<dynamic> res;
    try {
      res = await _get('/cardsets.php');
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach YGOPRODeck',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final body = _decode(res.data);
    // cardsets.php answers with a bare array - there is no wrapper object and no
    // meta block - so anything else means the endpoint changed shape.
    if (body is! List) {
      throw CatalogException(
        'YGOPRODeck published no set list',
        source: sourceName,
      );
    }

    final parsed = <_YgoSet>[];
    for (final item in body) {
      final set = _YgoSet.fromJson(item);
      if (set != null) parsed.add(set);
    }

    // Sets sharing a code are ordered oldest first so the original keeps the
    // plain code and every later reuse is the one that moves: "lob" stays the
    // 2002 set a collector means, and the 2023 anniversary printing becomes
    // "lob2". The rule depends only on provider data, so the codes stay stable
    // across refreshes and the cached cards keep resolving.
    final groups = <String, List<_YgoSet>>{};
    for (final set in parsed) {
      groups.putIfAbsent(set.providerCode, () => <_YgoSet>[]).add(set);
    }

    final reserved = {for (final set in parsed) set.providerCode.toLowerCase()};
    final assigned = <_YgoSet, String>{};
    for (final group in groups.values) {
      group.sort(_byReleaseThenName);
      for (var i = 0; i < group.length; i++) {
        final base = group[i].providerCode.toLowerCase();
        var code = base;
        var n = i;
        while (assigned.containsValue(code) ||
            (n > 0 && reserved.contains(code))) {
          n++;
          code = '$base$n';
        }
        assigned[group[i]] = code;
      }
    }

    return [for (final set in parsed) set.withCode(assigned[set] ?? set.code)];
  }

  /// Orders a group of same-coded sets oldest first, then by name.
  ///
  /// A missing release date sorts last rather than first: a set the provider
  /// forgot to date is far more likely to be a recent reprint than the original.
  static int _byReleaseThenName(_YgoSet a, _YgoSet b) {
    final da = a.releasedAt;
    final db = b.releasedAt;
    if (da != null && db != null) {
      final byDate = da.compareTo(db);
      if (byDate != 0) return byDate;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    return a.name.compareTo(b.name);
  }

  TcgSet _tcgSetOf(_YgoSet set) => TcgSet(
        game: CardGame.yugioh,
        // The set's own code is its identity here: YGOPRODeck publishes no
        // numeric set id, and every other layer already keys sets by code.
        id: set.code,
        code: set.code,
        name: set.name,
        setType: _setType,
        releasedAt: set.releasedAt,
        cardCount: set.cardCount,
        // YGOPRODeck serves a raster JPG set image or nothing at all; there is
        // no SVG symbol in the payload, so the UI draws its own glyph.
        iconSvgUri: null,
        logoUri: set.imageUrl,
        collectorNumberStart: 1,
      );

  /// Resolves a set code - or a set name - to its indexed record.
  ///
  /// Names are accepted as well as codes because the repository hands the code
  /// back lower-cased from SQLite, while callers that only hold a name (a card's
  /// printing row) should not have to look one up.
  Future<_YgoSet?> _setFor(String codeOrName) async {
    final key = codeOrName.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final set in await _ensureSets()) {
      if (set.code == key || set.name.toLowerCase() == key) return set;
    }
    return null;
  }

  /// The set index keyed by lower-cased provider set name.
  ///
  /// Empty when the set list cannot be read: every caller is expanding a card's
  /// printings, where a missing index costs only a derived set code, and failing
  /// an entire search over it would be far worse.
  Future<Map<String, _YgoSet>> _indexByName() async {
    try {
      return {
        for (final set in await _ensureSets()) set.name.toLowerCase(): set,
      };
    } on CatalogException {
      return const <String, _YgoSet>{};
    }
  }

  // ------------------------------------------------------------------ cards

  @override
  Future<List<TcgCard>> fetchCardsInSet(
    String setCode, {
    void Function(int done, int total)? onProgress,
  }) async {
    final set = await _setFor(setCode);
    if (set == null) {
      throw CatalogException(
        'No Yu-Gi-Oh! set matches "$setCode"',
        source: sourceName,
      );
    }

    // One call for the whole set, prices included. The response has no meta
    // block: a cardset query always returns every match at once.
    final page = await _page('/cardinfo.php', {'cardset': set.name});

    final out = <TcgCard>[];
    for (final card in page.cards) {
      out.addAll(_printingsOf(card, within: set));
    }
    return out;
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    final passcode = _passcodeOf(id);
    if (passcode.isEmpty) return null;

    final page = await _pageOrNull('/cardinfo.php', {'id': passcode});
    if (page == null || page.cards.isEmpty) return null;
    final card = page.cards.first;

    final index = await _indexByName();
    final setCode = _idField(id, 1);
    final printingCode = _idField(id, 2);
    final rarity = _idField(id, 3);

    for (final row in card.sets) {
      if (_slug(row.code) != printingCode) continue;
      if (rarity.isNotEmpty && _slug(row.rarity) != rarity) continue;
      final set = index[row.name.toLowerCase()];
      return _cardFor(
        card,
        row,
        setCode: set?.code ?? _codeOf(row.code),
        setName: row.name,
        releasedAt: set?.releasedAt,
      );
    }

    // The id named a printing the provider no longer lists. The card's own
    // first printing is still the right card, so it is returned under the set
    // code the id asked for rather than as a miss.
    final candidates = _printingsOf(card, index: index);
    if (candidates.isEmpty) return null;
    return setCode.isEmpty ? candidates.first : candidates.first.copyWith(setCode: setCode);
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final YgoPage? page;
    try {
      page = await _pageOrNull('/cardinfo.php', {'fname': q});
    } on CatalogException {
      // Offline, or the provider is unhappy: an empty result is the same answer
      // the user gets from any other source, and the repository keeps whatever
      // the local cache holds.
      return const [];
    }
    if (page == null) return const [];

    final index = await _indexByName();
    final out = <TcgCard>[];
    for (final card in page.cards) {
      out.addAll(_printingsOf(card, index: index));
      if (out.length >= limit) break;
    }
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    final key = groupId.trim();
    if (key.isEmpty) return const [];

    // A group id is the card's normalised name, because Yu-Gi-Oh! has no oracle
    // id: reprints are grouped by name and nothing else joins them. The app also
    // hands this method a catalogue id in places, so an id resolves the card
    // directly rather than being searched for as if it were a name.
    final byId = _looksLikeId(key);
    final YgoPage? page;
    try {
      page = await _pageOrNull(
        '/cardinfo.php',
        byId ? {'id': _passcodeOf(key)} : {'fname': key},
      );
    } on CatalogException {
      return const [];
    }
    if (page == null) return const [];

    final index = await _indexByName();
    final wanted = TcgCard.normaliseName(key);
    final out = <TcgCard>[];
    for (final card in page.cards) {
      // fname is a fuzzy match - searching "Dark Magician" also returns "Dark
      // Magician Girl" - so the name is checked exactly before it is trusted.
      if (!byId && TcgCard.normaliseName(card.name) != wanted) continue;
      out.addAll(_printingsOf(card, index: index));
    }
    return out;
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const [];

    // One request per distinct passcode: every printing of a card shares the
    // card's price, so re-reading the card reprices all of them at once.
    final byPasscode = <String, List<TcgCard>>{};
    for (final card in cards) {
      final passcode = _passcodeOf(card.id);
      if (passcode.isEmpty) continue;
      byPasscode.putIfAbsent(passcode, () => <TcgCard>[]).add(card);
    }
    if (byPasscode.isEmpty) return const [];

    final prices = <String, TcgPrices>{};
    final queue = byPasscode.keys.toList();
    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final passcode = queue.removeAt(0);
        try {
          final page = await _pageOrNull('/cardinfo.php', {'id': passcode});
          if (page == null || page.cards.isEmpty) continue;
          prices[passcode] = _pricesOf(page.cards.first.prices);
        } catch (_) {
          // A card that cannot be re-read keeps the price it already had.
        }
      }
    }

    await Future.wait(List.generate(_concurrency, (_) => worker()));

    final out = <TcgCard>[];
    for (final card in cards) {
      final fresh = prices[_passcodeOf(card.id)];
      if (fresh != null) out.add(card.copyWith(prices: fresh));
    }
    return out;
  }

  // ---------------------------------------------------------------- mapping

  /// Builds one printing per row of a card's card_sets list.
  ///
  /// [within] is set when the caller already knows which set it is inside, which
  /// is what a set download does: the rows are then filtered to that set and the
  /// set code is the one the app stored. Otherwise [index] resolves each row's
  /// set by name, so a card found through search lands in the same sets as the
  /// same card found through browsing.
  List<TcgCard> _printingsOf(
    YgoCard card, {
    _YgoSet? within,
    Map<String, _YgoSet> index = const <String, _YgoSet>{},
  }) {
    final rows = within == null
        ? card.sets
        : card.sets.where((row) => _belongsTo(row, within)).toList();

    // The provider does publish cards with no printing rows at all. Losing them
    // from search would be worse than showing one unplaced printing, so they
    // keep everything except a set.
    if (rows.isEmpty) {
      return [
        _cardFor(
          card,
          null,
          setCode: within?.code ?? '',
          setName: within?.name ?? '',
          releasedAt: within?.releasedAt,
        ),
      ];
    }

    return [
      for (final row in rows)
        _cardFor(
          card,
          row,
          setCode: (within ?? index[row.name.toLowerCase()])?.code ??
              _codeOf(row.code),
          setName: row.name.isNotEmpty
              ? row.name
              : (within?.name ?? ''),
          releasedAt: within?.releasedAt ?? index[row.name.toLowerCase()]?.releasedAt,
        ),
    ];
  }

  /// Whether a printing row belongs to [set].
  ///
  /// The set name is the provider's own join between the two endpoints, so a
  /// named row is placed by name and nothing else. The collector code cannot
  /// stand in for it: Konami reprints sets under the same code, and
  /// "LOB-EN001" is a real row in both the 2002 Legend of Blue Eyes White
  /// Dragon and its 25th Anniversary Edition, so matching on the code prefix
  /// would file the anniversary printing into the original set as well.
  ///
  /// The code prefix is therefore only consulted for a row the provider left
  /// unnamed, where it is the sole signal available and a wrong guess inside
  /// the set the caller already named is harmless.
  static bool _belongsTo(YgoCardSet row, _YgoSet set) {
    final name = row.name.trim();
    if (name.isNotEmpty) return name.toLowerCase() == set.name.toLowerCase();
    return _providerCodeOf(row.code) == set.providerCode;
  }

  /// The badge shorthand for a printing's rarity, or null when there is none.
  ///
  /// cardinfo publishes `set_rarity_code` for most rarities - "(UR)", "(ScR)",
  /// "(StR)" - but leaves it empty for a few, and those are exactly the ones the
  /// tier letters cannot describe: "Grand Master Rare" and the "New" placeholder
  /// both arrive bare, and both would otherwise render as a generic premium
  /// letter shared with half the set.
  ///
  /// The fallback is the initials of the provider's own words, so the shorthand
  /// is derived from what Yu-Gi-Oh! calls the rarity rather than from a guess.
  /// Four characters is the cap, because the badge is a pill on a dense grid
  /// tile and a longer one would start pushing the card name out.
  static String? _rarityShorthand(YgoCardSet? row) {
    final published = row?.rarityCode.trim() ?? '';
    if (published.isNotEmpty) return published;

    final words = (row?.rarity ?? '')
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;

    final initials = words.length == 1
        ? words.first
        : words.map((word) => word[0]).join();
    final upper = initials.toUpperCase();
    return upper.length <= 4 ? upper : upper.substring(0, 4);
  }

  TcgCard _cardFor(
    YgoCard card,
    YgoCardSet? row, {
    required String setCode,
    required String setName,
    DateTime? releasedAt,
  }) {
    final rarity = (row?.rarity ?? '').trim();
    final attribute = (card.attribute ?? '').trim();
    final colors = attribute.isEmpty ? const <String>[] : <String>[attribute];

    return TcgCard(
      game: CardGame.yugioh,
      id: _printingId(
        card.id,
        setCode: setCode,
        printingCode: row?.code ?? '',
        rarity: rarity,
      ),
      setCode: setCode,
      setName: setName,
      name: card.name,
      // The trailing number of the collector code is the number printed on the
      // card and the order a binder is sorted in; the region in the middle
      // ("LOB-EN001") is a printing detail, not the number.
      collectorNumber: _collectorNumberOf(row?.code ?? ''),
      rarity: rarity.isEmpty ? 'unknown' : rarity,
      // YGOPRODeck publishes no layout field and no artist at all, and keeps a
      // Normal Monster's flavour text inside desc rather than apart, so none of
      // the three is invented here. The machine-readable frame type lives in
      // extras, where a layout decision can read it.
      typeLine: card.humanReadableCardType.isNotEmpty
          ? card.humanReadableCardType
          : card.type,
      oracleText: card.description.isEmpty ? null : card.description,
      colors: colors,
      // Yu-Gi-Oh! has no separate colour-identity concept: a card's attribute is
      // its identity, so both lists carry the same single value and the shared
      // bucketing code has something to work with either way.
      colorIdentity: colors,
      releasedAt: releasedAt,
      prices: _pricesOf(card.prices),
      imageUris: _imagesOf(card),
      oracleId: TcgCard.normaliseName(card.name),
      extras: {
        'passcode': card.id,
        if (card.frameType.isNotEmpty) 'frameType': card.frameType,
        if (card.typeLine.isNotEmpty) 'types': card.typeLine,
        if (card.race != null && card.race!.isNotEmpty) 'race': card.race,
        if (card.attack != null) 'atk': card.attack,
        if (card.defense != null) 'def': card.defense,
        if (card.level != null) 'level': card.level,
        if (card.linkValue != null) 'linkRating': card.linkValue,
        if (card.linkMarkers.isNotEmpty) 'linkMarkers': card.linkMarkers,
        if (card.scale != null) 'pendulumScale': card.scale,
        if (card.archetype != null && card.archetype!.isNotEmpty)
          'archetype': card.archetype,
        // The provider's own shorthand when it publishes one, and otherwise a
        // stand-in derived from its own name for the rarity. Leaving it empty
        // would drop the badge back to a tier letter, which cannot tell Grand
        // Master Rare from any other premium rarity.
        'rarityCode': ?_rarityShorthand(row),
        if (card.banlist?.tcg != null) 'banlistTcg': card.banlist!.tcg,
        if (card.ygoprodeckUrl.isNotEmpty) 'ygoprodeckUrl': card.ygoprodeckUrl,
      },
    );
  }

  /// The catalogue id for one printing.
  ///
  /// A card's passcode identifies the card, not the printing: the same passcode
  /// is printed in every set it appears in, and one set can hold it at two
  /// rarities under one collector code. The printing therefore needs all four
  /// facts together - passcode, the set the app stored it under, the Konami
  /// code actually printed on it, and the rarity - joined by colons, and the
  /// passcode stays first so [refreshPrices] and [fetchCardById] can read it
  /// back with a split rather than a lookup.
  static String _printingId(
    int passcode, {
    required String setCode,
    required String printingCode,
    required String rarity,
  }) {
    final code = _slug(printingCode);
    final slug = _slug(rarity);
    if (setCode.isEmpty && code.isEmpty) return passcode.toString();
    return [
      passcode.toString(),
      setCode,
      code.isEmpty ? 'unplaced' : code,
      slug.isEmpty ? 'unknown' : slug,
    ].join(':');
  }

  /// The passcode inside a catalogue id, or an empty string when there is none.
  static String _passcodeOf(String id) {
    final first = id.split(':').first.trim();
    final parsed = int.tryParse(first);
    return parsed == null ? '' : parsed.toString();
  }

  /// One colon-separated field of a catalogue id, or an empty string.
  static String _idField(String id, int index) {
    final parts = id.split(':');
    return index < parts.length ? parts[index] : '';
  }

  /// True when a value is one of this catalogue's ids rather than a card name.
  ///
  /// Only the first field is inspected, and a card whose name begins with a
  /// number ("7 Colored Fish") still fails the test because the digits are
  /// followed by a space rather than a colon or the end of the string.
  static bool _looksLikeId(String value) {
    final first = value.split(':').first.trim();
    return first.isNotEmpty && int.tryParse(first) != null;
  }

  /// The collector number printed on a card, from its Konami code.
  ///
  /// "LOB-EN001" and "LOB-001" are both number 001 to a collector; the letters
  /// in the middle name a region, not a position. A code with no digits at the
  /// end keeps whatever it has, so the number is never empty.
  static String _collectorNumberOf(String code) {
    final match = RegExp(r'(\d+)$').firstMatch(code.trim());
    if (match != null) return match.group(1)!;
    final dash = code.lastIndexOf('-');
    return dash >= 0 ? code.substring(dash + 1) : code.trim();
  }

  /// The set code a collector code belongs to, e.g. "LOB" from "LOB-EN001".
  static String _providerCodeOf(String code) {
    final trimmed = code.trim().toUpperCase();
    final dash = trimmed.indexOf('-');
    return dash > 0 ? trimmed.substring(0, dash) : trimmed;
  }

  /// The app's stored set code derived from a printing that was not downloaded
  /// as part of its set, e.g. "lob" from "LOB-EN001".
  static String _codeOf(String printingCode) =>
      _providerCodeOf(printingCode).toLowerCase();

  /// Lower-cases a provider value and turns everything else into a hyphen, so it
  /// can sit inside a catalogue id without ambiguity.
  static String _slug(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  /// Maps the provider's price block onto the shared shape.
  ///
  /// The whole card carries one USD figure with no foil split, and it is placed
  /// on the non-foil finish because that is the finish every default valuation
  /// in the app uses. The foil finish is left unpriced rather than filled in with
  /// the same number: the provider does not know what a foil copy sells for, and
  /// a duplicated figure would claim it does.
  static TcgPrices _pricesOf(YgoCardPrices? prices) {
    if (prices == null) return TcgPrices.empty;
    final usd = prices.bestUsd;
    return TcgPrices(
      // A card the provider holds no data for has no key at all, so an unpriced
      // card is empty rather than priced at zero.
      byFinish: {
        CardFinish.nonfoil.code: ?usd,
      },
      secondary: {
        // cardmarket is the one EUR figure in a block of four USD ones; it is
        // labelled here so nothing downstream can show euros as dollars.
        if (prices.cardmarket != null) 'eur': prices.cardmarket,
        if (prices.ebay != null) 'ebay': prices.ebay,
        if (prices.amazon != null) 'amazon': prices.amazon,
        if (prices.coolstuffinc != null) 'coolstuffinc': prices.coolstuffinc,
      },
    );
  }

  /// The artwork URLs, keyed the way the rest of the app expects.
  ///
  /// YGOPRODeck serves three sizes and no more: a thumbnail, the full-size scan
  /// and a square art-only crop. "large" therefore points at the same file as
  /// "normal" - there is nothing bigger to point at - and the crop is kept under
  /// the app's own art key so a grid can use it without a second request.
  static Map<String, String> _imagesOf(YgoCard card) {
    final image = card.primaryImage;
    if (image == null) return const <String, String>{};
    return <String, String>{
      if (image.imageUrlSmall.isNotEmpty) 'small': image.imageUrlSmall,
      if (image.imageUrl.isNotEmpty) ...{
        'normal': image.imageUrl,
        'large': image.imageUrl,
      },
      if (image.imageUrlCropped.isNotEmpty) 'art_crop': image.imageUrlCropped,
    };
  }

  // ------------------------------------------------------------- networking

  /// Reads a cardinfo.php query that is expected to answer.
  Future<YgoPage> _page(String path, Map<String, dynamic> query) async {
    final res = await _get(path, query);
    final body = _decode(res.data);
    if (body is! Map) {
      throw CatalogException(
        'YGOPRODeck returned an unexpected body',
        source: sourceName,
      );
    }
    final data = <String, Object?>{
      for (final entry in body.entries) entry.key.toString(): entry.value,
    };
    return YgoPage.fromJson(data);
  }

  /// Reads a cardinfo.php query, treating "nothing matched" as an empty result.
  ///
  /// The provider answers an unknown passcode and an unknown set name with HTTP
  /// 400 and an error body rather than 404, so a 400 is read the way a 404 would
  /// be anywhere else: as the provider saying no such card. Anything else - a
  /// timeout, a 5xx - is still a failure and still becomes a [CatalogException].
  Future<YgoPage?> _pageOrNull(String path, Map<String, dynamic> query) async {
    try {
      return await _page(path, query);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 404) return null;
      throw CatalogException(
        e.message ?? 'Could not reach YGOPRODeck',
        statusCode: status,
        source: sourceName,
      );
    }
  }

  Future<Response<dynamic>> _get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    await _reserveSlot();
    return _retry(() => _dio.get<dynamic>(path, queryParameters: query));
  }

  /// The moment the last request was allowed to start.
  DateTime _lastStart = DateTime.fromMillisecondsSinceEpoch(0);

  /// Serialises the *start* of requests, not their completion.
  ///
  /// Chaining the reservations is what makes the rate limit hold while several
  /// workers are in flight: each caller waits its turn to be told "go", then
  /// runs concurrently with the others, so the catalogue stays inside the
  /// documented ceiling without collapsing to one request at a time.
  Future<void> _slot = Future<void>.value();

  Future<void> _reserveSlot() {
    final next = _slot.then((_) async {
      final since = DateTime.now().difference(_lastStart);
      if (since < _minRequestGap) {
        await Future<void>.delayed(_minRequestGap - since);
      }
      _lastStart = DateTime.now();
    });
    _slot = next;
    return next;
  }

  /// Retries transient failures with backoff.
  Future<Response<dynamic>> _retry(Future<Response<dynamic>> Function() call) async {
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

  /// Decodes a response body, tolerating JSON served without a JSON type.
  ///
  /// Dio only decodes by itself when the server advertises a JSON content type,
  /// and a body that arrives as a raw string would otherwise look like a
  /// malformed response.
  static Object? _decode(Object? body) {
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
}

/// One entry of cardsets.php, with the code the app stores it under.
///
/// Private because the set list has no wire model of its own: it is four fields
/// read once and indexed, not a shape the rest of the app ever sees.
class _YgoSet {
  const _YgoSet({
    required this.code,
    required this.providerCode,
    required this.name,
    required this.cardCount,
    required this.releasedAt,
    required this.imageUrl,
  });

  /// Reads one entry, or null when it carries no set name.
  ///
  /// The name is the only handle cardinfo.php accepts - a code and an unknown
  /// name are both rejected with HTTP 400 - so a nameless row could never be
  /// fetched and is dropped rather than stored as a dead entry.
  static _YgoSet? fromJson(Object? item) {
    if (item is! Map) return null;
    final name = _text(item['set_name']).trim();
    if (name.isEmpty) return null;

    final code = _text(item['set_code']).trim();
    final image = _text(item['set_image']).trim();
    final count = item['num_of_cards'];
    return _YgoSet(
      // A missing code falls back to the name, which keeps the row addressable
      // instead of collapsing every such set onto one empty code.
      providerCode: code.isEmpty ? name.toUpperCase() : code.toUpperCase(),
      code: (code.isEmpty ? name : code).toLowerCase(),
      name: name,
      cardCount: count is num ? count.toInt() : 0,
      releasedAt: DateTime.tryParse(_text(item['tcg_date']).trim()),
      imageUrl: image.isEmpty ? null : image,
    );
  }

  /// The code the app stores and navigates by, unique within the game.
  final String code;

  /// The code Konami publishes, which several sets can share.
  final String providerCode;

  /// Set name, exactly as the provider spells it - the key its card query needs.
  final String name;

  /// How many printings the set holds, by the provider's own count.
  final int cardCount;

  final DateTime? releasedAt;

  /// Raster set image URL, or null when the provider published none.
  final String? imageUrl;

  _YgoSet withCode(String value) => _YgoSet(
        code: value,
        providerCode: providerCode,
        name: name,
        cardCount: cardCount,
        releasedAt: releasedAt,
        imageUrl: imageUrl,
      );

  static String _text(Object? value) {
    if (value is String) return value;
    return value?.toString() ?? '';
  }
}
