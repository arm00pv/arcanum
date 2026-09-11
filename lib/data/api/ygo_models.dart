// Standalone wire models for the YGOPRODeck Yu-Gi-Oh! API
// (https://db.ygoprodeck.com/api/v7/cardinfo.php).
//
// Nothing in this file imports another Arcanum file, and nothing imports
// Flutter: it is a provider-shaped wire model whose whole job is turning one
// HTTP payload into immutable Dart values. The domain layer (CardGame,
// TcgCard) is deliberately left unaware of YGOPRODeck's quirks, so this
// provider can be added - or dropped - without touching the rest of the app.
//
// Every shape below was read off live responses rather than guessed. The
// quirks that shaped the parser, all confirmed against the real endpoint:
//
//   * card_prices, card_sets, card_images and misc_info are arrays of objects
//     even when they hold exactly one element, so each is read as a list and
//     reduced to a single value.
//   * Every money field is a STRING ("0.33"), never a JSON number, and a card
//     with no market data sends "0.00" or "0" rather than null.
//   * "def" is literally null on Link monsters - not absent - and "level" is 0
//     there, so both stay nullable instead of being normalised away.
//   * typeline, atk, def, level, attribute, archetype, linkval, scale and
//     banlist_info are OMITTED on the cards that do not have them rather than
//     sent as null, so a missing key simply reads as null.
//   * meta is absent entirely on name= and cardset= queries and present on
//     num=/offset= queries, so the page keeps it nullable.
//   * misc_info only appears at all when the request passed &misc=yes.
//
// The parser never throws. It runs against a live third-party API whose
// payload drifts, and one unparseable field must not cost the user the other
// twenty cards on the page, so every accessor degrades to null, an empty list
// or an empty string.

// ---------------------------------------------------------------------------
// Parsing helpers
//
// These exist so that "the provider sent something odd" is decided in exactly
// one place per type instead of being re-litigated inside every fromJson.
// ---------------------------------------------------------------------------

/// Reads a scalar as text, stringifying anything that is not already a string.
///
/// A wrongly-typed scalar is stringified rather than dropped: showing the raw
/// "3" beats silently losing a rarity because the provider wrapped it in an
/// int, and no field read this way is ever used for arithmetic.
String? _stringOrNull(Object? value) {
  if (value is String) {
    return value;
  }
  return value?.toString();
}

/// [String]-typed convenience over [_stringOrNull] for the keys the provider
/// always publishes, where callers should not have to write '?? '''.
String _stringOr(Object? value, String fallback) =>
    _stringOrNull(value) ?? fallback;

/// Reads a required counter, degrading to 0.
///
/// Used only for the card id, where 0 is not a value the provider ever
/// issues, so a garbled id stays detectable instead of silently plausible.
int _int(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim()) ?? 0;
  }
  return 0;
}

/// Reads an optional counter, keeping "absent" distinguishable from "zero".
///
/// The distinction matters for the card level: it is 0 on Link monsters, so a
/// null return must mean the key was missing, never that the provider sent 0.
int? _intOrNull(Object? value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

/// Reads a decimal from either a JSON number or a numeric string.
///
/// Non-finite results are rejected because double.tryParse('NaN') succeeds and
/// would otherwise poison every later comparison with a silent NaN.
double? _doubleOrNull(Object? value) {
  double? parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    parsed = double.tryParse(value.trim());
  }
  if (parsed == null || !parsed.isFinite) {
    return null;
  }
  return parsed;
}

/// Reads a price, collapsing zero to null.
///
/// The provider publishes "0.00" for a card it holds no market data for - it
/// never sends null and never omits the key - so zero means "unknown", not
/// "free". Collapsing it here keeps that lie out of the rest of the app.
double? _priceOrNull(Object? value) {
  final double? parsed = _doubleOrNull(value);
  if (parsed == null || parsed <= 0) {
    return null;
  }
  return parsed;
}

/// Reads a JSON array of strings, ignoring entries that carry no text.
List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  final List<String> out = <String>[];
  for (final Object? item in value) {
    final String? text = _stringOrNull(item);
    if (text != null) {
      out.add(text);
    }
  }
  return List<String>.unmodifiable(out);
}

