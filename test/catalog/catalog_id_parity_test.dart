// The server importer and the Dart providers must derive the same card rows.
//
//   flutter test test/catalog/catalog_id_parity_test.dart
//
// Design: docs/catalogue-server-side.md, sections 3, 7 and 8. This is the test
// the design calls the most valuable thing in the document, and the reason is
// that the failure it catches is silent. A card id is derived, not forwarded:
// the importer writes a row, the client writes a row for the same card from the
// same provider response, and if the two disagree about the id - or about the
// name, the oracle id, the rarity spelling, the collector sort key, the JSON in
// extras - then a collection row naming that card stops resolving. It does not
// raise. It renders as "--", for ever, for one collector, and nothing anywhere
// says why.
//
// One game per case, in the table below, and the same assertions applied to
// every case. Each case names a committed sample of real provider responses -
// cut by tool/catalog/make_lorcana_sample.py, make_pokemon_sample.py and
// make_yugioh_sample.py - drives the real provider client over it, and turns
// every TcgCard into the catalog_cards row a client would store.
// tool/catalog/test_id_parity.py runs each importer owner's own functions over
// the same samples and compares against the same committed file:
//
//   tool/catalog/catalog_id_vectors.json.gz
//
// Neither side is the authority. Both are asserted against that file, which was
// generated from the Dart and is reviewed as a diff, so a change in either
// language fails a test rather than moving the goalposts.
//
// Regenerate the vectors, and read the diff, with:
//
//   flutter test test/catalog/catalog_id_parity_test.dart \
//       --dart-define=UPDATE_ID_VECTORS=true
//
// The four games are here because they cover the shapes an id can take:
// Lorcana forwards the provider's own id, Pokemon forwards it while deriving
// the oracle id and the collector sort key, Yu-Gi-Oh! synthesises the id from a
// passcode, the app's own set code, the collector code and the rarity, and
// Gundam forwards an id whose provider prints several products under one
// collector number - so the id has to be the product and the number cannot be.
// Nothing here touches the network, and the Yu-Gi-Oh! case takes about half a
// minute because that client deliberately throttles itself to ten requests a
// second.

import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:arcanum/data/catalog/gundam_catalog.dart";
import "package:arcanum/data/catalog/lorcana_catalog.dart";
import "package:arcanum/data/catalog/pokemon_catalog.dart";
import "package:arcanum/data/catalog/swu_catalog.dart";
import "package:arcanum/data/catalog/ygo_catalog.dart";
import "package:arcanum/domain/models/tcg_card.dart";
import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";

const String _gundamSample = "tool/catalog/gundam_sample.json.gz";
const String _lorcanaSample = "tool/catalog/lorcana_sample.json.gz";
const String _pokemonSample = "tool/catalog/pokemon_sample.json.gz";
const String _yugiohSample = "tool/catalog/yugioh_sample.json.gz";
const String _swuSample = "tool/catalog/swu_sample.json.gz";
const String _vectorPath = "tool/catalog/catalog_id_vectors.json.gz";

/// Whether to rewrite the committed vectors instead of asserting them.
const bool _update = bool.fromEnvironment("UPDATE_ID_VECTORS");

/// What one game's sample produces: the stored rows, keyed by the column the
/// catalogue keys them by - the card id and the set code.
typedef _Sample = ({
  Map<String, Map<String, Object?>> cards,
  Map<String, Map<String, Object?>> sets,
});

/// Drives a real provider client over its committed sample.
typedef _Drive = Future<_Sample> Function(Map<String, dynamic> sample);

/// An assertion only one game's sample can make, run over the rows it drove.
typedef _Check = void Function(Map<String, dynamic> sample, _Sample rows);

/// One game's case: the committed responses, the client to run over them, and
/// what that sample has to prove.
class _GameCase {
  const _GameCase({
    required this.game,
    required this.sample,
    required this.drive,
    required this.checks,
  });

  final String game;
  final String sample;
  final _Drive drive;
  final List<_NamedCheck> checks;
}

class _NamedCheck {
  const _NamedCheck(this.name, this.run);

  final String name;
  final _Check run;
}

Map<String, dynamic> _readGzip(String path) {
  final File file = File(path);
  if (!file.existsSync()) {
    fail("$path is missing; see the header of this file for how to make it");
  }
  return jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())))
      as Map<String, dynamic>;
}

void _writeGzip(String path, Object? payload) {
  final List<int> raw = utf8.encode(jsonEncode(payload));
  // mtime 0, so regenerating an unchanged file leaves its bytes alone and a
  // diff means a real change.
  File(path).writeAsBytesSync(gzip.encode(raw), flush: true);
}

/// The catalog_cards columns for one card.
///
/// A transcription of the shared mapper in lib/data/db/catalog_row.dart, which
/// this test keeps its own copy of because it writes the SQLite-only price
/// columns too. What is being compared is the *stored row*
/// rather than the model, because a row is what reaches the database and what
/// the other language has to reproduce. Booleans stay booleans: the catalogue
/// keeps the honest type and the adapter converts them to the 0/1 the SQLite
/// mapper expects.
Map<String, Object?> rowOf(TcgCard c) => <String, Object?>{
  "id": c.id,
  "oracle_id": c.oracleId,
  "set_code": c.setCode,
  "set_name": c.setName,
  "name": c.name,
  "collector_number": c.collectorNumber,
  "collector_sort": c.collectorNumberSortKey,
  "rarity": c.rarity,
  "layout": c.layout,
  "type_line": c.typeLine,
  "oracle_text": c.oracleText,
  "mana_cost": c.manaCost,
  "cmc": c.cmc,
  "colors": c.colors.join(","),
  "color_identity": c.colorIdentity.join(","),
  "artist": c.artist,
  "flavor_text": c.flavorText,
  "image_small": c.imageUris["small"],
  "image_normal": c.imageUris["normal"],
  "image_large": c.imageUris["large"],
  "image_art_crop": c.imageUris["art_crop"],
  "image_png": c.imageUris["png"],
  "back_image_small": c.faces.length > 1 ? c.faces[1].imageUris["small"] : null,
  "back_image_normal":
      c.faces.length > 1 ? c.faces[1].imageUris["normal"] : null,
  "digital": c.digital,
  "promo": c.promo,
  "reprint": c.reprint,
  "reserved": c.reserved,
  "full_art": c.fullArt,
  "booster": c.booster,
  "foil": c.foil,
  "nonfoil": c.nonfoil,
  "edhrec_rank": c.edhrecRank,
  "released_at": c.releasedAt?.toIso8601String().split("T").first,
  "extras": c.extras.isEmpty ? null : c.extras,
};

