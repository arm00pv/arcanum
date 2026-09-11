import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/domain/models/card_game.dart';

/// One face of a multi-faced printing.
///
/// Magic's transform and modal cards have two faces with their own art and
/// rules text. Pokémon cards have a single face, so this list is empty for them.
class TcgCardFace {
  const TcgCardFace({
    this.name,
    this.typeLine,
    this.text,
    this.cost,
    this.artist,
    this.imageUris = const {},
  });

  final String? name;
  final String? typeLine;
  final String? text;
  final String? cost;
  final String? artist;
  final Map<String, String> imageUris;

  String? imageUrl({String size = 'normal'}) =>
      imageUris[size] ?? imageUris['normal'] ?? imageUris['large'] ?? imageUris['small'];
}

/// Market prices for one printing, keyed by physical finish.
///
/// Different games publish different numbers. Magic gives TCGplayer market
/// prices for non-foil, foil and etched plus Cardmarket euros and MTGO tickets;
/// Pokémon gives per-variant market prices (normal, holofoil, reverse holo,
/// 1st edition). Rather than pretend they are the same, the canonical map is
/// [byFinish] and anything the provider reports under a different name is kept
/// in [secondary] so it can still be shown without being mislabelled.
class TcgPrices {
  const TcgPrices({
    this.byFinish = const {},
    this.secondary = const {},
    this.updatedAt,
  });

  /// Price in USD for each physical finish, keyed by [CardFinish.code].
  final Map<String, double?> byFinish;

  /// Provider-specific extras such as Cardmarket euros or MTGO tickets.
  final Map<String, double?> secondary;

  /// When the provider last refreshed these numbers.
  final DateTime? updatedAt;

  static const empty = TcgPrices();

  /// The price for a finish, or null when the game has no such finish.
  double? priceFor(CardFinish finish) => byFinish[finish.code];

  double? get nonfoil => byFinish[CardFinish.nonfoil.code];
  double? get foil => byFinish[CardFinish.foil.code];
  double? get etched => byFinish[CardFinish.etched.code];
  double? get holofoil => byFinish[CardFinish.holofoil.code];
  double? get reverseHolofoil => byFinish[CardFinish.reverseHolofoil.code];
  double? get firstEdition => byFinish[CardFinish.firstEdition.code];
  double? get firstEditionHolofoil =>
      byFinish[CardFinish.firstEditionHolofoil.code];

  double? get eur => secondary['eur'];
  double? get tix => secondary['tix'];

  /// True when no finish has a usable price.
  bool get isEmpty => byFinish.values.every((v) => v == null || v <= 0);

  /// The most representative price: the cheapest finish actually quoted.
  ///
  /// Used by list rows where showing every variant would be noise. Null when
  /// nothing is priced.
  double? get from {
    final values = byFinish.values.whereType<double>().where((v) => v > 0).toList();
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  /// The finishes that actually carry a price, in declaration order.
  List<CardFinish> get quotedFinishes => CardFinish.values
      .where((f) => (byFinish[f.code] ?? 0) > 0)
      .toList();

  Map<String, Object?> toJson() => {
        'byFinish': byFinish,
        'secondary': secondary,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  factory TcgPrices.fromJson(Map<String, Object?>? json) {
    if (json == null) return empty;
    Map<String, double?> read(String key) {
      final raw = json[key];
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          e.key.toString(): (e.value as num?)?.toDouble(),
      };
    }

    final updated = json['updatedAt'];
    return TcgPrices(
      byFinish: read('byFinish'),
      secondary: read('secondary'),
      updatedAt: updated is String ? DateTime.tryParse(updated) : null,
    );
  }
}

/// A printing, independent of which game it belongs to.
///
/// This is the model the whole app speaks. Deliberately shaped so that a Magic
/// card and a Pokémon card can both be described without either being treated as
/// the degenerate case of the other: fields that only one game uses are
/// nullable, and [extras] carries anything genuinely game-specific.
class TcgCard {
  const TcgCard({
    required this.game,
    required this.id,
    required this.setCode,
    required this.setName,
    required this.name,
    required this.collectorNumber,
    required this.rarity,
    this.layout = '',
    this.typeLine,
    this.oracleText,
    this.manaCost,
    this.artist,
    this.flavorText,
    this.cmc,
    this.colors = const [],
    this.colorIdentity = const [],
    this.digital = false,
    this.foil = false,
    this.nonfoil = false,
    this.promo = false,
    this.reprint = false,
    this.reserved = false,
    this.fullArt = false,
    this.booster = false,
    this.releasedAt,
    this.prices = TcgPrices.empty,
    this.imageUris = const {},
    this.faces = const [],
    this.scryfallUri,
    this.edhrecRank,
    this.oracleId,
    this.extras = const {},
  });