/// Views any JSON object as a String-keyed map, or null when it is not one.
///
/// jsonDecode hands back a map whose keys are strings and whose values are
/// dynamic, while a hand-built test fixture is typed to Object, and both must
/// work, hence the copy.
Map<String, Object?>? _asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        entry.key.toString(): entry.value,
    };
  }
  return null;
}

/// Reads a JSON array of objects, dropping entries that are not objects.
///
/// Dropping is deliberate: card_prices of [null] and card_sets of [1, 2] both
/// occur in the wild, and an empty list is a far safer outcome than a
/// placeholder value the app would then display as though it were real.
List<Map<String, Object?>> _mapList(Object? value) {
  if (value is! List) {
    return const <Map<String, Object?>>[];
  }
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  for (final Object? item in value) {
    final Map<String, Object?>? map = _asMap(item);
    if (map != null) {
      out.add(map);
    }
  }
  return List<Map<String, Object?>>.unmodifiable(out);
}

// ---------------------------------------------------------------------------
// Prices
// ---------------------------------------------------------------------------

/// The single entry of a card's card_prices array.
///
/// The provider publishes five vendor prices side by side in TWO currencies
/// and never says so in the payload: [cardmarket] is EUR, the other four are
/// USD. Mixing them is the easiest mistake to make with this API, so the
/// currency is spelled out on every field rather than once on the class.
class YgoCardPrices {
  /// Creates a price snapshot from already-parsed values.
  const YgoCardPrices({
    this.cardmarket,
    this.tcgplayer,
    this.ebay,
    this.amazon,
    this.coolstuffinc,
  });

  /// Reads one card_prices entry.
  ///
  /// Each vendor is parsed independently, so one garbled vendor costs only
  /// that vendor instead of the whole price block.
  factory YgoCardPrices.fromJson(Map<String, Object?> json) => YgoCardPrices(
    cardmarket: _priceOrNull(json['cardmarket_price']),
    tcgplayer: _priceOrNull(json['tcgplayer_price']),
    ebay: _priceOrNull(json['ebay_price']),
    amazon: _priceOrNull(json['amazon_price']),
    coolstuffinc: _priceOrNull(json['coolstuffinc_price']),
  );

  /// Cardmarket price in EUR. Null when the provider sent 0 or garbage.
  final double? cardmarket;

  /// TCGplayer price in USD. This is the figure the app treats as the market
  /// price; see [bestUsd].
  final double? tcgplayer;

  /// eBay price in USD.
  final double? ebay;

  /// Amazon price in USD. Routinely an order of magnitude above the others
  /// because it tracks third-party listings rather than the game's market.
  final double? amazon;

  /// CoolStuffInc price in USD.
  final double? coolstuffinc;

  /// The one USD figure a card row should display.
  ///
  /// TCGplayer is the reference market for Yu-Gi-Oh!, so it wins outright when
  /// present - even when another vendor is cheaper - because a consistent
  /// source matters more than the lowest number. Only when TCGplayer holds no
  /// data does the cheapest of the remaining USD vendors stand in. The EUR
  /// price is never used here: showing euros as dollars would be wrong by
  /// whatever the exchange rate happens to be that day.
  double? get bestUsd {
    final double? preferred = tcgplayer;
    if (preferred != null) {
      return preferred;
    }
    final List<double> alternatives = <double>[?ebay, ?amazon, ?coolstuffinc];
    if (alternatives.isEmpty) {
      return null;
    }
    return alternatives.reduce((double a, double b) => a < b ? a : b);
  }

  /// True when the provider had no usable price in any currency.
  bool get isEmpty =>
      cardmarket == null &&
      tcgplayer == null &&
      ebay == null &&
      amazon == null &&
      coolstuffinc == null;

  @override
  String toString() =>
      'YgoCardPrices(tcgplayer: $tcgplayer, cardmarket: $cardmarket)';
}

// ---------------------------------------------------------------------------
// Sets, images and misc data
// ---------------------------------------------------------------------------