/// The catalog_sets columns for one set.
///
/// card_count is what the provider publishes and is 0 where it publishes none:
/// Lorcast's set list carries no count at all. card_row_count is what the
/// import records after counting, so the two are different facts.
Map<String, Object?> setRowOf(TcgSet s) => <String, Object?>{
  "code": s.code,
  "id": s.id,
  "name": s.name,
  "set_type": s.setType,
  "released_at": s.releasedAt?.toIso8601String().split("T").first,
  "card_count": s.cardCount,
  "printed_size": s.printedSize,
  "icon_svg_uri": s.iconSvgUri,
  "logo_uri": s.logoUri,
  "series": s.series,
  "digital": s.digital,
  "foil_only": s.foilOnly,
  "nonfoil_only": s.nonfoilOnly,
  "parent_set_code": s.parentSetCode,
  "block_code": s.blockCode,
  "block": s.block,
  "collector_number_start": s.collectorNumberStart,
};

/// Structural equality over decoded JSON.
///
/// Written out rather than pulled from package:collection so this test depends
/// on nothing that is not already needed to run the client. Numbers compare
/// numerically, because JSON has one number type and the two languages may
/// read 3 as an int or as a double.
bool sameJson(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final Object? key in a.keys) {
      if (!b.containsKey(key)) return false;
      if (!sameJson(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

ResponseBody _json(Object? body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });

// --------------------------------------------------------------- the samples
//
// Each adapter serves one committed sample in place of the network. The sample
// is what the provider actually answered, so the catalogue under test is the
// real one rather than a convenient shape, and a request for something the
// sample does not hold is answered the way the provider answers it.

/// Serves the committed Lorcast sample.
///
/// A request for a set the sample does not hold is a 404, which is how Lorcast
/// answers an unknown code.
class _SampleLorcast implements HttpClientAdapter {
  _SampleLorcast(this.sets, this.byCode);

  /// The set objects as the sample holds them, unwrapped from the envelope
  /// Lorcast answers /sets with, and put back on the way out.
  final List<dynamic> sets;
  final Map<String, String> byCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.uri.path;
    if (path.endsWith("/sets")) {
      // Lorcast answers the set list inside a results envelope; the sample
      // stores the unwrapped list, so it is wrapped again here.
      return _json(<String, Object?>{"results": sets}, 200);
    }
    final RegExpMatch? match =
        RegExp(r"/sets/([^/]+)/cards$").firstMatch(path);
    final String? body = match == null ? null : byCode[match.group(1)];
    if (body == null) {
      return _json(<String, Object?>{"error": "Not found"}, 404);
    }
    return ResponseBody.fromString(body, 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// Serves the committed TCGdex sample.
///
/// TCGdex answers three things the client asks for: the set list, one set's
/// metadata with its card stubs, and one card's full detail. The card detail is
/// where the id the client stores comes from, so a card the sample does not
/// hold is a 404 and the client falls back to the stub - which is what happens
/// against the live provider too.
class _SampleTcgdex implements HttpClientAdapter {
  _SampleTcgdex(Map<String, dynamic> sample)
      : sets = sample["sets"] as List<dynamic>,
        details = <String, String>{
          for (final MapEntry<String, dynamic> entry
              in (sample["details"] as Map<String, dynamic>).entries)
            entry.key: jsonEncode(entry.value),
        },
        cards = <String, String>{
          for (final dynamic raw in sample["cards"] as List<dynamic>)
            (raw as Map<String, dynamic>)["id"] as String: jsonEncode(raw),
        };

  final List<dynamic> sets;
  final Map<String, String> details;
  final Map<String, String> cards;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // pathSegments, not path: an id may carry a percent-escaped collector
    // number ("exu-%3F") and the segment is the decoded form of it.
    final List<String> segments = options.uri.pathSegments;
    if (segments.isNotEmpty && segments.last == "sets") {
      return _json(sets, 200);
    }
    if (segments.length >= 2) {
      final String? body = segments[segments.length - 2] == "sets"
          ? details[segments.last]
          : segments[segments.length - 2] == "cards"
              ? cards[segments.last]
              : null;
      if (body != null) {
        return ResponseBody.fromString(
            body, 200, headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>[Headers.jsonContentType],
        });
      }
    }
    return _json(<String, Object?>{"status": 404, "message": "Not found"}, 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Serves the committed YGOPRODeck sample.
///
/// cardsets.php answers a bare array of every set; cardinfo.php answers an
/// envelope with "data", either for one set name or for one passcode. The
/// provider answers a query it cannot match with HTTP 400 and an error body
/// rather than a 404, so an unknown query is a 400 here too and the client
/// reads it as "no such card".
class _SampleYgo implements HttpClientAdapter {
  _SampleYgo(Map<String, dynamic> sample)
      : sets = sample["sets"] as List<dynamic>,
        byPasscode = <String, String>{
          for (final dynamic raw in sample["cards"] as List<dynamic>)
            (raw as Map<String, dynamic>)["id"].toString(): jsonEncode(raw),
        },
        bySetName = _ygoBySetName(sample["cards"] as List<dynamic>);

  final List<dynamic> sets;
  final Map<String, String> byPasscode;
  final Map<String, String> bySetName;

  static const Map<String, Object?> _noMatch = <String, Object?>{
    "error": "No card matching your query was found in the database.",
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.uri.path;
    if (path.endsWith("/cardsets.php")) {
      return _json(sets, 200);
    }
    if (!path.endsWith("/cardinfo.php")) {
      return _json(_noMatch, 400);
    }
    final Map<String, String> query = options.uri.queryParameters;
    final String? setName = query["cardset"];
    final String? id = query["id"];
    final String? body =
        setName != null ? bySetName[setName] : (id == null ? null : byPasscode[id.trim()]);
    if (body == null) {
      return _json(_noMatch, 400);
    }
    if (setName != null) {
      return ResponseBody.fromString(
          body, 200, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });
    }
    // The passcode query answers the card inside the provider's envelope, the
    // same object a cardset query would have carried.
    return _json(<String, Object?>{'data': <dynamic>[jsonDecode(body)]}, 200);
  }

  /// The cards the provider holds in each set, which is what a cardset query
  /// answers with: whole card objects, every printing included.
  static Map<String, String> _ygoBySetName(List<dynamic> cards) {
    final Map<String, List<dynamic>> grouped = <String, List<dynamic>>{};
    for (final dynamic raw in cards) {
      final Map<String, dynamic> card = raw as Map<String, dynamic>;
      final Set<String> names = <String>{
        for (final dynamic row
            in (card["card_sets"] as List<dynamic>?) ?? const <dynamic>[])
          ((row as Map<String, dynamic>)["set_name"] ?? "").toString(),
      };
      for (final String name in names) {
        if (name.isEmpty) continue;
        grouped.putIfAbsent(name, () => <dynamic>[]).add(card);
      }
    }
    return <String, String>{
      for (final MapEntry<String, List<dynamic>> entry in grouped.entries)
        entry.key: jsonEncode(<String, Object?>{"data": entry.value}),
    };
  }

  @override
  void close({bool force = false}) {}
}

/// Serves the committed gcgapi sample.
///
/// gcgapi answers three things the client asks for: the set list, one set's
/// products - paged, because the provider caps a page at 250 rows and reports
/// the cap in its own meta rather than refusing - and one product by its id. The
/// sample holds every product of the sets it takes whole, so a page is served by
/// filtering those products by set code, case-insensitively as the provider
/// does, and slicing them the way a filtered list is sliced. A product the
/// sample does not hold is a 404, which is how the provider answers an id it
/// does not publish.
class _SampleGcgapi implements HttpClientAdapter {
  _SampleGcgapi(Map<String, dynamic> sample)
      : sets = jsonEncode(sample["sets"]),
        byId = <String, String>{
          for (final dynamic raw in sample["cards"] as List<dynamic>)
            (raw as Map<String, dynamic>)["product_id"] as String: jsonEncode(raw),
        },
        bySet = _bySet(sample["cards"] as List<dynamic>);

  /// The whole set list, as the provider answers /sets with it.
  final String sets;
  final Map<String, String> byId;
  final Map<String, List<String>> bySet;

  /// The sample's products filed by the set the provider files them in, which is
  /// not always the set their printed number names.
  static Map<String, List<String>> _bySet(List<dynamic> cards) {
    final Map<String, List<String>> out = <String, List<String>>{};
    for (final dynamic raw in cards) {
      final Map<String, dynamic> card = raw as Map<String, dynamic>;
      final String code =
          (card["set_code"] ?? "").toString().trim().toLowerCase();
      if (code.isEmpty) continue;
      out.putIfAbsent(code, () => <String>[]).add(jsonEncode(card));
    }
    return out;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final List<String> segments = options.uri.pathSegments;
    if (segments.isNotEmpty && segments.last == "sets") {
      return ResponseBody.fromString(
          '{"data":$sets}', 200,
          headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });
    }
    if (segments.length >= 2 && segments[segments.length - 2] == "cards") {
      final String? body = byId[segments.last];
      if (body == null) {
        return _json(<String, Object?>{"detail": "Not found"}, 404);
      }
      return ResponseBody.fromString(
          '{"data":$body}', 200,
          headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });
    }
    if (segments.isNotEmpty && segments.last == "cards") {
      final Map<String, String> query = options.uri.queryParameters;
      final String code = (query["set_code"] ?? "").toLowerCase();
      final List<String> all = bySet[code] ?? const <String>[];
      final int limit = int.tryParse(query["limit"] ?? "") ?? 100;
      final int offset = int.tryParse(query["offset"] ?? "") ?? 0;
      final List<String> page = all.skip(offset).take(limit).toList();
      return _json(<String, Object?>{
        "data": <dynamic>[for (final String row in page) jsonDecode(row)],
        "_meta": <String, Object?>{
          "total": all.length,
          "limit": limit,
          "offset": offset,
          "count": page.length,
        },
      }, 200);
    }
    return _json(<String, Object?>{"data": <dynamic>[], "_meta": <String, Object?>{}}, 200);
  }

  @override
  void close({bool force = false}) {}
}

// ------------------------------------------------------------ the id parity

/// Every card row the Lorcana sample produces, keyed by the id it was stored
/// under, and every set row.
Future<_Sample> _lorcanaRows(Map<String, dynamic> sample) async {
  final List<dynamic> cards = sample["cards"] as List<dynamic>;
  final Map<String, String> byCode = <String, String>{};
  for (final dynamic raw in cards) {
    final Map<String, dynamic> card = raw as Map<String, dynamic>;
    final Map<String, dynamic> set = card["set"] as Map<String, dynamic>;
    final String code = set["code"] as String;
    byCode[code] = jsonEncode(
        <Map<String, dynamic>>[for (final dynamic c in cards)
          if (((c as Map<String, dynamic>)["set"]
                  as Map<String, dynamic>)["code"] ==
              code)
            c]);
  }

  final Dio dio = Dio(BaseOptions(baseUrl: "https://api.lorcast.com/v0"));
  dio.httpClientAdapter =
      _SampleLorcast(sample["sets"] as List<dynamic>, byCode);
  final LorcanaCatalog catalog = LorcanaCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> setRows =
      <String, Map<String, Object?>>{
    for (final TcgSet set in sets) set.code: setRowOf(set),
  };
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    for (final TcgCard card in await catalog.fetchCardsInSet(set.code)) {
      rows[card.id] = rowOf(card);
    }
  }
  return (cards: rows, sets: setRows);
}

/// Every card row the Pokemon sample produces, keyed by the id it was stored
/// under, and every set row.
///
/// A TCGdex set response carries only names and ids, so the client downloads
/// each card of the sets the sample cuts whole. The rest of the sample is cards
/// the provider files in a set the sample does not cut whole, and those are
/// reached the way the app reaches a card it already holds an id for: by the id
/// itself.
Future<_Sample> _pokemonRows(Map<String, dynamic> sample) async {
  final Dio dio = Dio(BaseOptions(baseUrl: "https://api.tcgdex.net/v2/en"));
  dio.httpClientAdapter = _SampleTcgdex(sample);
  final PokemonCatalog catalog = PokemonCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> setRows =
      <String, Map<String, Object?>>{
    for (final TcgSet set in sets) set.code: setRowOf(set),
  };

  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    for (final TcgCard card in await catalog.fetchCardsInSet(set.code)) {
      rows[card.id] = rowOf(card);
    }
  }
  for (final dynamic raw in sample["cards"] as List<dynamic>) {
    final String id = (raw as Map<String, dynamic>)["id"] as String;
    if (rows.containsKey(id)) continue;
    final TcgCard? card = await catalog.fetchCardById(id);
    if (card == null) {
      fail("the sample holds an id the client could not read back");
    }
    rows[card.id] = rowOf(card);
  }
  return (cards: rows, sets: setRows);
}

