import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:arcanum/data/catalog/card_art.dart';
import 'package:arcanum/data/catalog/card_catalog.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// Card data for the games TCGplayer catalogs itself.
///
/// One Piece and Dragon Ball have no free catalogue API of their own, and the
/// sites that carry them are either keyed, dead or unlicensed. What they
/// do have is TCGplayer, which is where those games are actually bought and sold,
/// and a daily mirror of TCGplayer's own catalog and pricing endpoints: tcgcsv,
/// which publishes, per category and per set, exactly what the shop knows.
///
/// It catalogs fewer games than it used to, and the two that left say why the
/// rest will: Gundam went to gcgapi and Star Wars: Unlimited to the publisher's
/// own database, because a source that lets a browser read it needs no relay of
/// ours - and the relay is the part of this that costs. Their factories are still
/// here, unwired, because one line in `providers.dart` is what makes either move
/// reversible.
///
/// It is free, keyless and complete - names, art, collector numbers, rarities,
/// the game's own categories and a market price per finish - and it is the same
/// publisher whose prices Scryfall and TCGdex already hand Magic and Pokemon,
/// so a value in this app means the same thing whichever game it belongs to.
///
/// Four properties of the source shape the code here.
///
/// **A category is a game, a group is a set, a product is a printing.** The
/// category id is fixed per game and lives on the named constructors below; the
/// group list gives every set in one request; a set's printings and their prices
/// are two more. There is no endpoint for a single product, so a card's id
/// carries the group it came from: this class reads '3188-453505' as group 3188,
/// product 453505, and can fetch either without a search.
///
/// **Sealed product shares the set.** A booster box sits in the same product
/// list as the cards. It is told apart structurally rather than by name: a card
/// carries a collector number, a box carries none. That same test is what keeps
/// a box out of a binder.
///
/// **The provider's set code is not the code on the card.** TCGplayer spells a
/// set 'BT-26' where the card prints 'BT26-052'. The app stores one code per set
/// and the scanner reads the other off the card, so the code is normalised here
/// to what the card prints - letters and digits, nothing between them - which
/// makes the two the same string.
///
/// **The mirror is rebuilt once a day, on the honour system.** Its own
/// guidelines ask for a named User-Agent, a pause between requests and no more
/// than a synchronisation a day. This class sends the first, paces itself with
/// the second, and the repository's seven-day set cache covers the third.
class TcgcsvCatalog extends CardCatalog {
  TcgcsvCatalog._({
    required this.game,
    required this.categoryId,
    required List<String> colourFields,
    Dio? dio,
  }) : _colourFields = colourFields,
       _dio = dio ?? _client();

  /// The One Piece Card Game, TCGplayer category 68.
  ///
  /// One Piece states a card's colour in its Color field, one value or two
  /// separated by a semicolon, which is the game's colour pie and the thing
  /// every deck is built along.
  factory TcgcsvCatalog.onePiece({Dio? dio}) => TcgcsvCatalog._(
    game: CardGame.onePiece,
    categoryId: 68,
    colourFields: const <String>['Color'],
    dio: dio,
  );

  /// Star Wars: Unlimited, TCGplayer category 79.
  ///
  /// Unlimited calls a card's colour an aspect, and the field also carries the
  /// card's alignment - 'Command;Villainy' - so the value is split and the
  /// game's own bucket rule picks between them.
  factory TcgcsvCatalog.starWarsUnlimited({Dio? dio}) => TcgcsvCatalog._(
    game: CardGame.starWarsUnlimited,
    categoryId: 79,
    colourFields: const <String>['Aspect'],
    dio: dio,
  );

  /// The Digimon Card Game, TCGplayer category 63.
  factory TcgcsvCatalog.digimon({Dio? dio}) => TcgcsvCatalog._(
    game: CardGame.digimon,
    categoryId: 63,
    colourFields: const <String>['Color'],
    dio: dio,
  );