/// One printing of a card: an entry of card_sets.
///
/// Rows are NOT unique by [code]. A card printed at several rarities inside
/// one set arrives as several rows sharing an identical [code] - the same
/// RA03-EN001 twice, once "Super Rare" and once "Starlight Rare" - so a caller
/// that keys a map by [code] silently drops printings. Key by ([code],
/// [rarity]) instead, and expect the row count to exceed the number of
/// distinct codes.
class YgoCardSet {
  /// Creates a set row from already-parsed values.
  const YgoCardSet({
    this.name = '',
    this.code = '',
    this.rarity = '',
    this.rarityCode = '',
    this.price = '',
  });

  /// Reads one card_sets entry.
  factory YgoCardSet.fromJson(Map<String, Object?> json) => YgoCardSet(
    name: _stringOr(json['set_name'], ''),
    code: _stringOr(json['set_code'], ''),
    rarity: _stringOr(json['set_rarity'], ''),
    rarityCode: _stringOr(json['set_rarity_code'], ''),
    price: _stringOr(json['set_price'], ''),
  );

  /// Display name of the set, e.g. 2016 Mega-Tins.
  final String name;

  /// The collector code printed on the card, e.g. CT13-EN003.
  final String code;

  /// Rarity name, e.g. Ultra Rare.
  final String rarity;

  /// Short rarity code, e.g. (UR).
  final String rarityCode;

  /// Price exactly as the provider sent it, still a STRING.
  ///
  /// Deliberately not converted to a double: the payload never says which
  /// currency this particular field is in, so a numeric field here would
  /// invite the app to print an unlabelled number. Use the card's price block
  /// for money and keep this for what the print run cost at the time.
  final String price;

  @override
  String toString() => 'YgoCardSet($code, $rarity)';
}

/// One artwork entry of card_images.
///
/// The three URLs point at the same art at different sizes; they are kept
/// separately because the cropped variant has different framing (square, art
/// only) and cannot be substituted for the other two in a grid.
class YgoCardImage {
  /// Creates an image entry from already-parsed values.
  const YgoCardImage({
    this.id = 0,
    this.imageUrl = '',
    this.imageUrlSmall = '',
    this.imageUrlCropped = '',
  });

  /// Reads one card_images entry.
  factory YgoCardImage.fromJson(Map<String, Object?> json) => YgoCardImage(
    id: _int(json['id']),
    imageUrl: _stringOr(json['image_url'], ''),
    imageUrlSmall: _stringOr(json['image_url_small'], ''),
    imageUrlCropped: _stringOr(json['image_url_cropped'], ''),
  );

  /// Passcode of this artwork. Normally the card's own id, but alternate arts
  /// carry a different one, which is what makes them addressable at all.
  final int id;

  /// Full-size artwork.
  final String imageUrl;

  /// Thumbnail artwork, for lists and grids.
  final String imageUrlSmall;

  /// Square art-only crop, for chips and avatars.
  final String imageUrlCropped;

  /// True when the provider sent no usable artwork at all.
  bool get isEmpty => imageUrl.isEmpty && imageUrlSmall.isEmpty;

  @override
  String toString() => 'YgoCardImage($id)';
}

/// The single entry of misc_info, returned only for &misc=yes requests.
class YgoMiscInfo {
  /// Creates a misc block from already-parsed values.
  const YgoMiscInfo({
    this.views,
    this.viewsWeek,
    this.upvotes,
    this.downvotes,
    this.konamiId,
    this.hasEffect = false,
    this.formats = const <String>[],
    this.treatedAs,
    this.tcgDate,
    this.ocgDate,
    this.mdRarity,
    this.betaName,
  });