/// Every card row the Yu-Gi-Oh! sample produces, keyed by the id it was stored
/// under, and every set row.
///
/// Two paths, because the client derives a printing's set code differently on
/// each and they must not disagree. A set download places a printing in the set
/// being downloaded; a card reached by its passcode places each printing in the
/// set its own name resolves to. Where both paths produce the same id, the rows
/// are asserted identical rather than one silently overwriting the other.
Future<_Sample> _ygoRows(Map<String, dynamic> sample) async {
  final Dio dio = Dio(BaseOptions(baseUrl: "https://db.ygoprodeck.com/api/v7"));
  dio.httpClientAdapter = _SampleYgo(sample);
  final YgoCatalog catalog = YgoCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> setRows =
      <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    expect(setRows.containsKey(set.code), isFalse,
        reason: "two sets were assigned the same code");
    setRows[set.code] = setRowOf(set);
  }

  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  int metTwice = 0;
  void add(TcgCard card) {
    final Map<String, Object?> row = rowOf(card);
    final Map<String, Object?>? seen = rows[card.id];
    if (seen != null) {
      metTwice++;
      expect(sameJson(seen, row), isTrue,
          reason: "one id is derived differently by the two paths that "
              "reach it: ${card.id}");
      return;
    }
    rows[card.id] = row;
  }

  for (final dynamic name in sample["sampled_sets"] as List<dynamic>) {
    TcgSet? wanted;
    for (final TcgSet set in sets) {
      if (set.name == name) wanted = set;
    }
    if (wanted == null) {
      fail("the sample names a set the client did not list");
    }
    for (final TcgCard card in await catalog.fetchCardsInSet(wanted.code)) {
      add(card);
    }
  }

  for (final dynamic raw in sample["cards"] as List<dynamic>) {
    final String passcode = (raw as Map<String, dynamic>)["id"].toString();
    for (final TcgCard card in await catalog.fetchPrintingsOf(passcode)) {
      add(card);
    }
  }
  // Without this the agreement above would be vacuous: two paths that never met
  // on the same id cannot disagree about one.
  expect(metTwice, greaterThan(0),
      reason: "no id was derived by both paths, so their agreement is untested");
  return (cards: rows, sets: setRows);
}