  /// Which game this printing belongs to.
  final CardGame game;

  /// Provider-scoped unique id (a Scryfall UUID for Magic, `base1-4` for Pokémon).
  final String id;

  /// Set code (Magic) or set id (Pokémon), e.g. `lea` or `base1`.
  final String setCode;
  final String setName;

  final String name;

  /// The number printed on the card. Not always numeric: Pokémon uses `TG01`,
  /// `SV001` and `H1`, Magic uses `★` and `1a`.
  final String collectorNumber;

  final String rarity;

  /// Magic's layout (`normal`, `transform`, …). Empty for Pokémon.
  final String layout;

  /// Magic's type line, or a composed Pokémon line such as `Pokémon - Stage 1`.
  final String? typeLine;

  /// Rules text: Magic's oracle text, or a Pokémon card's attacks and rules.
  final String? oracleText;

  /// Magic's mana cost. Null for Pokémon, which has no such concept.
  final String? manaCost;

  final String? artist;
  final String? flavorText;

  /// Magic's converted mana cost. Repurposed for Pokémon as HP / 100 so that
  /// existing "cost" sorting still means something sensible.
  final double? cmc;

  /// Magic colours, or Pokémon energy types.
  final List<String> colors;

  /// Magic's colour identity. Empty for Pokémon.
  final List<String> colorIdentity;

  final bool digital, foil, nonfoil, promo, reprint, reserved, fullArt, booster;
  final DateTime? releasedAt;
  final TcgPrices prices;

  /// Image URLs keyed by size. Empty for multi-faced Magic cards, whose art
  /// lives on [faces].
  final Map<String, String> imageUris;

  final List<TcgCardFace> faces;

  /// Provider page for this printing, when there is one.
  final String? scryfallUri;

  /// EDHREC popularity rank (Magic only). Null elsewhere.
  final int? edhrecRank;

  /// Groups reprints of the same card: Magic's oracle id, or the Pokémon card
  /// name normalised. Null when the provider gives nothing comparable.
  final String? oracleId;

  /// Anything genuinely game-specific, so the model never has to grow a field
  /// that only one game will ever read.
  final Map<String, Object?> extras;

  bool get isMultiFaced => faces.length > 1;

  /// The best image for this card, handling multi-faced cards.
  String? imageUrl({String size = 'normal', int face = 0}) {
    final direct = imageUris[size] ??
        imageUris['normal'] ??
        imageUris['large'] ??
        imageUris['small'];
    if (direct != null && face == 0) return direct;
    if (faces.isEmpty) return direct;
    final index = face.clamp(0, faces.length - 1);
    return faces[index].imageUrl(size: size) ?? direct;
  }

  /// Sort key for collector numbers that are not plain integers.
  ///
  /// Pokémon mixes `4`, `TG01`, `SV001` and `H1` inside a single set, and
  /// Magic uses suffixes like `1a`. Numeric prefixes sort numerically and
  /// anything else sorts after, alphabetically — which is exactly how a binder
  /// is ordered.
  int get collectorNumberSortKey {
    final trimmed = collectorNumber.trim();
    final direct = int.tryParse(trimmed);
    if (direct != null) return direct;

    final match = RegExp(r'^(\D*)(\d+)').firstMatch(trimmed);
    if (match != null) {
      final prefix = match.group(1) ?? '';
      final digits = int.tryParse(match.group(2) ?? '') ?? 0;
      // Prefixed numbers sort after plain numbers, grouped by prefix letter.
      final prefixRank = prefix.isEmpty ? 0 : 1 + (prefix.codeUnitAt(0) % 64);
      return prefixRank * 1000000 + digits;
    }
    return 1 << 30;
  }