  /// Reads the misc_info entry.
  factory YgoMiscInfo.fromJson(Map<String, Object?> json) => YgoMiscInfo(
    views: _intOrNull(json['views']),
    viewsWeek: _intOrNull(json['viewsweek']),
    upvotes: _intOrNull(json['upvotes']),
    downvotes: _intOrNull(json['downvotes']),
    konamiId: _intOrNull(json['konami_id']),
    hasEffect: _int(json['has_effect']) != 0,
    formats: _stringList(json['formats']),
    treatedAs: _stringOrNull(json['treated_as']),
    tcgDate: _stringOrNull(json['tcg_date']),
    ocgDate: _stringOrNull(json['ocg_date']),
    mdRarity: _stringOrNull(json['md_rarity']),
    betaName: _stringOrNull(json['beta_name']),
  );

  /// Lifetime page views on ygoprodeck.com.
  final int? views;

  /// Views in the last seven days.
  final int? viewsWeek;

  /// Community upvotes.
  final int? upvotes;

  /// Community downvotes.
  final int? downvotes;

  /// Konami's own passcode for the card. It differs from the API id for some
  /// reprints, so it is the key to use when matching against Konami data.
  final int? konamiId;

  /// Whether the card has an effect text box at all.
  ///
  /// The wire key has_effect is the integer 0 or 1 rather than a JSON
  /// boolean, so it is normalised to a bool once here instead of at every
  /// call site.
  final bool hasEffect;

  /// Formats the card is legal in, e.g. TCG Advanced, Duel Links.
  ///
  /// Kept exactly as sent, INCLUDING duplicates: the provider really does
  /// repeat a format when a card sits in two sub-lists of it. Use
  /// [uniqueFormats] when the duplicates would be visible to the user.
  final List<String> formats;

  /// The name this card is treated as for rules purposes, when it has one.
  final String? treatedAs;

  /// TCG release date as the provider's raw YYYY-MM-DD string.
  ///
  /// Left unparsed on purpose: a malformed date is more useful shown verbatim
  /// than silently dropped, and nothing in the app sorts or compares on it.
  final String? tcgDate;

  /// OCG release date, raw, for the same reason as [tcgDate].
  final String? ocgDate;

  /// Rarity in Master Duel, when the card appears in that game.
  final String? mdRarity;

  /// Original name from the beta card database, for cards later renamed.
  final String? betaName;

  /// [formats] with duplicates removed, original order preserved.
  List<String> get uniqueFormats {
    final Set<String> seen = <String>{};
    final List<String> out = <String>[];
    for (final String format in formats) {
      if (seen.add(format)) {
        out.add(format);
      }
    }
    return List<String>.unmodifiable(out);
  }

  @override
  String toString() => 'YgoMiscInfo(konami: $konamiId, formats: $formats)';
}

/// The banlist_info object, sent only when the card really is restricted.
///
/// The key is absent - not null - for every unrestricted card, which is the
/// overwhelming majority, so an all-null [YgoBanlistInfo] never appears in
/// practice: the card's field is null instead, and this class only ever holds
/// real statuses.
class YgoBanlistInfo {
  /// Creates a banlist block from already-parsed values.
  const YgoBanlistInfo({this.tcg, this.ocg, this.goat});

  /// Reads a banlist_info object.
  factory YgoBanlistInfo.fromJson(Map<String, Object?> json) => YgoBanlistInfo(
    tcg: _stringOrNull(json['ban_tcg']),
    ocg: _stringOrNull(json['ban_ocg']),
    goat: _stringOrNull(json['ban_goat']),
  );

  /// Status in the TCG: Forbidden, Limited or Semi-Limited.
  final String? tcg;

  /// Status in the OCG, which is frequently different from [tcg].
  final String? ocg;

  /// Status on the Goat Format list, a community-run historical format.
  final String? goat;