/// Every card row the Gundam sample produces, keyed by the id it was stored
/// under, and every set row.
///
/// The sample cuts seven sets whole and lists all 28, so the rows are the ones
/// a client derives by downloading those seven sets. Every sampled product is
/// then reached a second time the way the app reaches a card it already holds an
/// id for, and the two rows are asserted identical rather than one of them being
/// chosen: Gundam is the game where the two paths could have differed - the
/// client takes a set download's code from the set it was asked for and a by-id
/// row's code from the payload's own set_code - and did not, because the payload
/// names the set the product is filed under either way. A change that made them
/// disagree fails here instead of quietly moving which row the committed vectors
/// hold.
Future<_Sample> _gundamRows(Map<String, dynamic> sample) async {
  final Dio dio = Dio(BaseOptions(baseUrl: "https://api.gcgapi.com/v1"));
  dio.httpClientAdapter = _SampleGcgapi(sample);
  final GundamCatalog catalog = GundamCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> setRows =
      <String, Map<String, Object?>>{
    for (final TcgSet set in sets) set.code: setRowOf(set),
  };

  final Set<String> whole = <String>{
    for (final dynamic code in sample["sampled_sets"] as List<dynamic>)
      code.toString().toLowerCase(),
  };
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    if (!whole.contains(set.code)) continue;
    for (final TcgCard card in await catalog.fetchCardsInSet(set.code)) {
      rows[card.id] = rowOf(card);
    }
  }

  for (final dynamic raw in sample["cards"] as List<dynamic>) {
    final String id = (raw as Map<String, dynamic>)["product_id"] as String;
    final TcgCard? byId = await catalog.fetchCardById(id);
    if (byId == null) {
      fail("the sample holds an id the client could not read back");
    }
    final Map<String, Object?>? row = rows[id];
    if (row == null) {
      fail("the sample holds a product no set download produced: $id");
    }
    expect(sameJson(row, rowOf(byId)), isTrue,
        reason: "the set download and the by-id path derive different rows for "
            "$id");
  }
  return (cards: rows, sets: setRows);
}


/// The card types that are not cards, spelled out because the catalogue keeps
/// its own copy private (SwuCatalog._tokens).
const Set<String> _tokens = <String>{
  "Token Upgrade",
  "Token Unit",
  "Credit Token",
  "Force Token",
};

/// Every sampled record that is a token, by its cardUid.
Set<String> _sampleTokens(Map<String, dynamic> sample) => <String>{
  for (final dynamic raw in sample["cards"] as List<dynamic>)
    if (_tokens.contains((_SampleSwu._relation(
                _SampleSwu._attributes(raw as Map<String, dynamic>)!,
                "type")?["name"] ??
            "")
        .toString()))
      (_SampleSwu._attributes(raw)!["cardUid"] ?? "").toString(),
};

/// Serves the committed Star Wars: Unlimited sample in place of the network.
///
/// Two routes and two shapes: the set list answers whole, and the card list
/// answers a filter - expansion code, the base-printings filter the counts are
/// read with, a token exclusion, one id, or a batch of them - sliced the way the
/// source slices a page. The records are Strapi envelopes, so a relation is
/// `{data: {id, attributes}}` and a list of them is `{data: [...]}`, which is what
/// the client unwraps and what this has to read the same way.
class _SampleSwu implements HttpClientAdapter {
  _SampleSwu(Map<String, dynamic> sample)
    : sets = (sample["sets"] as List<dynamic>).cast<Map<String, dynamic>>(),
      cards = (sample["cards"] as List<dynamic>).cast<Map<String, dynamic>>();

  final List<Map<String, dynamic>> sets;
  final List<Map<String, dynamic>> cards;

  static Map<String, dynamic>? _attributes(Map<String, dynamic> record) {
    final Object? inner = record["attributes"];
    return inner is Map ? inner.cast<String, dynamic>() : null;
  }

  static Map<String, dynamic>? _relation(
      Map<String, dynamic> attributes, String key) {
    final Object? raw = attributes[key];
    if (raw is! Map) return null;
    final Object? data = raw["data"];
    if (data is! Map) return null;
    final Object? inner = data["attributes"];
    return inner is Map ? inner.cast<String, dynamic>() : null;
  }


  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.uri.path;
    final Map<String, String> params = options.uri.queryParameters;
    if (path.endsWith("card-expansions")) {
      return _body(jsonEncode(<String, Object?>{
        "data": sets,
        "meta": <String, Object?>{
          "pagination": <String, Object?>{"total": sets.length},
        },
      }));
    }
    if (!path.endsWith("card-list")) {
      return _body('{"data":null,"error":{"status":404}}', 404);
    }

    List<Map<String, dynamic>> rows = List<Map<String, dynamic>>.of(cards);
    final String? code = params["filters[expansion][code][\$eq]"];
    if (code != null) {
      rows = rows
          .where((Map<String, dynamic> row) =>
              _relation(_attributes(row)!, "expansion")?["code"] == code)
          .toList();
    }
    if (params["filters[variantOf][\$null]"] == "true") {
      rows = rows
          .where((Map<String, dynamic> row) =>
              _relation(_attributes(row)!, "variantOf") == null)
          .toList();
    }
    for (
      var i = 0;
      params.containsKey("filters[type][name][\$notIn][$i]");
      i++
    ) {
      final String excluded = params["filters[type][name][\$notIn][$i]"]!;
      rows = rows
          .where((Map<String, dynamic> row) =>
              _relation(_attributes(row)!, "type")?["name"] != excluded)
          .toList();
    }
    final String? uid = params["filters[cardUid][\$eq]"];
    if (uid != null) {
      rows = rows
          .where((Map<String, dynamic> row) =>
              _attributes(row)!["cardUid"].toString() == uid)
          .toList();
    }
    final List<String> wanted = <String>[
      for (var i = 0; params.containsKey("filters[cardUid][\$in][$i]"); i++)
        params["filters[cardUid][\$in][$i]"]!,
    ];
    if (wanted.isNotEmpty) {
      rows = rows
          .where((Map<String, dynamic> row) =>
              wanted.contains(_attributes(row)!["cardUid"].toString()))
          .toList();
    }