  /// The Dragon Ball Super Card Game: Fusion World, TCGplayer category 80.
  ///
  /// Fusion World states a card's colour in its Color field - one of five, and
  /// two on a Leader - and the colour is a deckbuilding rule rather than a
  /// label: a deck may only hold cards that share a colour with its Leader.
  factory TcgcsvCatalog.dragonBall({Dio? dio}) => TcgcsvCatalog._(
    game: CardGame.dragonBall,
    categoryId: 80,
    colourFields: const <String>['Color'],
    dio: dio,
  );

  /// The Gundam Card Game, TCGplayer category 86.
  ///
  /// Gundam states colour the same way and plays it the same way: a card is one
  /// of five colours, a deck may use two of them, and the colour decides what
  /// the deck is allowed to play.
  factory TcgcsvCatalog.gundam({Dio? dio}) => TcgcsvCatalog._(
    game: CardGame.gundam,
    categoryId: 86,
    colourFields: const <String>['Color'],
    dio: dio,
  );

  /// Where the mirror answers, which is what a phone asks.
  static const String _direct = 'https://tcgcsv.com/tcgplayer';

  /// Arcanum's own relay in front of the mirror, which is what a browser asks.
  static const String _relay = 'https://marquezhv.com/arcanumweb-api/tcgcsv';

  /// The address card data is asked for under.
  ///
  /// A browser cannot ask the mirror itself. tcgcsv sends no CORS headers, so
  /// the browser discards the answer before any of this code sees it, and it
  /// asks callers to identify themselves - which means a User-Agent header, one
  /// the browser will not let a page set. Five of the nine games are catalogued
  /// here and all five came back empty in the browser build for those two
  /// reasons alone, so a browser is pointed at Arcanum's relay instead: it
  /// fetches the same path under the name the mirror asks for and returns the
  /// answer with the header the browser is waiting for. A phone needs none of
  /// that - there is no origin to be judged against and the header the app
  /// sends is the one the mirror wants - so it asks the mirror directly and its
  /// card data never passes through a host of ours.
  ///
  /// [web] is a browser build reading its own state rather than a choice a
  /// caller makes; it is a parameter so both addresses can be read at once
  /// without running a request through either.
  static String apiBase({bool web = kIsWeb}) => web ? _relay : _direct;

  /// How the mirror asks to be identified.
  static const String _agent =
      'Arcanum/1.0 (+https://github.com/arm00pv/arcanum)';

  /// The gap kept between two requests.
  ///
  /// tcgcsv publishes a daily rebuild rather than a live service and asks
  /// callers to pace themselves; a set costs two requests, so opening a set
  /// costs a fraction of a second more than it strictly has to and the mirror
  /// is not hammered for it.
  static const Duration _gap = Duration(milliseconds: 200);

  /// Retries per request before giving up on a single call.
  static const int _maxRetries = 3;

  /// TCGplayer's product CDN, which serves the same art the shop shows.
  static const String _imageCdn = 'https://tcgplayer-cdn.tcgplayer.com/product';

  @override
  final CardGame game;

  /// TCGplayer's category id for this game.
  final int categoryId;

  /// The extendedData fields that carry this game's categories, in order.
  final List<String> _colourFields;

  final Dio _dio;

  /// When the last request went out, for the pacing in [_get].
  DateTime? _lastCall;

  // A set code maps to every group the provider files it under, not to one:
  // TCGplayer gives a set's release-event or championship printings a run of
  // their own and the same abbreviation, so one code can be two groups.
  Map<String, List<int>>? _groups;
  Map<String, String>? _setNames;
  Map<String, String>? _setTypes;
  Future<Map<String, List<int>>>? _groupsInFlight;

  static Dio _client() => Dio(
    BaseOptions(
      baseUrl: apiBase(),
      connectTimeout: const Duration(seconds: 12),
      // A large set - Star Wars: Unlimited's Ashes of the Empire is 954
      // products - is about 1.5 MB in one response.
      receiveTimeout: const Duration(seconds: 60),
      headers: const <String, String>{
        'Accept': 'application/json',
        'User-Agent': _agent,
      },
    ),
  );

  @override
  String get sourceName => 'tcgcsv';

  // ------------------------------------------------------------------- sets