  @override
  String toString() => 'YgoBanlistInfo(tcg: $tcg, ocg: $ocg, goat: $goat)';
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

/// One card object from cardinfo.php.
class YgoCard {
  /// Creates a card from already-parsed values.
  ///
  /// The identity strings are non-nullable on purpose: YGOPRODeck always
  /// publishes them, and forcing a null check on the name at every call site
  /// would cost more than it protects. [YgoCard.fromJson] maps a missing or
  /// garbled one to the empty string, which callers can test with a single
  /// isEmpty.
  const YgoCard({
    required this.id,
    required this.name,
    required this.type,
    required this.humanReadableCardType,
    required this.frameType,
    required this.description,
    required this.ygoprodeckUrl,
    this.typeLine = const <String>[],
    this.race,
    this.attack,
    this.defense,
    this.level,
    this.attribute,
    this.archetype,
    this.linkValue,
    this.linkMarkers = const <String>[],
    this.scale,
    this.pendulumDescription,
    this.monsterDescription,
    this.banlist,
    this.sets = const <YgoCardSet>[],
    this.images = const <YgoCardImage>[],
    this.prices,
    this.miscInfo,
  });

  /// Reads one entry of the response's data array.
  ///
  /// Every key goes through a helper that tolerates the wrong type, so this
  /// factory returns a card for any object at all - including an empty one -
  /// rather than throwing on one bad field half-way down a page of results.
  factory YgoCard.fromJson(Map<String, Object?> json) {
    final List<Map<String, Object?>> priceEntries = _mapList(
      json['card_prices'],
    );
    final Map<String, Object?>? banlistInfo = _asMap(json['banlist_info']);
    final List<Map<String, Object?>> miscEntries = _mapList(json['misc_info']);
    return YgoCard(
      id: _int(json['id']),
      name: _stringOr(json['name'], ''),
      typeLine: _stringList(json['typeline']),
      type: _stringOr(json['type'], ''),
      humanReadableCardType: _stringOr(json['humanReadableCardType'], ''),
      frameType: _stringOr(json['frameType'], ''),
      description: _stringOr(json['desc'], ''),
      ygoprodeckUrl: _stringOr(json['ygoprodeck_url'], ''),
      race: _stringOrNull(json['race']),
      attack: _intOrNull(json['atk']),
      defense: _intOrNull(json['def']),
      level: _intOrNull(json['level']),
      attribute: _stringOrNull(json['attribute']),
      archetype: _stringOrNull(json['archetype']),
      linkValue: _intOrNull(json['linkval']),
      linkMarkers: _stringList(json['linkmarkers']),
      scale: _intOrNull(json['scale']),
      pendulumDescription: _stringOrNull(json['pend_desc']),
      monsterDescription: _stringOrNull(json['monster_desc']),
      banlist: banlistInfo == null
          ? null
          : YgoBanlistInfo.fromJson(banlistInfo),
      sets: <YgoCardSet>[
        for (final Map<String, Object?> entry in _mapList(json['card_sets']))
          YgoCardSet.fromJson(entry),
      ],
      images: <YgoCardImage>[
        for (final Map<String, Object?> entry in _mapList(json['card_images']))
          YgoCardImage.fromJson(entry),
      ],
      prices: priceEntries.isEmpty
          ? null
          : YgoCardPrices.fromJson(priceEntries.first),
      miscInfo: miscEntries.isEmpty
          ? null
          : YgoMiscInfo.fromJson(miscEntries.first),
    );
  }

  /// Konami passcode, the card's stable identity across the whole API.
  ///
  /// 0 means the payload carried no usable id; treat that as an unparseable
  /// card rather than as a real card whose passcode happens to be zero.
  final int id;

  /// Printed English name.
  final String name;

  /// The monster's types, e.g. Spellcaster, Normal.
  ///
  /// Present ONLY on monsters - the key is absent on Spell and Trap cards - so
  /// an empty list means "not a monster, or not published", never "no types".
  final List<String> typeLine;

  /// Full type line, e.g. Pendulum Effect Monster.
  final String type;

  /// Display-friendly type, e.g. Link Effect Monster.
  final String humanReadableCardType;

  /// Machine-readable frame, e.g. effect, link, spell, effect_pendulum.
  ///
  /// This is the field to switch on for layout decisions: it is a small,
  /// closed set, whereas [type] is free text with a new variant every few
  /// sets and will silently miss cases.
  final String frameType;

  /// Rules or flavour text, as printed.
  final String description;

  /// Monster type (Spellcaster) or Spell/Trap property (Quick-Play).
  final String? race;

  /// ATK, from the JSON key atk. Absent on Spell and Trap cards.
  final int? attack;