    final int pageSize =
        int.tryParse(params["pagination[pageSize]"] ?? "") ?? 250;
    final int page = int.tryParse(params["pagination[page]"] ?? "") ?? 1;
    final List<Map<String, dynamic>> slice = rows
        .skip((page - 1) * pageSize)
        .take(pageSize)
        .toList();
    return _body(jsonEncode(<String, Object?>{
      "data": slice,
      "meta": <String, Object?>{
        "pagination": <String, Object?>{
          "total": rows.length,
          "pageSize": pageSize,
          "page": page,
        },
      },
    }));
  }

  static ResponseBody _body(String body, [int status = 200]) =>
      ResponseBody.fromString(body, status, headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}

/// Every row the two languages must agree on for Star Wars: Unlimited.
///
/// The client lists every set - which is one request for the list and one count
/// request per set, both answered from the sample - then downloads the sets the
/// sample cuts whole, then reaches every sampled record a second time by its own
/// id. The two paths are asserted identical rather than one being chosen: this is
/// the game where they could have differed, because a treatment takes its
/// collector number and its oracle id from the base card it points at, and a
/// by-id read has no set context to fall back on.
Future<_Sample> _swuRows(Map<String, dynamic> sample) async {
  final Dio dio =
      Dio(BaseOptions(baseUrl: "https://admin.starwarsunlimited.com/api/"));
  dio.httpClientAdapter = _SampleSwu(sample);
  final SwuCatalog catalog = SwuCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> setRows =
      <String, Map<String, Object?>>{
    for (final TcgSet set in sets) set.code: setRowOf(set),
  };

  final Set<String> whole = <String>{
    for (final dynamic code in sample["sampled_sets"] as List<dynamic>)
      code.toString().toLowerCase(),
  };
  final Map<String, Map<String, Object?>> rows =
      <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    if (!whole.contains(set.code)) continue;
    for (final TcgCard card in await catalog.fetchCardsInSet(set.code)) {
      rows[card.id] = rowOf(card);
    }
  }

  final Set<String> tokens = _sampleTokens(sample);
  for (final dynamic raw in sample["cards"] as List<dynamic>) {
    final Map<String, dynamic> attributes =
        _SampleSwu._attributes(raw as Map<String, dynamic>)!;
    final String id = (attributes["cardUid"] ?? "").toString();
    // A token is not a card and the catalogue drops it, so there is no row for
    // either language to agree about and nothing to read back.
    if (tokens.contains(id)) continue;
    final TcgCard? byId = await catalog.fetchCardById(id);
    if (byId == null) {
      fail("the sample holds an id the client could not read back: $id");
    }
    final Map<String, Object?>? row = rows[id];
    if (row == null) {
      fail("the sample holds a record no set download produced: $id");
    }
    expect(sameJson(row, rowOf(byId)), isTrue,
        reason:
            "the set download and the by-id path derive different rows for $id");
  }
  return (cards: rows, sets: setRows);
}

// ----------------------------------------------------------- the assertions

/// The provider ids a sample publishes under one key.
Set<String> _providerIds(Map<String, dynamic> sample, String key) => <String>{
  for (final dynamic raw in sample[key] as List<dynamic>)
    ((raw as Map<String, dynamic>)["id"] ?? "").toString(),
};

