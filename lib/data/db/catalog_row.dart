import 'dart:convert';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// One catalogue row, turned into a model and back.
///
/// A server row is a local row - \`catalog_cards\` and \`catalog_sets\` were named
/// and typed as the SQLite tables are, on purpose, so that the thing which
/// reads a row into a [TcgCard] is written once and used by every path that
/// stores catalogue data. Two copies of this is how the device and the shared
/// catalogue start disagreeing about a card without either of them failing.
///
/// What is deliberately *not* part of the shared shape is the wire. Postgres
/// carries a boolean where SQLite stores 0/1 and a \`jsonb\` object where SQLite
/// stores a JSON string, and the reader for a shared row converts those before
/// the row reaches here. Everything below therefore only ever sees the shape
/// the local database has.
abstract final class CatalogRow {
  /// The row one printing is stored as.
  ///
  /// [now] stamps \`prices_updated_at\`, because the printing and its price
  /// arrive in the same answer and there is no second moment to record for the
  /// same write.
  static Map<String, Object?> cardToRow(CardGame game, TcgCard c, int now) => {
    'id': c.id,
    'game': game.id,
    'oracle_id': c.oracleId,
    'set_code': c.setCode,
    'set_name': c.setName,
    'name': c.name,
    'collector_number': c.collectorNumber,
    'collector_sort': c.collectorNumberSortKey,
    'rarity': c.rarity,
    'layout': c.layout,
    'type_line': c.typeLine,
    'oracle_text': c.oracleText,
    'mana_cost': c.manaCost,
    'cmc': c.cmc,
    'colors': c.colors.join(','),
    'color_identity': c.colorIdentity.join(','),
    'artist': c.artist,
    'flavor_text': c.flavorText,
    'image_small': c.imageUris['small'],
    'image_normal': c.imageUris['normal'],
    'image_large': c.imageUris['large'],
    'image_art_crop': c.imageUris['art_crop'],
    'image_png': c.imageUris['png'],
    'back_image_small': c.faces.length > 1
        ? c.faces[1].imageUris['small']
        : null,
    'back_image_normal': c.faces.length > 1
        ? c.faces[1].imageUris['normal']
        : null,
    'prices_json': jsonEncode(c.prices.toJson()),
    'prices_updated_at': now,
    'digital': c.digital ? 1 : 0,
    'promo': c.promo ? 1 : 0,
    'reprint': c.reprint ? 1 : 0,
    'reserved': c.reserved ? 1 : 0,
    'full_art': c.fullArt ? 1 : 0,
    'booster': c.booster ? 1 : 0,
    'foil': c.foil ? 1 : 0,
    'nonfoil': c.nonfoil ? 1 : 0,
    'edhrec_rank': c.edhrecRank,
    'released_at': c.releasedAt?.toIso8601String().split('T').first,
    'extras_json': c.extras.isEmpty
        ? null
        : jsonEncode(c.extras.map((k, v) => MapEntry(k, v))),
  };

  /// The printing a stored row describes.
  static TcgCard cardFromRow(CardGame game, Map<String, Object?> r) => TcgCard(
    game: game,
    id: r['id'] as String,
    oracleId: r['oracle_id'] as String?,
    setCode: r['set_code'] as String,
    setName: (r['set_name'] as String?) ?? '',
    name: r['name'] as String,
    collectorNumber: (r['collector_number'] as String?) ?? '',
    rarity: (r['rarity'] as String?) ?? 'unknown',
    layout: (r['layout'] as String?) ?? '',
    typeLine: r['type_line'] as String?,
    oracleText: r['oracle_text'] as String?,
    manaCost: r['mana_cost'] as String?,
    artist: r['artist'] as String?,
    flavorText: r['flavor_text'] as String?,
    cmc: (r['cmc'] as num?)?.toDouble(),
    colors: _split(r['colors']),
    colorIdentity: _split(r['color_identity']),
    digital: (r['digital'] as int? ?? 0) == 1,
    foil: (r['foil'] as int? ?? 0) == 1,
    nonfoil: (r['nonfoil'] as int? ?? 0) == 1,
    promo: (r['promo'] as int? ?? 0) == 1,
    reprint: (r['reprint'] as int? ?? 0) == 1,
    reserved: (r['reserved'] as int? ?? 0) == 1,
    fullArt: (r['full_art'] as int? ?? 0) == 1,
    booster: (r['booster'] as int? ?? 0) == 1,
    edhrecRank: (r['edhrec_rank'] as num?)?.toInt(),
    releasedAt: _parseDate(r['released_at'] as String?),
    prices: _pricesFrom(r['prices_json']),
    imageUris: _imagesFromRow(r),
    faces: _facesFromRow(r),
    extras: _extrasFrom(r['extras_json']),
  );

  /// The set a stored row describes.
  static TcgSet setFromRow(CardGame game, Map<String, Object?> r) => TcgSet(
    game: game,
    id: r['id'] as String,
    code: r['code'] as String,
    name: r['name'] as String,
    setType: (r['set_type'] as String?) ?? 'unknown',
    releasedAt: _parseDate(r['released_at'] as String?),
    cardCount: (r['card_count'] as num?)?.toInt() ?? 0,
    printedSize: (r['printed_size'] as num?)?.toInt(),
    iconSvgUri: r['icon_svg_uri'] as String?,
    logoUri: r['logo_uri'] as String?,
    series: r['series'] as String?,
    digital: (r['digital'] as int? ?? 0) == 1,
    foilOnly: (r['foil_only'] as int? ?? 0) == 1,
    nonfoilOnly: (r['nonfoil_only'] as int? ?? 0) == 1,
    parentSetCode: r['parent_set_code'] as String?,
    blockCode: r['block_code'] as String?,
    block: r['block'] as String?,
    collectorNumberStart: (r['collector_number_start'] as num?)?.toInt(),
  );

  static TcgPrices _pricesFrom(Object? raw) {
    if (raw is! String || raw.isEmpty) return TcgPrices.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return TcgPrices.empty;
      return TcgPrices.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return TcgPrices.empty;
    }
  }

  static Map<String, Object?> _extrasFrom(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  static Map<String, String> _imagesFromRow(Map<String, Object?> r) {
    final out = <String, String>{};
    void put(String key, Object? v) {
      if (v is String && v.isNotEmpty) out[key] = v;
    }

    put('small', r['image_small']);
    put('normal', r['image_normal']);
    put('large', r['image_large']);
    put('art_crop', r['image_art_crop']);
    put('png', r['image_png']);
    return out;
  }

  static List<TcgCardFace> _facesFromRow(Map<String, Object?> r) {
    final back = <String, String>{};
    final bs = r['back_image_small'];
    final bn = r['back_image_normal'];
    if (bs is String && bs.isNotEmpty) back['small'] = bs;
    if (bn is String && bn.isNotEmpty) back['normal'] = bn;
    if (back.isEmpty) return const [];
    // The front face is reconstructed from the top-level images so that
    // imageUrl(face: 0) and imageUrl(face: 1) behave identically.
    return [
      TcgCardFace(
        name: r['name'] as String?,
        typeLine: r['type_line'] as String?,
        text: r['oracle_text'] as String?,
        cost: r['mana_cost'] as String?,
        imageUris: _imagesFromRow(r),
      ),
      TcgCardFace(imageUris: back),
    ];
  }

  static List<String> _split(Object? v) {
    final s = (v as String?) ?? '';
    if (s.isEmpty) return const [];
    return s.split(',').where((e) => e.isNotEmpty).toList();
  }

  static DateTime? _parseDate(String? s) =>
      s == null ? null : DateTime.tryParse(s);
}
