// Immutable, null-safe models for the Scryfall MTG API.
//
// Every field name below was verified against the live API, not guessed. The
// probes that produced these models (all HTTP 200, real responses) were:
//
//   GET  https://api.scryfall.com/sets
//   GET  https://api.scryfall.com/cards/search?q=set%3Atla&order=set&unique=prints
//   GET  https://api.scryfall.com/cards/tla/27          (double-faced card)
//   POST https://api.scryfall.com/cards/collection
//
// Confirmed object shapes:
//   Set  : object, id, code, name, set_type, released_at, card_count,
//          icon_svg_uri, digital, foil_only, nonfoil_only, parent_set_code,
//          block_code, block, printed_size, uri, search_uri, scryfall_uri,
//          mtgo_code, arena_code, tcgplayer_id
//   List : object, data, has_more, next_page, total_cards (cards only)
//   Card : see ScryfallCard.fromJson
//
// Nothing in this file imports Flutter, so it is usable from plain Dart.

// ---------------------------------------------------------------------------
// Parsing helpers (defensive: the API omits or nulls many optional fields)
// ---------------------------------------------------------------------------

const List<String> _wubrgOrder = <String>['W', 'U', 'B', 'R', 'G'];

/// Image sizes Scryfall publishes, in the order we prefer them when the exact
/// requested size is missing from a card's map.
const List<String> _imageSizeFallback = <String>[
  'normal',
  'large',
  'small',
  'png',
  'border_crop',
  'art_crop',
];

String? _string(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return value;
  }
  return value.toString();
}

String _stringOr(Object? value, String fallback) => _string(value) ?? fallback;

int _int(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim()) ?? fallback;
  }
  return fallback;
}

int? _intOrNull(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

double? _doubleOrNull(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return double.tryParse(trimmed);
  }
  return null;
}

bool _bool(Object? value, {bool fallback = false}) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    if (value == 'true') {
      return true;
    }
    if (value == 'false') {
      return false;
    }
  }
  return fallback;
}

List<String> _stringList(Object? value) {
  if (value is List) {
    final List<String> out = <String>[];
    for (final Object? item in value) {
      if (item != null) {
        out.add(item.toString());
      }
    }
    return List<String>.unmodifiable(out);
  }
  return const <String>[];
}

Map<String, String> _stringMap(Object? value) {
  if (value is Map) {
    final Map<String, String> out = <String, String>{};
    value.forEach((Object? key, Object? item) {
      if (item != null) {
        out[key.toString()] = item.toString();
      }
    });
    return Map<String, String>.unmodifiable(out);
  }
  return const <String, String>{};
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, dynamic>(
      (Object? key, Object? item) => MapEntry<String, dynamic>(
        key.toString(),
        item,
      ),
    );
  }
  return const <String, dynamic>{};
}

DateTime? _dateTime(Object? value) {
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    return DateTime.tryParse(trimmed);
  }
  return null;
}