  /// DEF, from the JSON key def.
  ///
  /// The wire key is read explicitly because "def" is a Dart identifier only
  /// by accident and reads like a keyword; the field is named defense so call
  /// sites stay legible. Null on Link monsters, which have no DEF at all, and
  /// absent on Spell and Trap cards, which have neither stat.
  final int? defense;

  /// Level, from the JSON key level.
  ///
  /// Two traps live here, both left exactly as the provider sends them rather
  /// than normalised. On XYZ monsters this number is the RANK, and on Link
  /// monsters it is 0 - not null - because Links have neither level nor rank.
  /// Read [frameType] or [linkValue] to tell those apart; guessing from the
  /// number alone would mislabel every XYZ monster in the game.
  final int? level;

  /// Attribute, e.g. DARK, LIGHT, DIVINE. Null on Spell and Trap cards.
  final String? attribute;

  /// Archetype name, e.g. Dark Magician.
  ///
  /// The key is OMITTED when a card belongs to no archetype, so null is the
  /// common case and is not an error worth logging.
  final String? archetype;

  /// Link rating, on Link monsters only.
  final int? linkValue;

  /// Link arrows, e.g. Top, Bottom-Left, Bottom-Right.
  ///
  /// Only Link monsters have these, so an empty list is the normal state for
  /// every other card rather than a parse failure.
  final List<String> linkMarkers;

  /// Pendulum scale, on Pendulum monsters only.
  final int? scale;

  /// Pendulum effect text, on Pendulum monsters only.
  final String? pendulumDescription;

  /// The monster effect text of a Pendulum card.
  ///
  /// The provider splits this out of [description] so the two printed boxes
  /// stay separable, and a caller rendering them must not fall back to
  /// [description] or the pendulum text would appear twice.
  final String? monsterDescription;

  /// Restriction status, or null when the card is on no list at all.
  ///
  /// Null is the normal case: the provider omits banlist_info entirely for
  /// unrestricted cards instead of sending an empty object.
  final YgoBanlistInfo? banlist;

  /// Every printing of this card, newest sets first.
  ///
  /// May contain several rows with the same set code at different rarities -
  /// see [YgoCardSet] before keying anything by set code.
  final List<YgoCardSet> sets;

  /// Artwork variants. The provider serves at least one for any real card.
  final List<YgoCardImage> images;

  /// Market prices, or null when the block was missing or unusable.
  ///
  /// The array always holds exactly one object, but it is still an array, so
  /// it is read as one and collapsed; an empty or non-object entry yields null
  /// rather than a price object holding five fake zeroes.
  final YgoCardPrices? prices;

  /// Community and metadata block, present only for &misc=yes requests.
  final YgoMiscInfo? miscInfo;

  /// Permalink to the card's page on ygoprodeck.com.
  final String ygoprodeckUrl;

  /// The card's market price in USD, or null when there is no market data.
  ///
  /// The convenience the UI actually wants: it hides both the missing price
  /// block and the EUR/USD split behind one nullable figure, so a card row
  /// never has to know which vendor answered.
  double? get bestUsdPrice => prices?.bestUsd;

  /// True when the card is restricted in at least one format.
  bool get isOnBanlist => banlist != null;

  /// First artwork, or null when the provider published none.
  YgoCardImage? get primaryImage => images.isEmpty ? null : images.first;

  /// Best thumbnail URL for lists, falling back to the full-size art.
  ///
  /// A grid cell wants the small file, but some printings only publish the
  /// large one; falling back keeps the cell filled instead of showing a gap
  /// the user would read as a broken card.
  String? get thumbnailUrl {
    final YgoCardImage? image = primaryImage;
    if (image == null) {
      return null;
    }
    if (image.imageUrlSmall.isNotEmpty) {
      return image.imageUrlSmall;
    }
    if (image.imageUrl.isNotEmpty) {
      return image.imageUrl;
    }
    return null;
  }