/// The assertions every game is held to, plus the ones its own sample can make.
final List<_GameCase> _games = <_GameCase>[
  _GameCase(
    game: "lorcana",
    sample: _lorcanaSample,
    drive: _lorcanaRows,
    checks: <_NamedCheck>[
      _NamedCheck(
          "is the size the design asks for and keeps the awkward shapes",
          (Map<String, dynamic> sample, _Sample rows) {
        expect(rows.cards.length, greaterThan(300),
            reason: "the design asks for a sample of a few hundred cards");
        expect(rows.sets.length, 24);

        final List<dynamic> cards = sample["cards"] as List<dynamic>;
        bool anyPromoArt = false;
        bool anyQuoted = false;
        bool anyOddNumber = false;
        int multiInk = 0;
        int singleInkOnly = 0;
        for (final dynamic raw in cards) {
          final Map<String, dynamic> c = raw as Map<String, dynamic>;
          if (c["tcgplayer_id"] == null) anyPromoArt = true;
          if ((c["version"]?.toString() ?? "")
              .startsWith(String.fromCharCode(34))) {
            anyQuoted = true;
          }
          if (!RegExp(r"^[0-9]+$")
              .hasMatch(c["collector_number"]?.toString() ?? "")) {
            anyOddNumber = true;
          }
          final List<dynamic> inks =
              (c["inks"] as List<dynamic>?) ?? const <dynamic>[];
          if (inks.length > 1) multiInk++;
          if (inks.isEmpty && c["ink"] != null) singleInkOnly++;
        }
        // Each of these is a place the derivation branches, and a sample that
        // lost one would keep passing while covering less.
        expect(anyPromoArt, isTrue,
            reason: "no card without a TCGplayer product");
        expect(anyQuoted, isTrue, reason: "no quoted subtitle");
        expect(anyOddNumber, isTrue,
            reason: "no non-integer collector number");
        expect(multiInk, greaterThan(0), reason: "no two-ink card");
        // The branch where only the singular ink shorthand is published, which
        // is the one place the colours of a card come from somewhere else.
        expect(singleInkOnly, greaterThan(0),
            reason: "no card carrying only the singular ink");
      }),
      _NamedCheck("every id is the provider owner's own id, verbatim",
          (Map<String, dynamic> sample, _Sample rows) {
        // Lorcana is the cheap pilot partly because its ids are forwarded
        // rather than synthesised - no passcode:set:printing:rarity to
        // reconstruct. The test still pins it, because "forwarded verbatim" is
        // exactly the kind of claim that quietly stops being true.
        final Set<String> providerIds = _providerIds(sample, "cards");
        expect(rows.cards.keys.toSet().difference(providerIds), isEmpty);
        expect(rows.cards.length, providerIds.length);
      }),
      _NamedCheck("stored set codes are lower case and unique",
          (Map<String, dynamic> sample, _Sample rows) {
        // The catalogue keys a set by (game, code) with the code folded to
        // lower case, and the provider addresses it case-sensitively:
        // /sets/P1/cards answers and /sets/p1/cards is a 404. Both spellings
        // are real, and only one of them is stored.
        for (final String code in rows.sets.keys) {
          expect(code, code.toLowerCase());
        }
        expect(rows.sets.length, 24);
      }),
    ],
  ),
  _GameCase(
    game: "pokemon",
    sample: _pokemonSample,
    drive: _pokemonRows,
    checks: <_NamedCheck>[
      _NamedCheck("every id is the provider owner's own id, verbatim",
          (Map<String, dynamic> sample, _Sample rows) {
        // TCGdex addresses a card as "<set id>-<local id>" and the client
        // stores exactly that, so this is the claim the importer has to make
        // too: nothing here is synthesised, and the id the client stores is the
        // one the provider's own card response carries. What is derived for
        // this game is the oracle id and the collector sort key beside it.
        final Set<String> providerIds = _providerIds(sample, "cards");
        expect(rows.cards.keys.toSet().difference(providerIds), isEmpty);
        expect(rows.cards.length, providerIds.length);
      }),
      _NamedCheck("keeps the collector numbers the sort key has to branch on",
          (Map<String, dynamic> sample, _Sample rows) {
        // TcgCard.collectorNumberSortKey reads a leading non-digit prefix and
        // sorts prefixed numbers after plain ones, grouped by that prefix. A
        // sample of plain integers would pass while proving nothing about it.
        final Set<String> numbers = <String>{
          for (final Map<String, Object?> row in rows.cards.values)
            (row["collector_number"] ?? "").toString(),
        };
        bool hasPrefix(String prefix) => numbers.any((String n) =>
            n.startsWith(prefix) && n.length > prefix.length);
        expect(
            numbers
                .where((String n) => RegExp(r"^[0-9]+$").hasMatch(n))
                .length,
            greaterThan(50),
            reason: "too few plain integer collector numbers");
        expect(hasPrefix("TG"), isTrue,
            reason: "no TG01-shaped collector number");
        expect(hasPrefix("SV"), isTrue,
            reason: "no SV001-shaped collector number");
        expect(
            numbers
                .where((String n) => !RegExp(r"^[A-Za-z]*[0-9]+$").hasMatch(n))
                .length,
            greaterThan(0),
            reason: "no collector number that is not letters and digits");
      }),
      _NamedCheck("every stored set row is one the sample lists",
          (Map<String, dynamic> sample, _Sample rows) {
        // The sample cuts five sets whole and reaches the rest of its cards by
        // id, so a card row may name a set the sample does not hold - but every
        // set row has to be one the provider's own list published.
        final Set<String> listed = <String>{
          for (final dynamic raw in sample["sets"] as List<dynamic>)
            ((raw as Map<String, dynamic>)["id"] ?? "").toString(),
        };
        expect(rows.sets.keys.toSet(), listed);
      }),
    ],
  ),
  _GameCase(
    game: "swu",
    sample: _swuSample,
    drive: _swuRows,
    checks: <_NamedCheck>[
      _NamedCheck("every id is the publisher's cardUid, verbatim",
          (Map<String, dynamic> sample, _Sample rows) {
        // The publisher names a card three ways and only one of them is an id.
        // cardUid is unique over the whole game; cardId is null on most records
        // and names a related card where it is set, and validationId repeats.
        // This asserts the one the catalogue stores, over every record the
        // sample holds that is a card at all.
        final Set<String> providerIds = <String>{
          for (final dynamic raw in sample["cards"] as List<dynamic>)
            (_SampleSwu._attributes(raw as Map<String, dynamic>)!["cardUid"] ??
                    "")
                .toString(),
        };
        expect(rows.cards.keys.toSet().difference(providerIds), isEmpty);
        expect(
            rows.cards.length,
            providerIds.length - _sampleTokens(sample).length,
            reason: "every record that is a card is stored, and no token is");
      }),
      _NamedCheck("gives a treatment its base card's number, and keeps it apart",
          (Map<String, dynamic> sample, _Sample rows) {
        // A hyperspace Luke carries cardNumber 1 where Luke carries 5, because a
        // treatment's own number counts its run rather than the card. Both
        // languages take the number from the base record the treatment points at,
        // which is the number printed on the card and the number the app's binder
        // slots group by - while the id stays the treatment's own, so two
        // holdings of one card do not collapse into one row.
        int treatments = 0;
        for (final dynamic raw in sample["cards"] as List<dynamic>) {
          final Map<String, dynamic> attributes =
              _SampleSwu._attributes(raw as Map<String, dynamic>)!;
          final Map<String, dynamic>? base =
              _SampleSwu._relation(attributes, "variantOf");
          if (base == null) continue;
          final Map<String, Object?>? row = rows.cards[
              (attributes["cardUid"] ?? "").toString()];
          if (row == null) continue;
          treatments++;
          final int printed = (base["cardNumber"] as num).toInt();
          expect(row["collector_number"], printed.toString().padLeft(3, "0"),
              reason: "a treatment took its own run number rather than the "
                  "number printed on the card");
          expect(row["oracle_id"], (base["cardUid"] ?? "").toString(),
              reason: "the treatments of one card do not group with it");
          expect(row["id"], isNot((base["cardUid"] ?? "").toString()),
              reason: "a treatment was stored under its base card's id");
        }
        expect(treatments, greaterThan(50),
            reason: "the sample holds too few treatments for this to prove "
                "anything");
      }),
      _NamedCheck("draws a leader from the portrait face of a landscape card",
          (Map<String, dynamic> sample, _Sample rows) {
        // A leader's own art is 418x300 and the app draws every card at the
        // game's portrait ratio, so the stored picture is the deployed unit on
        // the other face of the same card. A row carrying the landscape URL
        // would be a tile with a third of the card cut off each side.
        int leaders = 0;
        for (final dynamic raw in sample["cards"] as List<dynamic>) {
          final Map<String, dynamic> attributes =
              _SampleSwu._attributes(raw as Map<String, dynamic>)!;
          if (attributes["artFrontHorizontal"] != true) continue;
          final Map<String, Object?>? row = rows.cards[
              (attributes["cardUid"] ?? "").toString()];
          if (row == null) continue;
          final Object? back =
              _SampleSwu._relation(attributes, "artBack")?["url"];
          if (back == null) continue;
          leaders++;
          expect(row["image_normal"], back.toString());
        }
        expect(leaders, greaterThan(5),
            reason: "the sample holds too few leaders for this to prove "
                "anything");
      }),
      _NamedCheck("counts base printings, and holds a set past the page cap",
          (Map<String, dynamic> sample, _Sample rows) {
        // The set list carries no card count at all, so both languages count a
        // set with a one-record read whose envelope carries the total, over the
        // base printings that are not tokens - which is the number printed on
        // the cards. And a set bigger than the page cap is the only thing that
        // proves the two languages page a set the same way.
        final Map<String, int> bases = <String, int>{};
        for (final dynamic raw in sample["cards"] as List<dynamic>) {
          final Map<String, dynamic> attributes =
              _SampleSwu._attributes(raw as Map<String, dynamic>)!;
          if (_tokens.contains(
              (_SampleSwu._relation(attributes, "type")?["name"] ?? "")
                  .toString())) {
            continue;
          }
          if (_SampleSwu._relation(attributes, "variantOf") != null) continue;
          final String code =
              (_SampleSwu._relation(attributes, "expansion")?["code"] ?? "")
                  .toString();
          bases[code] = (bases[code] ?? 0) + 1;
        }
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.sets.entries) {
          final String providerCode = (entry.value["id"] ?? "").toString();
          expect(entry.value["card_count"], bases[providerCode] ?? 0,
              reason: "set ${entry.key} is not counted over its base "
                  "printings");
        }
        final String biggest = bases.entries
            .reduce((MapEntry<String, int> a, MapEntry<String, int> b) =>
                a.value >= b.value ? a : b)
            .key;
        final int stored = rows.cards.values
            .where((Map<String, Object?> row) =>
                row["set_code"] ==
                    biggest.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), ""))
            .length;
        expect(stored, greaterThan(250),
            reason: "no sampled set is larger than the page cap, so the paging "
                "is untested");
      }),
    ],
  ),
  _GameCase(
    game: "yugioh",
    sample: _yugiohSample,
    drive: _ygoRows,
    checks: <_NamedCheck>[
      _NamedCheck("every id is synthesised, not a forwarded provider id",
          (Map<String, dynamic> sample, _Sample rows) {
        // The one game here whose id is built: "<passcode>:<set code>:<printing
        // code slug>:<rarity slug>", with the passcode first so the app can
        // read it back with a split. A bare passcode is the branch for a card
        // the provider gives no printing rows at all.
        final Set<String> passcodes = _providerIds(sample, "cards");
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.cards.entries) {
          final List<String> parts = entry.key.split(":");
          expect(int.tryParse(parts.first), isNotNull,
              reason: "a card id does not begin with a passcode: ${entry.key}");
          if (parts.length == 1) {
            expect(passcodes.contains(parts.first), isTrue,
                reason: "a bare id is not a passcode the provider "
                    "publishes: ${entry.key}");
          } else {
            expect(parts.length, 4,
                reason: "a card id is not four fields: ${entry.key}");
            expect(parts[3].trim().isEmpty, isFalse,
                reason: "a card id carries no rarity field: ${entry.key}");
          }
        }
        final int bare =
            rows.cards.keys.where((String id) => !id.contains(":")).length;
        expect(bare, greaterThan(0),
            reason: "no card the provider gives no printings at all");
        expect(
            rows.cards.keys.where((String id) => id.contains(":")).length,
            greaterThan(100),
            reason: "almost nothing in the sample was synthesised");
      }),
      _NamedCheck("holds a set whose code the collision rule suffixed",
          (Map<String, dynamic> sample, _Sample rows) {
        // Konami publishes 1,035 sets under 646 codes and the client
        // disambiguates the repeats with a numeric suffix. That rule is part of
        // every printing id, so a sample whose sets all kept their own code
        // would leave the likeliest way for the two languages to disagree
        // untested.
        final Map<String, String> published = <String, String>{};
        for (final dynamic raw in sample["sets"] as List<dynamic>) {
          final Map<String, dynamic> set = raw as Map<String, dynamic>;
          published[(set["set_name"] ?? "").toString()] =
              (set["set_code"] ?? "").toString();
        }
        final List<String> suffixed = <String>[
          for (final MapEntry<String, Map<String, Object?>> entry
              in rows.sets.entries)
            if (published[entry.value["name"]] != null &&
                published[entry.value["name"]]!.toLowerCase() != entry.key)
              entry.key,
        ];
        expect(suffixed, isNotEmpty,
            reason: "no set code was suffixed, so the collision rule is "
                "untested by this sample");
        expect(rows.sets.length, 1035, reason: "the set list was cut");
      }),
      _NamedCheck("every stored set code carries a name and nothing is empty",
          (Map<String, dynamic> sample, _Sample rows) {
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.sets.entries) {
          expect(entry.key.trim().isEmpty, isFalse);
          expect((entry.value["name"] ?? "").toString().trim().isEmpty, isFalse,
              reason: "set ${entry.key} carries no name");
        }
      }),
    ],
  ),
  _GameCase(
    game: "gundam",
    sample: _gundamSample,
    drive: _gundamRows,
    checks: <_NamedCheck>[
      _NamedCheck("every id is the provider's own product id, verbatim",
          (Map<String, dynamic> sample, _Sample rows) {
        // gcgapi publishes one id per product and the client stores exactly it:
        // nothing is derived, appended or re-cased. This is also the claim the
        // game needs, because the *printed number* cannot be the id - see the
        // next check for the cluster that says so.
        final Set<String> providerIds = <String>{
          for (final dynamic raw in sample["cards"] as List<dynamic>)
            ((raw as Map<String, dynamic>)["product_id"] ?? "").toString(),
        };
        expect(rows.cards.keys.toSet().difference(providerIds), isEmpty);
        expect(rows.cards.length, providerIds.length);
      }),
      _NamedCheck("keeps the art variants of one card apart",
          (Map<String, dynamic> sample, _Sample rows) {
        // A Gundam alternate art is a product of its own with the same number
        // printed on it - GD01-005 has four - so an id derived from the printed
        // number would collapse several holdings into one and the collector
        // would see one row where they own two. The sample has to hold such a
        // cluster (it holds 202 products sharing a number) and the rows have to
        // keep them apart, which is what makes the id a product and not a
        // number.
        final Map<String, List<String>> byNumber = <String, List<String>>{};
        for (final dynamic raw in sample["cards"] as List<dynamic>) {
          final Map<String, dynamic> card = raw as Map<String, dynamic>;
          byNumber
              .putIfAbsent(
                  (card["card_number"] ?? "").toString(), () => <String>[])
              .add((card["product_id"] ?? "").toString());
        }
        final List<String> clusters = <String>[
          for (final MapEntry<String, List<String>> entry in byNumber.entries)
            if (entry.value.length > 1) entry.key,
        ];
        expect(clusters, isNotEmpty,
            reason: "the sample holds no card number printed on more than one "
                "product, so an id derived from the number would pass");
        final int clustered = clusters.fold<int>(
            0, (int sum, String number) => sum + byNumber[number]!.length);
        final int stored = <String>{
          for (final String number in clusters)
            for (final String id in byNumber[number]!) id,
        }.where(rows.cards.containsKey).length;
        expect(stored, clustered,
            reason: "the number and the id are not one-to-one over the sample");
        final Set<String> numbers = <String>{
          for (final Map<String, Object?> row in rows.cards.values)
            (row["collector_number"] ?? "").toString(),
        };
        expect(numbers.length, lessThan(rows.cards.length),
            reason: "no collector number repeats, so this sample cannot show "
                "what an id built from the number would do");
      }),
      _NamedCheck("every stored set code is the provider's code folded",
          (Map<String, dynamic> sample, _Sample rows) {
        // The provider addresses a set by GD01 and every layer of the app stores
        // and compares it as gd01, so the code and the id genuinely differ here
        // and both are kept: the folded code in the row the app reads, the
        // provider's spelling in the set's own id.
        final Set<String> listed = <String>{
          for (final dynamic raw in sample["sets"] as List<dynamic>)
            ((raw as Map<String, dynamic>)["set_code"] ?? "").toString(),
        };
        expect(rows.sets.keys.toSet(), <String>{
          for (final String code in listed)
            code.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), ""),
        });
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.sets.entries) {
          expect(entry.key, entry.key.toLowerCase());
          expect(listed, contains(entry.value["id"]));
          expect((entry.value["card_count"] as num?)?.toInt(), greaterThan(0),
              reason: "set ${entry.key} carries no card count, so the Sets tab "
                  "cannot say how large it is before it is opened");
        }
      }),
      _NamedCheck("holds a set larger than the provider's page cap",
          (Map<String, dynamic> sample, _Sample rows) {
        // gcgapi caps a page at 250 rows and reports the cap rather than
        // refusing, so a set bigger than that is only whole if both languages
        // page it the same way. A sample in which every set fitted in one page
        // would leave the paging untested.
        final List<String> paging = <String>[
          for (final dynamic raw in sample["sets"] as List<dynamic>)
            if ((((raw as Map<String, dynamic>)["card_count"] as num?)
                        ?.toInt() ??
                    0) >
                250)
              (raw["set_code"] ?? "").toString(),
        ];
        expect(paging, isNotEmpty,
            reason: "no sampled set is larger than the provider's page cap");
        for (final String code in paging) {
          final String folded =
              code.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]"), "");
          final int expected = (sample["cards"] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .where((Map<String, dynamic> card) =>
                  (card["set_code"] ?? "").toString().toLowerCase() == folded)
              .length;
          final int stored = rows.cards.values
              .where((Map<String, Object?> row) => row["set_code"] == folded)
              .length;
          expect(stored, expected,
              reason: "set $code is paged and the pages did not add up");
        }
      }),
    ],
  ),
];