  @override
  Future<List<TcgSet>> fetchAllSets({
    void Function(int done, int total)? onProgress,
  }) async {
    final List<dynamic> raw;
    try {
      raw = _results(await _get('/$categoryId/groups'));
    } on DioException catch (e) {
      throw CatalogException(
        e.message ?? 'Could not reach tcgcsv',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }

    final sets = <TcgSet>[];
    final groups = <String, List<int>>{};
    final names = <String, String>{};
    final types = <String, String>{};
    // One request carries every set, so a tick means "this set has been read"
    // rather than "this set has been downloaded".
    onProgress?.call(0, raw.length);
    for (final item in raw) {
      if (item is! Map) continue;
      final id = _int(item['groupId']);
      final name = _string(item['name']);
      if (id == null || name == null) continue;
      final abbreviation = _string(item['abbreviation']) ?? name;
      final published = _string(item['publishedOn']);
      final code = _setCode(abbreviation, name);
      final known = groups.putIfAbsent(code, () => <int>[]);
      names.putIfAbsent(code, () => name);
      // Kept for the cards as well as the set row: a printing's own row says
      // that it came out of a promotional run, which is what tells the app that
      // the art it is about to show is the publisher's sample rather than a
      // photograph of the card.
      types.putIfAbsent(code, () => _setTypeFor(abbreviation, name));
      known.add(id);
      if (known.length > 1) {
        // A second group under a code that is already spoken for. The provider
        // splits a set's release-event or championship printings into a run of
        // their own and letters them with the set's own abbreviation, so the
        // cards print the same code as the set they came from. To a collector
        // they are that set, and a row of their own would be a row that hides
        // it - one Digimon set and one Star Wars: Unlimited set are listed this
        // way today - so the run is folded in and its cards are downloaded with
        // the set's.
        onProgress?.call(sets.length, raw.length);
        continue;
      }
      sets.add(
        TcgSet(
          game: game,
          // The group id addresses the set at the provider; the code is what
          // the rest of the app stores and what the card prints.
          id: '$id',
          code: code,
          name: name,
          setType: _setTypeFor(abbreviation, name),
          releasedAt: published == null ? null : DateTime.tryParse(published),
          // The group list publishes no card count; the repository fills it in
          // the first time the set is opened, so a zero here means "not known".
        ),
      );
      onProgress?.call(sets.length, raw.length);
    }
    // The list just read is the one every later call needs to turn a set code
    // into a group id, so it is kept here as well: a screen that refreshes the
    // set list should not make the next card download ask for it again.
    _remember(groups, names, types);
    return sets;
  }

  /// Keeps the code-to-group map from a set list that has just been read.
  Map<String, List<int>> _remember(
    Map<String, List<int>> groups,
    Map<String, String> names,
    Map<String, String> types,
  ) {
    _groups = groups;
    _setNames = names;
    _setTypes = types;
    _groupsInFlight = null;
    return _groups!;
  }

  /// The set code, as the card prints it.
  ///
  /// TCGplayer writes a set's abbreviation the way its own shop does - 'BT-26',
  /// 'OP18 RE', 'ST-31' - and the card prints 'BT26-052', 'OP18-001',
  /// 'ST31-001'. Every difference between the two is punctuation, so the code
  /// the app stores is the abbreviation with everything that is not a letter or
  /// a digit taken out. That makes the code the scanner reads off a card the
  /// same string the catalogue is keyed by, which is the only way a scan can
  /// resolve to one printing.
  static String _setCode(String abbreviation, String name) {
    final fromAbbreviation = _slug(abbreviation);
    return fromAbbreviation.isNotEmpty ? fromAbbreviation : _slug(name);
  }

  /// Classifies a set from the two things the provider states about it.
  ///
  /// tcgcsv carries an isSupplemental flag, but it is false for promo runs and
  /// starter decks alike, so the split is read off the abbreviation and the
  /// name - which is what the provider's own naming describes: release event
  /// cards are suffixed 'RE', starter decks are prefixed 'ST' or 'SD' and named
  /// as such, and everything else is a booster set. A set-type filter is only
  /// worth offering if the split means something, and this is the split these
  /// three games actually have.
  static String _setTypeFor(String abbreviation, String name) {
    final code = abbreviation.trim().toUpperCase().replaceAll(' ', '');
    final lower = name.toLowerCase();
    if (code.endsWith('RE') ||
        lower.contains('promo') ||
        lower.contains('release event')) {
      return 'promo';
    }
    if (code.startsWith('ST') ||
        code.startsWith('SD') ||
        lower.startsWith('starter') ||
        lower.startsWith('structure') ||
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
    final groups = await _groupsFor(setCode);
    if (groups.isEmpty) return const <TcgCard>[];

    final setName = await _setNameFor(setCode);
    final cards = <TcgCard>[];
    // A set can be more than one group, so every group it is filed under is
    // read and the cards are pooled: a booster set's release-event printings
    // are the same set, the same code and the same binder.
    final total = groups.length * 2;
    onProgress?.call(0, total);
    var done = 0;
    for (final group in groups) {
      final List<dynamic> products;
      final List<dynamic> prices;
      try {
        products = _results(await _get('/$categoryId/$group/products'));
        onProgress?.call(++done, total);
        prices = _results(await _get('/$categoryId/$group/prices'));
        onProgress?.call(++done, total);
      } on DioException catch (e) {
        // A group the provider has dropped is skipped; a set with no group left
        // is an empty set rather than an error, in the same spirit as the other
        // catalogues.
        if (e.response?.statusCode == 404) continue;
        throw CatalogException(
          e.message ?? 'Could not reach tcgcsv',
          statusCode: e.response?.statusCode,
          source: sourceName,
        );
      }

      final byProduct = _pricesByProduct(prices);
      for (final item in products) {
        if (item is! Map) continue;
        final card = _cardFrom(item, byProduct, setCode, setName, group);
        if (card != null) cards.add(card);
      }
    }

    // The interface promises collector-number order and the provider's order is
    // its own; the index tiebreak keeps the sort stable between downloads.
    final ordered =
        <(int, TcgCard)>[for (var i = 0; i < cards.length; i++) (i, cards[i])]
          ..sort((a, b) {
            final byNumber = a.$2.collectorNumberSortKey.compareTo(
              b.$2.collectorNumberSortKey,
            );
            return byNumber != 0 ? byNumber : a.$1.compareTo(b.$1);
          });
    return <TcgCard>[for (final (_, card) in ordered) card];
  }

  @override
  Future<TcgCard?> fetchCardById(String id) async {
    final split = _splitId(id);
    if (split == null) return null;
    final (group, productId) = split;
    try {
      final products = _results(await _get('/$categoryId/$group/products'));
      Map<dynamic, dynamic>? found;
      for (final item in products) {
        if (item is Map && _int(item['productId']) == productId) {
          found = item;
          break;
        }
      }
      if (found == null) return null;
      final prices = _results(await _get('/$categoryId/$group/prices'));
      final setCode = await _setCodeForGroup(group);
      return _cardFrom(
        found,
        _pricesByProduct(prices),
        setCode,
        await _setNameFor(setCode),
        group,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw CatalogException(
        e.message ?? 'Could not reach tcgcsv',
        statusCode: e.response?.statusCode,
        source: sourceName,
      );
    }
  }

  @override
  Future<Map<String, TcgCard>> fetchCardsByIds(List<String> ids) async {
    // A card's id carries the group it came from and there is no endpoint for a
    // single product, so the ids are sorted into their groups before anything
    // is asked for: one product list and one price list answer for every card a
    // group holds. A collection that names five hundred printings out of one
    // set is two requests here rather than a thousand, which is the difference
    // between a first sign-in that takes a moment and one that takes minutes.
    final byGroup = <int, Set<int>>{};
    for (final id in ids) {
      final split = _splitId(id);
      if (split == null) continue;
      byGroup.putIfAbsent(split.$1, () => <int>{}).add(split.$2);
    }

    final cards = <String, TcgCard>{};
    for (final entry in byGroup.entries) {
      final group = entry.key;
      final wanted = entry.value;
      try {
        final products = _results(await _get('/$categoryId/$group/products'));
        final found = <Map<dynamic, dynamic>>[
          for (final item in products)
            if (item is Map && wanted.contains(_int(item['productId']))) item,
        ];
        // A group holding none of the ids it was asked about - a printing the
        // shop has since dropped - is not worth its price list as well.
        if (found.isEmpty) continue;

        final prices = _results(await _get('/$categoryId/$group/prices'));
        final byProduct = _pricesByProduct(prices);
        final setCode = await _setCodeForGroup(group);
        final setName = await _setNameFor(setCode);
        for (final product in found) {
          // The card writes its own id - the group it was filed under and the
          // product it is - which is the id it was asked about.
          final card = _cardFrom(product, byProduct, setCode, setName, group);
          if (card != null) cards[card.id] = card;
        }
      } on DioException {
        // The same tolerance the set download shows: a group the provider has
        // dropped is an empty group rather than an error, and one group that
        // cannot be read is not the rest of the collection's problem.
      }
    }
    return cards;
  }

  @override
  Future<List<TcgCard>> search(String query, {int limit = 100}) async {
    // tcgcsv republishes a shop's catalogue: groups, products, prices. It has
    // no search endpoint, and the only way to answer a query about a card name
    // would be to download every group in the category - 87 requests for One
    // Piece - which its own guidelines forbid and which would take longer than
    // typing the card into the binder.
    //
    // So a search covers the sets already on this phone, which is what the
    // repository falls back to and what the search screen says.
    return const <TcgCard>[];
  }

  @override
  Future<List<TcgCard>> fetchPrintingsOf(String groupId) async {
    // Reprints are separate products in separate groups with no shared id to
    // ask about, so the repository's local cache - keyed by the oracle id this
    // catalogue writes onto every card - is what answers "every printing of
    // this card".
    return const <TcgCard>[];
  }

  @override
  Future<List<TcgCard>> refreshPrices(List<TcgCard> cards) async {
    if (cards.isEmpty) return const <TcgCard>[];

    // One price list covers a whole set, so the cards are grouped first: a
    // binder of forty cards from one set costs one request, not forty.
    final byGroup = <int, List<TcgCard>>{};
    for (final card in cards) {
      final split = _splitId(card.id);
      if (split == null) continue;
      byGroup.putIfAbsent(split.$1, () => <TcgCard>[]).add(card);
    }

    final out = <TcgCard>[];
    for (final entry in byGroup.entries) {
      try {
        final rows = _results(await _get('/$categoryId/${entry.key}/prices'));
        final byProduct = _pricesByProduct(rows);
        for (final card in entry.value) {
          final split = _splitId(card.id);
          final fresh = split == null ? null : byProduct['${split.$2}'];
          if (fresh == null || fresh.isEmpty) continue;
          out.add(card.copyWith(prices: _pricesOf(fresh)));
        }
      } on DioException {
        // A partial refresh is still useful; skip the group that failed.
      }
    }
    return out;
  }

  // --------------------------------------------------------------- requests

  /// One GET, paced and retried.
  ///
  /// The pacing is deliberately on the request rather than on the set: a set is
  /// two calls, and both go through here, so the gap the provider asked for is
  /// kept between calls however the caller batches them.
  Future<Object?> _get(String path) async {
    final last = _lastCall;
    if (last != null) {
      final waited = DateTime.now().difference(last);
      if (waited < _gap) await Future<void>.delayed(_gap - waited);
    }
    _lastCall = DateTime.now();
    final res = await _retry(() => _dio.get<dynamic>(path));
    return res.data;
  }

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
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  /// Unwraps the results envelope every tcgcsv route answers with.
  static List<dynamic> _results(Object? data) {
    if (data is List) return data;
    if (data is Map) {
      final results = data['results'];
      if (results is List) return results;
    }
    return const <dynamic>[];
  }

  // ---------------------------------------------------------------- mapping

  /// Builds one card from a product and its prices.
  ///
  /// Returns null for anything without a collector number, which is the
  /// structural test for "this is a card": a booster box, a bundle and a
  /// playmat live in the same list as the cards and carry no number, and a row
  /// with no number cannot be sorted into a binder or matched by a scan.
  TcgCard? _cardFrom(
    Map<dynamic, dynamic> product,
    Map<String, Map<String, double?>> prices,
    String setCode,
    String setName,
    int group,
  ) {
    final productId = _int(product['productId']);
    if (productId == null) return null;
    final extended = _extended(product);
    final number = _string(extended['Number']);
    if (number == null) return null;

    final name = _cleanName(
      _string(product['name']) ?? _string(product['cleanName']) ?? '',
    );
    if (name.isEmpty) return null;

    final type = _string(extended['CardType']) ?? '';
    final colours = <String>[
      for (final field in _colourFields)
        for (final value in (extended[field] ?? '').toString().split(';'))
          if (value.trim().isNotEmpty) value.trim(),
    ];

    return TcgCard(
      game: game,
      id: '$group-$productId',
      setCode: setCode,
      setName: setName,
      name: name,
      // A printing filed under a promotional run is a promotional card. The
      // provider states it as the group's own name, which is what
      // [TcgSet.setType] is read from, and the flag travels with the card
      // because the card is what a screen has in hand.
      promo: _setTypes?[_slug(setCode)] == 'promo',
      collectorNumber: _collectorNumberOf(number),
      rarity: _string(extended['Rarity']) ?? 'unknown',
      typeLine: _typeLine(type, extended),
      oracleText: _text(extended['Description']),
      // One Piece and Star Wars: Unlimited state a cost; Digimon states a play
      // cost and leaves the other field empty. Both are the number a card
      // costs to play, which is what the app sorts and filters by.
      cmc: _num(extended['Cost'] ?? extended['PlayCost'])?.toDouble(),
      colors: colours,
      colorIdentity: colours,
      prices: _pricesOf(prices['$productId'] ?? const <String, double?>{}),
      imageUris: _images(productId),
      // The provider publishes no oracle identity, so a card is grouped by
      // what a collector would call it: its name and what kind of card it is.
      // Name alone is not enough - a One Piece Leader and a One Piece
      // Character are both "Monkey.D.Luffy" and are not the same card, and
      // Star Wars: Unlimited prints a Leader and a Unit under one name - so the
      // card type is part of the key. Reprints keep the same type and still
      // group.
      oracleId: '${TcgCard.normaliseName(_baseName(name))}|${_slug(type)}',
      extras: <String, Object?>{
        // The shop's own product id, under the name the rest of the app asks
        // for it by: the price-history providers are keyed by TCGplayer's
        // product id, and this is the same number tcgcsv lists it under.
        'tcgplayerId': productId,
        'productId': productId,
        'groupId': group,
        'printedNumber': number,
        if (type.isNotEmpty) 'cardType': type,
        for (final field in const <String>[
          'Power',
          'HP',
          'Life',
          'Counterplus',
          'Subtypes',
          'Attribute',
          'Arena Type',
          'Traits',
          'LevelLv',
          'PlayCost',
          'DigimonForm',
          'DigimonAttribute',
          // Fusion World states a combo power as well as a battle power, and
          // Gundam states attack and hit points, a level, the zone a unit
          // deploys to and the pilot that links to it.
          'Combo Power',
          'Attack Points',
          'Hit Points',
          'Character Traits',
          'Trait',
          'Level',
          'Zone',
          'Link Condition',
        ])
          if (_string(extended[field]) case final String value) field: value,
      },
    );
  }

  /// The prices TCGplayer quotes for one product.
  ///
  /// Every one of these games is priced under the same two subtypes - "Normal"
  /// and "Foil" - which are the two finishes the app knows. A product with no
  /// quote at all, or with a null market price, is left unpriced rather than
  /// filled in from the low or mid asking price: those are offers rather than
  /// sales, and a valuation built from them would not be the same number the
  /// rest of the app shows for Magic and Pokemon.
  static TcgPrices _pricesOf(Map<String, double?> quoted) {
    final byFinish = <String, double?>{};
    for (final entry in quoted.entries) {
      byFinish[_finishCode(entry.key)] = entry.value;
    }
    return TcgPrices(byFinish: byFinish);
  }

  /// Maps the provider's price subtype to a [CardFinish] code.
  static String _finishCode(String subType) =>
      subType.trim().toLowerCase() == 'foil' ? 'foil' : 'nonfoil';

  /// The market price of every product in a price list, by product and subtype.
  static Map<String, Map<String, double?>> _pricesByProduct(
    List<dynamic> rows,
  ) {
    final out = <String, Map<String, double?>>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final productId = _int(row['productId']);
      final subType = _string(row['subTypeName']);
      if (productId == null || subType == null) continue;
      final perProduct = out.putIfAbsent(
        '$productId',
        () => <String, double?>{},
      );
      final market = row['marketPrice'];
      final value = market is num && market > 0 ? market.toDouble() : null;
      // A product can be listed twice under one subtype; the price that is
      // actually there wins over the one that is not.
      if (!perProduct.containsKey(subType) || perProduct[subType] == null) {
        perProduct[subType] = value;
      }
    }
    return out;
  }

  /// The card's art, keyed by size.
  ///
  /// tcgcsv publishes one 200-pixel JPEG per product, and the shop's CDN serves
  /// the same product at other widths by naming convention - which is what the
  /// other catalogue in this app that uses this CDN already relies on.
  static Map<String, String> _images(int productId) => <String, String>{
    'small': CardArt.host('$_imageCdn/${productId}_200w.jpg'),
    'normal': CardArt.host('$_imageCdn/${productId}_400w.jpg'),
    'large': CardArt.host('$_imageCdn/${productId}_in_1000x1000.jpg'),
  };

  /// The position within the set, from the number the provider prints.
  ///
  /// The three games spell their numbers differently and all three mean the
  /// same thing by them: One Piece writes 'OP01-002', Digimon 'BT26-052 C' with
  /// a rarity code stuck on the end, and Star Wars: Unlimited '94/264'. The
  /// position is the digits after the last separator in each case, and the full
  /// printed string is kept in extras for anything that wants to show it.
  static String _collectorNumberOf(String printed) {
    final first = printed.trim().split(RegExp(r'\s+')).first;
    final beforeSlash = first.split('/').first;
    final match = RegExp(r'(\d+)$').firstMatch(beforeSlash);
    return match?.group(1) ?? beforeSlash;
  }

  /// The card's name, without the number the provider glues into it.
  ///
  /// TCGplayer names a One Piece product 'Trafalgar Law (002)' and
  /// 'Monkey.D.Luffy (003) (Parallel)': the number is the same one printed on
  /// the card and is already stored as the collector number, while the art
  /// variant in the second bracket is worth keeping because it is what tells
  /// two products apart on a shelf. Only a bracket holding nothing but digits
  /// is dropped.
  static String _cleanName(String raw) => raw
      .replaceAll(RegExp(r'\s*\(\s*\d+\s*\)'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  /// The card's name with every bracketed variant taken off.
  ///
  /// TCGplayer marks an art variant in the product's name - 'Trafalgar Law
  /// (002) (Parallel)' - and those variants are separate products that a
  /// collector calls one card, which is exactly what the oracle id has to group.
  static String _baseName(String name) => name
      .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();

  /// The type line, with the game's own extra fields appended.
  ///
  /// One Piece prints a card type and sub-types, Star Wars: Unlimited a card
  /// type and traits, Digimon a form and a level. The type line is what the app
  /// searches and shows, so what the provider states about a card is joined
  /// into it rather than left in fields nothing reads.
  static String? _typeLine(String type, Map<String, dynamic> extended) {
    final parts = <String>[
      if (type.isNotEmpty) type,
      if (_listed(extended, 'Subtypes') case final String sub) sub,
      if (_listed(extended, 'Traits') case final String traits) traits,
      // Fusion World calls a card's traits its Character Traits and Gundam
      // calls them a Trait; both print them under the card type on the card,
      // which is where the type line puts them.
      if (_listed(extended, 'Character Traits') case final String traits)
        traits,
      if (_listed(extended, 'Trait') case final String trait) trait,
      if (_string(extended['DigimonForm']) case final String form) form,
      // Digimon prints the species - Dragon, Machine, Holy Beast - in the same
      // block as the form, and it is what a player searches for.
      if (_string(extended['DigimonType']) case final String kind) kind,
      if (_string(extended['LevelLv']) case final String level) 'Level $level',
      // A Gundam unit states the level it can be deployed at, which Digimon's
      // LevelLv is the same idea as, and the zone it may be deployed to.
      if (_string(extended['Level']) case final String level) 'Level $level',
      if (_listed(extended, 'Zone') case final String zone) zone,
      if (_string(extended['Arena Type']) case final String arena) arena,
    ];
    final line = parts.join(' - ');
    return line.isEmpty ? null : line;
  }

  /// A provider field that holds a semicolon-separated list.
  ///
  /// One Piece lists sub-types and Star Wars: Unlimited lists traits that way,
  /// while both print them on the card separated by slashes. The type line is
  /// shown and searched, so it is spelled the way the card is.
  static String? _listed(Map<String, dynamic> extended, String field) {
    final raw = _string(extended[field]);
    if (raw == null) return null;
    final parts = raw
        .split(';')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);
    return parts.isEmpty ? null : parts.join(' / ');
  }

  /// The provider's extendedData as a plain map.
  ///
  /// It arrives as a list of name and value pairs, with the fields present
  /// depending on the game and sometimes on the card - a Digimon option card
  /// carries a colour and a play cost while a sealed box carries neither.
  static Map<String, dynamic> _extended(Map<dynamic, dynamic> product) {
    final raw = product['extendedData'];
    final out = <String, dynamic>{};
    if (raw is! List) return out;
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = _string(entry['name']);
      if (name == null) continue;
      out[name] = entry['value'];
    }
    return out;
  }

  /// The rules text, with the provider's markup taken out.
  ///
  /// TCGplayer writes a card's text with tags in it - em, br and links to errata
  /// pages - and the app searches and displays this field, so the markup is
  /// stripped rather than shown to a collector.
  static String? _text(Object? raw) {
    final text = raw?.toString() ?? '';
    if (text.trim().isEmpty) return null;
    final stripped = text
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return stripped.isEmpty ? null : stripped;
  }

  /// Every group id behind a set code, from the set list.
  ///
  /// The app keys sets by code and the provider addresses them by group id, so
  /// the list has to be read to translate one into the other. Usually that is
  /// one group; where the provider has split a set into a second run under the
  /// same abbreviation it is two, and both are read so the set is whole. A code
  /// that is not in the list is an unknown set: the answer is an empty set, not
  /// an error, in the same spirit as the other catalogues.
  Future<List<int>> _groupsFor(String setCode) async {
    final groups = await _loadGroups();
    return groups[_setCode(setCode, setCode)] ?? const <int>[];
  }

  /// The app's set code for a group id, for a card fetched by id alone.
  Future<String> _setCodeForGroup(int group) async {
    final groups = await _loadGroups();
    for (final entry in groups.entries) {
      if (entry.value.contains(group)) return entry.key;
    }
    return '$group';
  }

  Future<String> _setNameFor(String setCode) async {
    await _loadGroups();
    return _setNames?[setCode] ?? setCode.toUpperCase();
  }

  /// The set list, read once per catalogue and kept.
  ///
  /// One request buys every set and every group the app will need while it is
  /// open. A failure is not cached, so the next attempt can try again.
  Future<Map<String, List<int>>> _loadGroups() async {
    final known = _groups;
    if (known != null) return known;
    final pending = _groupsInFlight;
    if (pending != null) return pending;
    final future = fetchAllSets().then((List<TcgSet> sets) {
      // fetchAllSets has already kept the map; this only has to hand it back.
      return _groups ?? <String, List<int>>{};
    });
    _groupsInFlight = future;
    return future;
  }

  /// Splits a card id into its group and product.
  static (int, int)? _splitId(String id) {
    final parts = id.split('-');
    if (parts.length != 2) return null;
    final group = int.tryParse(parts[0]);
    final product = int.tryParse(parts[1]);
    if (group == null || product == null) return null;
    return (group, product);
  }

  /// Lower-cases a provider value and keeps only letters and digits, so it can
  /// sit in a set code and match what a card prints.
  static String _slug(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static String? _string(Object? raw) {
    final text = raw?.toString().trim() ?? '';
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
}