  @override
  String toString() => 'YgoCard($id, $name, $type)';
}

// ---------------------------------------------------------------------------
// Pagination
// ---------------------------------------------------------------------------

/// The meta block of a paginated response.
///
/// Only num= and offset= queries produce it, and it is what makes paging
/// possible: the provider caps a page at 100 rows and truncates silently, so
/// without [nextPage] a caller cannot tell a complete result set from the
/// first hundred of thirteen thousand.
class YgoMeta {
  /// Creates a meta block from already-parsed values.
  ///
  /// The counters are non-nullable and degrade to 0: inside a meta block the
  /// provider always sends all of them, so a 0 is unambiguously "no rows" and
  /// never a stand-in for a value that was present but unreadable.
  const YgoMeta({
    this.generated,
    this.currentRows = 0,
    this.totalRows = 0,
    this.rowsRemaining = 0,
    this.totalPages = 0,
    this.pagesRemaining = 0,
    this.nextPage,
    this.nextPageOffset,
  });

  /// Reads the meta object.
  factory YgoMeta.fromJson(Map<String, Object?> json) => YgoMeta(
    generated: _stringOrNull(json['generated']),
    currentRows: _int(json['current_rows']),
    totalRows: _int(json['total_rows']),
    rowsRemaining: _int(json['rows_remaining']),
    totalPages: _int(json['total_pages']),
    pagesRemaining: _int(json['pages_remaining']),
    nextPage: _stringOrNull(json['next_page']),
    nextPageOffset: _intOrNull(json['next_page_offset']),
  );

  /// When the provider generated this page, as the raw string it sent.
  ///
  /// Kept verbatim because the format has changed between API revisions, and a
  /// value that cannot be parsed is still worth showing in a diagnostics view.
  final String? generated;

  /// Rows in this page, normally 100 on a capped request.
  final int currentRows;

  /// Rows matching the query across the whole database.
  final int totalRows;

  /// Rows still unread. Zero on the last page.
  final int rowsRemaining;

  /// Pages matching the query in total.
  final int totalPages;

  /// Pages still unread. Zero on the last page.
  final int pagesRemaining;

  /// URL of the next page of results.
  ///
  /// Null on the last page AND on a full-database fetch, where the provider
  /// omits the key because there is nothing to page to. Callers should test
  /// this rather than comparing counters: it is the provider's own answer, and
  /// it already carries the query and misc flags forward, which a hand-built
  /// URL would have to rebuild and would eventually get wrong.
  final String? nextPage;

  /// The offset [nextPage] uses, handy for progress reporting.
  final int? nextPageOffset;

  /// True when the provider published another page to fetch.
  bool get hasNextPage => nextPage != null;

  @override
  String toString() =>
      'YgoMeta($currentRows/$totalRows rows, $pagesRemaining pages left)';
}

/// A parsed cardinfo.php response.
class YgoPage {
  /// Creates a page from already-parsed values.
  const YgoPage({this.cards = const <YgoCard>[], this.meta});

  /// Reads a whole response body.
  ///
  /// A missing meta is tolerated rather than treated as an error because it
  /// genuinely is absent on name= and cardset= queries: those return every
  /// match in one response and have nothing to paginate, so rejecting them
  /// would break search outright.
  factory YgoPage.fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? meta = _asMap(json['meta']);
    return YgoPage(
      cards: <YgoCard>[
        for (final Map<String, Object?> entry in _mapList(json['data']))
          YgoCard.fromJson(entry),
      ],
      meta: meta == null ? null : YgoMeta.fromJson(meta),
    );
  }

  /// The cards in this page, in the order the provider ranked them.
  final List<YgoCard> cards;

  /// Pagination block, or null when the query was not paginated.
  final YgoMeta? meta;

  /// True when this page carries no cards.
  bool get isEmpty => cards.isEmpty;

  /// True when the provider says another page is available.
  ///
  /// False for a non-paginated query as well, because [meta] is null there and
  /// such a response already contains every match.
  bool get hasNextPage => meta?.nextPage != null;

  /// Number of cards in this page.
  int get length => cards.length;

  @override
  String toString() => 'YgoPage($length cards, meta: $meta)';
}