void main() {
  final Map<String, Map<String, dynamic>> samples =
      <String, Map<String, dynamic>>{};
  final Map<String, _Sample> driven = <String, _Sample>{};

  setUpAll(() async {
    for (final _GameCase game in _games) {
      samples[game.game] = _readGzip(game.sample);
      driven[game.game] = await game.drive(samples[game.game]!);
    }
    if (_update) {
      _writeGzip(_vectorPath, <String, Object?>{
        "generated_by": "test/catalog/catalog_id_parity_test.dart",
        "why": "the derived rows both languages must agree on, one block per game",
        "games": <Map<String, Object?>>[
          for (final _GameCase game in _games)
            <String, Object?>{
              "game": game.game,
              "sample": game.sample,
              "cards": _sortedRows(driven[game.game]!.cards, "id"),
              "sets": _sortedRows(driven[game.game]!.sets, "code"),
            },
        ],
      });
    }
  });

  for (final _GameCase game in _games) {
    group("${game.game}: the id parity with the importer", () {
      test("cards: the committed vectors are current", () {
        if (_update) return;
        final Map<String, dynamic> committed = _readGzip(_vectorPath);
        final Map<String, Object?> byId = <String, Object?>{
          for (final dynamic raw in _cardsOf(committed, game.game))
            (raw as Map<String, dynamic>)["id"] as String: raw,
        };
        final Map<String, Map<String, Object?>> rows = driven[game.game]!.cards;

        final List<String> problems = <String>[];
        final Set<String> missing =
            rows.keys.toSet().difference(byId.keys.toSet());
        final Set<String> extra =
            byId.keys.toSet().difference(rows.keys.toSet());
        if (missing.isNotEmpty) {
          problems.add("${missing.length} cards the client derives are not "
              "in the file, e.g. ${missing.take(3).join(", ")}");
        }
        if (extra.isNotEmpty) {
          problems.add("${extra.length} cards in the file the client no "
              "longer derives, e.g. ${extra.take(3).join(", ")}");
        }
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.entries) {
          if (!byId.containsKey(entry.key)) continue;
          if (!sameJson(byId[entry.key], <String, Object?>{
            "id": entry.key,
            ...entry.value,
          })) {
            problems.add("${entry.key}: the client now derives a different "
                "row");
          }
        }
        expect(problems, isEmpty,
            reason: "${problems.take(5).join("; ")}. If the importer was "
                "not the thing that changed, regenerate with "
                "--dart-define=UPDATE_ID_VECTORS=true and read the diff.");
      });

      test("sets: the committed vectors are current", () {
        if (_update) return;
        final Map<String, dynamic> committed = _readGzip(_vectorPath);
        final Map<String, Object?> byCode = <String, Object?>{
          for (final dynamic raw in _setsOf(committed, game.game))
            (raw as Map<String, dynamic>)["code"] as String: raw,
        };
        final Map<String, Map<String, Object?>> rows = driven[game.game]!.sets;
        for (final MapEntry<String, Map<String, Object?>> entry
            in rows.entries) {
          expect(byCode.containsKey(entry.key), isTrue,
              reason: "set ${entry.key} is not in the committed vectors");
          expect(
              sameJson(byCode[entry.key],
                  <String, Object?>{"code": entry.key, ...entry.value}),
              isTrue,
              reason: "set ${entry.key} no longer derives the same row");
        }
        expect(byCode.length, rows.length,
            reason: "the file holds sets the client no longer derives");
      });

      test("no id is empty and no id repeats", () {
        final Map<String, Map<String, Object?>> rows = driven[game.game]!.cards;
        expect(rows.keys.where((String id) => id.trim().isEmpty), isEmpty);
        expect(rows.length, rows.keys.toSet().length);
      });

      for (final _NamedCheck check in game.checks) {
        test(check.name,
            () => check.run(samples[game.game]!, driven[game.game]!));
      }
    });
  }
}

/// One game's committed rows, keyed and sorted by the column that names them.
List<Map<String, Object?>> _sortedRows(
    Map<String, Map<String, Object?>> rows, String key) {
  final List<String> keys = rows.keys.toList()..sort();
  return <Map<String, Object?>>[
    for (final String name in keys)
      <String, Object?>{key: name, ...rows[name]!},
  ];
}

/// One game's block of the committed vectors.
Map<String, dynamic> _gameVectors(Map<String, dynamic> vectors, String game) {
  for (final dynamic raw in vectors["games"] as List<dynamic>) {
    final Map<String, dynamic> block = raw as Map<String, dynamic>;
    if (block["game"] == game) return block;
  }
  fail("the committed vectors hold no block for $game");
}

/// One game's committed card rows.
List<dynamic> _cardsOf(Map<String, dynamic> vectors, String game) =>
    _gameVectors(vectors, game)["cards"] as List<dynamic>;

/// One game's committed set rows.
List<dynamic> _setsOf(Map<String, dynamic> vectors, String game) =>
    _gameVectors(vectors, game)["sets"] as List<dynamic>;