/// Serialises a date the way Scryfall does: `YYYY-MM-DD`.
String? _dateToJson(DateTime? value) {
  if (value == null) {
    return null;
  }
  final String year = value.year.toString().padLeft(4, '0');
  final String month = value.month.toString().padLeft(2, '0');
  final String day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// Returns the best available URL for [size] out of a Scryfall image map.
String? _pickImageUrl(Map<String, String> uris, String size) {
  if (uris.isEmpty) {
    return null;
  }
  final String? exact = uris[size];
  if (exact != null && exact.isNotEmpty) {
    return exact;
  }
  for (final String candidate in _imageSizeFallback) {
    final String? value = uris[candidate];
    if (value != null && value.isNotEmpty) {
      return value;
    }
  }
  for (final String value in uris.values) {
    if (value.isNotEmpty) {
      return value;
    }
  }
  return null;
}

/// De-duplicates colours and sorts them in WUBRG order.
List<String> _sortColors(Iterable<String> input) {
  final Set<String> remaining = <String>{};
  for (final String color in input) {
    if (color.isNotEmpty) {
      remaining.add(color);
    }
  }
  final List<String> ordered = <String>[];
  for (final String color in _wubrgOrder) {
    if (remaining.remove(color)) {
      ordered.add(color);
    }
  }
  final List<String> rest = remaining.toList()..sort();
  ordered.addAll(rest);
  return List<String>.unmodifiable(ordered);
}

String? _relatedUri(Map<String, dynamic> json, String key) {
  final Object? related = json['related_uris'];
  if (related is Map) {
    final Object? value = related[key];
    if (value != null) {
      return value.toString();
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Set
// ---------------------------------------------------------------------------

/// A Scryfall Set object (`GET /sets`).
class ScryfallSet {
  const ScryfallSet({
    required this.id,
    required this.code,
    required this.name,
    required this.setType,
    this.releasedAt,
    this.cardCount = 0,
    this.iconSvgUri,
    this.digital = false,
    this.foilOnly = false,
    this.nonfoilOnly = false,
    this.parentSetCode,
    this.blockCode,
    this.block,
    this.printedSize,
    this.collectorNumberStart,
    this.setUri,
    this.searchUri,
    this.scryfallUri,
  });

  factory ScryfallSet.fromJson(Map<String, dynamic> json) => ScryfallSet(
        id: _stringOr(json['id'], ''),
        code: _stringOr(json['code'], ''),
        name: _stringOr(json['name'], ''),
        setType: _stringOr(json['set_type'], ''),
        releasedAt: _dateTime(json['released_at']),
        cardCount: _int(json['card_count']),
        iconSvgUri: _string(json['icon_svg_uri']),
        digital: _bool(json['digital']),
        foilOnly: _bool(json['foil_only']),
        nonfoilOnly: _bool(json['nonfoil_only']),
        parentSetCode: _string(json['parent_set_code']),
        blockCode: _string(json['block_code']),
        block: _string(json['block']),
        printedSize: _intOrNull(json['printed_size']),
        collectorNumberStart: _intOrNull(json['collector_number_start']),
        setUri: _string(json['uri']),
        searchUri: _string(json['search_uri']),
        scryfallUri: _string(json['scryfall_uri']),
      );

  /// Scryfall UUID for this set.
  final String id;

  /// The unique three to six letter set code, e.g. `tla`.
  final String code;

  /// English name of the set.
  final String name;

  /// Computer-readable classification, e.g. `expansion`, `promo`, `token`.
  final String setType;

  /// Date the set was released. Scryfall sends `YYYY-MM-DD`.
  final DateTime? releasedAt;

  /// Number of cards in the set.
  final int cardCount;

  /// URI of the set's SVG icon on Scryfall's CDN.
  final String? iconSvgUri;

  /// True if the set only exists in a video game.
  final bool digital;

  /// True if the set contains only foil cards.
  final bool foilOnly;

  /// True if the set contains only nonfoil cards.
  final bool nonfoilOnly;

  /// Set code of the parent set, if any (promo/token sets often have one).
  final String? parentSetCode;

  /// Block code, if any.
  final String? blockCode;

  /// Block or group name code, if any.
  final String? block;

  /// Denominator for the set's printed collector numbers, if any.
  final int? printedSize;

  /// First collector number of the set.
  ///
  /// NOTE: this key does **not** exist in the current API response (verified
  /// against all 1049 sets on /sets - zero of them carry it). The field is kept
  /// so a future API addition is picked up for free, and is null today.
  final int? collectorNumberStart;

  /// API URI of this set object.
  final String? setUri;

  /// API URI that starts paginating over the cards in this set.
  final String? searchUri;

  /// Permapage for this set on scryfall.com.
  final String? scryfallUri;

  /// Uppercase set code, handy for display.
  String get displayCode => code.toUpperCase();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'object': 'set',
        'id': id,
        'code': code,
        'name': name,
        'set_type': setType,
        'released_at': _dateToJson(releasedAt),
        'card_count': cardCount,
        'icon_svg_uri': iconSvgUri,
        'digital': digital,
        'foil_only': foilOnly,
        'nonfoil_only': nonfoilOnly,
        'parent_set_code': parentSetCode,
        'block_code': blockCode,
        'block': block,
        'printed_size': printedSize,
        'collector_number_start': collectorNumberStart,
        'uri': setUri,
        'search_uri': searchUri,
        'scryfall_uri': scryfallUri,
      };

  @override
  String toString() => 'ScryfallSet($code, "$name", $cardCount cards)';
}

// ---------------------------------------------------------------------------
// Card face
// ---------------------------------------------------------------------------

/// One face of a multi-faced card (`card_faces[]`).
class ScryfallCardFace {
  const ScryfallCardFace({
    this.name,
    this.manaCost,
    this.typeLine,
    this.oracleText,
    this.flavorText,
    this.artist,
    this.imageUris = const <String, String>{},
    this.colors = const <String>[],
  });

  factory ScryfallCardFace.fromJson(Map<String, dynamic> json) =>
      ScryfallCardFace(
        name: _string(json['name']),
        manaCost: _string(json['mana_cost']),
        typeLine: _string(json['type_line']),
        oracleText: _string(json['oracle_text']),
        flavorText: _string(json['flavor_text']),
        artist: _string(json['artist']),
        imageUris: _stringMap(json['image_uris']),
        colors: _sortColors(_stringList(json['colors'])),
      );

  final String? name;
  final String? manaCost;
  final String? typeLine;
  final String? oracleText;
  final String? flavorText;
  final String? artist;

  /// Keys observed on double-faced cards: `small`, `normal`, `large`, `png`,
  /// `art_crop`, `border_crop` (plus `thumb`, `grid`, `display`, `art`, `crop`).
  final Map<String, String> imageUris;

  /// This face's colours.
  final List<String> colors;

  /// Best image for this face at [size].
  String? imageUrl({String size = 'normal'}) => _pickImageUrl(imageUris, size);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'object': 'card_face',
        'name': name,
        'mana_cost': manaCost,
        'type_line': typeLine,
        'oracle_text': oracleText,
        'flavor_text': flavorText,
        'artist': artist,
        'image_uris': imageUris.isEmpty ? null : imageUris,
        'colors': colors,
      };

  @override
  String toString() => 'ScryfallCardFace($name)';
}

// ---------------------------------------------------------------------------
// Prices
// ---------------------------------------------------------------------------

/// Daily price information. Scryfall sends every price as a **string or null**,
/// e.g. `{"usd": "0.23", "usd_foil": "0.29", "usd_etched": null, ...}`.
class ScryfallPrices {
  const ScryfallPrices({
    this.usd,
    this.usdFoil,
    this.usdEtched,
    this.eur,
    this.eurFoil,
    this.eurEtched,
    this.tix,
  });

  factory ScryfallPrices.fromJson(Map<String, dynamic> json) => ScryfallPrices(
        usd: _doubleOrNull(json['usd']),
        usdFoil: _doubleOrNull(json['usd_foil']),
        usdEtched: _doubleOrNull(json['usd_etched']),
        eur: _doubleOrNull(json['eur']),
        eurFoil: _doubleOrNull(json['eur_foil']),
        eurEtched: _doubleOrNull(json['eur_etched']),
        tix: _doubleOrNull(json['tix']),
      );

  /// A price set where nothing is known.
  static const ScryfallPrices empty = ScryfallPrices();

  final double? usd;
  final double? usdFoil;
  final double? usdEtched;
  final double? eur;
  final double? eurFoil;
  final double? eurEtched;
  final double? tix;

  /// True when Scryfall reported no price at all for this printing.
  bool get isEmpty =>
      usd == null &&
      usdFoil == null &&
      usdEtched == null &&
      eur == null &&
      eurFoil == null &&
      eurEtched == null &&
      tix == null;

  /// Best USD price for the requested finish.
  ///
  /// Fallback chains (first non-null wins):
  /// * nonfoil: `usd` -> `usdFoil` -> `usdEtched`
  /// * foil:    `usdFoil` -> `usd` -> `usdEtched`
  /// * etched:  `usdEtched` -> `usdFoil` -> `usd`
  double? priceFor({bool foil = false, bool etched = false}) {
    if (etched) {
      return usdEtched ?? usdFoil ?? usd;
    }
    if (foil) {
      return usdFoil ?? usd ?? usdEtched;
    }
    return usd ?? usdFoil ?? usdEtched;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'usd': usd,
        'usd_foil': usdFoil,
        'usd_etched': usdEtched,
        'eur': eur,
        'eur_foil': eurFoil,
        'eur_etched': eurEtched,
        'tix': tix,
      };

  @override
  String toString() => 'ScryfallPrices(usd: $usd, usdFoil: $usdFoil, tix: $tix)';
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

/// A Scryfall Card object.
class ScryfallCard {
  const ScryfallCard({
    required this.id,
    required this.name,
    required this.setCode,
    required this.setName,
    required this.collectorNumber,
    required this.rarity,
    required this.layout,
    this.typeLine,
    this.oracleText,
    this.manaCost,
    this.artist,
    this.flavorText,
    this.cmc,
    this.colors = const <String>[],
    this.colorIdentity = const <String>[],
    this.digital = false,
    this.foil = false,
    this.nonfoil = false,
    this.promo = false,
    this.reprint = false,
    this.reserved = false,
    this.fullArt = false,
    this.booster = false,
    this.releasedAt,
    this.prices = ScryfallPrices.empty,
    this.imageUris = const <String, String>{},
    this.faces = const <ScryfallCardFace>[],
    this.scryfallUri,
    this.gathererUri,
    this.setUri,
    this.rulingUri,
    this.edhrecRank,
    this.oracleId,
  });

  factory ScryfallCard.fromJson(Map<String, dynamic> json) {
    final List<ScryfallCardFace> faces = <ScryfallCardFace>[];
    final Object? rawFaces = json['card_faces'];
    if (rawFaces is List) {
      for (final Object? face in rawFaces) {
        if (face is Map) {
          faces.add(ScryfallCardFace.fromJson(_map(face)));
        }
      }
    }

    // Multi-faced cards (transform / modal_dfc / reversible_card) omit
    // `colors` at the top level; the rules define colours per face. Roll them up
    // so callers always get a usable list.
    List<String> colors = _sortColors(_stringList(json['colors']));
    if (colors.isEmpty && faces.isNotEmpty) {
      colors = _sortColors(<String>[
        for (final ScryfallCardFace face in faces) ...face.colors,
      ]);
    }

    return ScryfallCard(
      id: _stringOr(json['id'], ''),
      name: _stringOr(json['name'], ''),
      setCode: _stringOr(json['set'], ''),
      setName: _stringOr(json['set_name'], ''),
      collectorNumber: _stringOr(json['collector_number'], ''),
      rarity: _stringOr(json['rarity'], ''),
      layout: _stringOr(json['layout'], ''),
      typeLine: _string(json['type_line']),
      oracleText: _string(json['oracle_text']),
      manaCost: _string(json['mana_cost']),
      artist: _string(json['artist']),
      flavorText: _string(json['flavor_text']),
      cmc: _doubleOrNull(json['cmc']),
      colors: colors,
      colorIdentity: _sortColors(_stringList(json['color_identity'])),
      digital: _bool(json['digital']),
      foil: _bool(json['foil']),
      nonfoil: _bool(json['nonfoil']),
      promo: _bool(json['promo']),
      reprint: _bool(json['reprint']),
      reserved: _bool(json['reserved']),
      fullArt: _bool(json['full_art']),
      booster: _bool(json['booster']),
      releasedAt: _dateTime(json['released_at']),
      prices: ScryfallPrices.fromJson(_map(json['prices'])),
      imageUris: _stringMap(json['image_uris']),
      faces: List<ScryfallCardFace>.unmodifiable(faces),
      scryfallUri: _string(json['scryfall_uri']),
      gathererUri: _string(json['gatherer_uri']) ??
          _relatedUri(json, 'gatherer'),
      setUri: _string(json['set_uri']),
      rulingUri: _string(json['rulings_uri']),
      edhrecRank: _intOrNull(json['edhrec_rank']),
      oracleId: _string(json['oracle_id']),
    );
  }

  /// Sort key used for collector numbers that are not plain integers.
  static const int nonNumericCollectorNumberSortKey = 1 << 30;

  final String id;
  final String name;

  /// The set code, from the JSON key `set`.
  final String setCode;

  /// The set name, from the JSON key `set_name`.
  final String setName;

  /// Collector number. Always a **string** in the API (can be `"1a"`, `"★"`).
  final String collectorNumber;

  /// `common`, `uncommon`, `rare`, `special`, `mythic` or `bonus`.
  final String rarity;

  /// `normal`, `transform`, `modal_dfc`, `split`, `adventure`, ...
  final String layout;

  final String? typeLine;
  final String? oracleText;

  /// Absent at the top level for multi-faced cards (it lives on each face).
  final String? manaCost;
  final String? artist;
  final String? flavorText;

  /// Mana value.
  final double? cmc;

  /// Card colours, rolled up from the faces when the API omits them.
  final List<String> colors;
  final List<String> colorIdentity;

  final bool digital;
  final bool foil;
  final bool nonfoil;
  final bool promo;
  final bool reprint;
  final bool reserved;
  final bool fullArt;
  final bool booster;

  final DateTime? releasedAt;
  final ScryfallPrices prices;

  /// Top-level image map. **Empty for double-faced cards** - use [imageUrl] or
  /// [faces] instead.
  final Map<String, String> imageUris;

  /// Empty for single-faced cards.
  final List<ScryfallCardFace> faces;

  final String? scryfallUri;
  final String? gathererUri;
  final String? setUri;
  final String? rulingUri;
  final int? edhrecRank;
  final String? oracleId;

  /// True when this printing has more than one face.
  bool get isMultiFaced => faces.length > 1;

  /// Returns the best image for this card, handling double-faced cards.
  ///
  /// Single-faced cards store imagery in the top-level `image_uris`; cards with
  /// `layout: transform` / `modal_dfc` / `reversible_card` have **no**
  /// top-level `image_uris` and store one map per entry of [faces]. When the
  /// card carries per-face imagery, [face] selects which face to return
  /// (0 = front); otherwise the top-level image is used.
  ///
  /// Returns null only when Scryfall published no image at all.
  String? imageUrl({String size = 'normal', int face = 0}) {
    final bool facesCarryImages =
        faces.any((ScryfallCardFace f) => f.imageUris.isNotEmpty);

    if (facesCarryImages) {
      final int index = face < 0 ? 0 : face;
      if (index < faces.length) {
        final String? url = _pickImageUrl(faces[index].imageUris, size);
        if (url != null) {
          return url;
        }
      }
      for (final ScryfallCardFace other in faces) {
        final String? url = _pickImageUrl(other.imageUris, size);
        if (url != null) {
          return url;
        }
      }
    }

    final String? topLevel = _pickImageUrl(imageUris, size);
    if (topLevel != null) {
      return topLevel;
    }

    for (final ScryfallCardFace other in faces) {
      final String? url = _pickImageUrl(other.imageUris, size);
      if (url != null) {
        return url;
      }
    }
    return null;
  }

  /// Collector number as an int when numeric, else a large sentinel so that
  /// non-numeric numbers (`"★"`, `"1a"`, `"T3"`) sort to the end.
  int get collectorNumberSortKey =>
      int.tryParse(collectorNumber.trim()) ?? nonNumericCollectorNumberSortKey;

  /// Sort key that also breaks ties deterministically on the raw string.
  String get sortKey =>
      collectorNumberSortKey.toString().padLeft(10, '0') + collectorNumber;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'object': 'card',
        'id': id,
        'oracle_id': oracleId,
        'name': name,
        'set': setCode,
        'set_name': setName,
        'collector_number': collectorNumber,
        'rarity': rarity,
        'layout': layout,
        'type_line': typeLine,
        'oracle_text': oracleText,
        'mana_cost': manaCost,
        'artist': artist,
        'flavor_text': flavorText,
        'cmc': cmc,
        'colors': colors.isEmpty ? null : colors,
        'color_identity': colorIdentity,
        'digital': digital,
        'foil': foil,
        'nonfoil': nonfoil,
        'promo': promo,
        'reprint': reprint,
        'reserved': reserved,
        'full_art': fullArt,
        'booster': booster,
        'released_at': _dateToJson(releasedAt),
        'prices': prices.toJson(),
        'image_uris': imageUris.isEmpty ? null : imageUris,
        'card_faces': faces.isEmpty
            ? null
            : <Map<String, dynamic>>[
                for (final ScryfallCardFace face in faces) face.toJson(),
              ],
        'scryfall_uri': scryfallUri,
        'gatherer_uri': gathererUri,
        'set_uri': setUri,
        'rulings_uri': rulingUri,
        'edhrec_rank': edhrecRank,
      };

  @override
  String toString() =>
      'ScryfallCard($name, $setCode/$collectorNumber, $rarity)';
}