  /// A stable key for grouping reprints when the provider gives no oracle id.
  static String normaliseName(String name) {
    final base = name.split('//').first;
    return base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// The provider's own short code for this printing's rarity, or null.
  ///
  /// A rarity tier is not a rarity: "Super Rare" and "Secret Rare" are both
  /// premium tiers, and a collector reading a badge is asking which one they
  /// hold. Where the provider publishes the shorthand collectors actually use -
  /// Yu-Gi-Oh! sends "(UR)", "(ScR)", "(StR)" in `set_rarity_code` - that code
  /// is the honest thing to show. Providers that publish only a tier, as Magic
  /// and Pokémon do, leave this null and the caller falls back to the tier.
  String? get rarityCode {
    final raw = extras['rarityCode'];
    if (raw is! String) return null;
    final stripped = raw.trim().replaceAll(RegExp(r'[()]'), '').trim();
    return stripped.isEmpty ? null : stripped;
  }

  TcgCard copyWith({
    String? id,
    String? setCode,
    String? setName,
    String? name,
    String? collectorNumber,
    String? rarity,
    TcgPrices? prices,
    Map<String, String>? imageUris,
    List<TcgCardFace>? faces,
    Map<String, Object?>? extras,
  }) =>
      TcgCard(
        game: game,
        id: id ?? this.id,
        setCode: setCode ?? this.setCode,
        setName: setName ?? this.setName,
        name: name ?? this.name,
        collectorNumber: collectorNumber ?? this.collectorNumber,
        rarity: rarity ?? this.rarity,
        layout: layout,
        typeLine: typeLine,
        oracleText: oracleText,
        manaCost: manaCost,
        artist: artist,
        flavorText: flavorText,
        cmc: cmc,
        colors: colors,
        colorIdentity: colorIdentity,
        digital: digital,
        foil: foil,
        nonfoil: nonfoil,
        promo: promo,
        reprint: reprint,
        reserved: reserved,
        fullArt: fullArt,
        booster: booster,
        releasedAt: releasedAt,
        prices: prices ?? this.prices,
        imageUris: imageUris ?? this.imageUris,
        faces: faces ?? this.faces,
        scryfallUri: scryfallUri,
        edhrecRank: edhrecRank,
        oracleId: oracleId,
        extras: extras ?? this.extras,
      );
}

/// A set, independent of which game it belongs to.
class TcgSet {
  const TcgSet({
    required this.game,
    required this.id,
    required this.code,
    required this.name,
    required this.setType,
    this.releasedAt,
    this.cardCount = 0,
    this.printedSize,
    this.iconSvgUri,
    this.logoUri,
    this.series,
    this.digital = false,
    this.foilOnly = false,
    this.nonfoilOnly = false,
    this.parentSetCode,
    this.blockCode,
    this.block,
    this.collectorNumberStart,
    this.scryfallUri,
    this.searchUri,
  });

  final CardGame game;
  final String id;

  /// Short code used in the UI and by the API (Magic) or the set id (Pokémon).
  final String code;
  final String name;
  final String setType;
  final DateTime? releasedAt;
  final int cardCount;
  final int? printedSize;

  /// SVG set symbol. Magic only — Pokémon ships PNG symbols and logos.
  final String? iconSvgUri;

  /// Raster set symbol or logo. Pokémon uses this; Magic leaves it null.
  final String? logoUri;

  /// Pokémon's series grouping, e.g. "Base", "Scarlet & Violet". Null for Magic.
  final String? series;

  final bool digital, foilOnly, nonfoilOnly;
  final String? parentSetCode;
  final String? blockCode;
  final String? block;
  final int? collectorNumberStart;
  final String? scryfallUri;
  final String? searchUri;

  /// Whether the set has an SVG symbol or only a raster one.
  bool get hasSvgIcon => iconSvgUri != null && iconSvgUri!.isNotEmpty;
}
