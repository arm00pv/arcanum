// The server importer and the Dart client must derive the same card rows.
//
//   flutter test test/catalog/catalog_id_parity_test.dart
//
// Design: docs/catalogue-server-side.md, sections 7 and 8. This is the test the
// design calls the most valuable thing in the document, and the reason is that
// the failure it catches is silent. A card id is derived, not forwarded: the
// importer writes a row, the client writes a row for the same card from the
// same provider response, and if the two disagree about the id - or about the
// name, the oracle id, the rarity spelling, the collector sort key, the JSON in
// extras - then a collection row naming that card stops resolving. It does not
// raise. It renders as "--", for ever, for one collector, and nothing anywhere
// says why.
//
// So the two sides are compared over real data rather than described in prose.
// tool/catalog/lorcana_sample.json.gz holds 440 real Lorcast card objects and
// all 24 sets, cut by tool/catalog/make_lorcana_sample.py. This test runs the
// real LorcanaCatalog over that sample and turns each TcgCard into the
// catalog_cards row a client would store. tool/catalog/test_id_parity.py runs
// the importer owner's own functions over the same sample and compares against
// the same committed file:
//
//   tool/catalog/catalog_id_vectors.json.gz
//
// Neither side is the authority. Both are asserted against the committed file,
// which was generated from the Dart and is reviewed as a diff, so a change in
// either language fails a test rather than moving the goalposts.
//
// Regenerate the vectors, and read the diff, with:
//
//   flutter test test/catalog/catalog_id_parity_test.dart \
//       --dart-define=UPDATE_ID_VECTORS=true
//
// Nothing here touches the network.

import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:arcanum/data/catalog/lorcana_catalog.dart";
import "package:arcanum/domain/models/tcg_card.dart";
import "package:dio/dio.dart";
import "package:flutter_test/flutter_test.dart";

const String _samplePath = "tool/catalog/lorcana_sample.json.gz";
const String _vectorPath = "tool/catalog/catalog_id_vectors.json.gz";

/// Whether to rewrite the committed vectors instead of asserting them.
const bool _update = bool.fromEnvironment("UPDATE_ID_VECTORS");

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

/// Serves the committed sample in place of the network.
///
/// The sample is what Lorcast actually answered, so the catalogue under test is
/// the real one rather than a convenient shape. A request for a set the sample
/// does not hold is a 404, which is how Lorcast answers an unknown code.
class _SampleLorcast implements HttpClientAdapter {
  _SampleLorcast(this.sets, this.byCode);

  /// The set objects as the sample holds them, unwrapped from the envelope
  /// Lorcast answers /sets with. put back on the way out.
  final List<dynamic> sets;
  final Map<String, String> byCode;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Map<String, List<String>> headers = <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    };
    final String path = options.uri.path;
    if (path.endsWith("/sets")) {
      // Lorcast answers the set list inside a results envelope; the sample
      // stores the unwrapped list, so it is wrapped again here.
      return ResponseBody.fromString(jsonEncode(<String, Object?>{"results": sets}),
          200, headers: headers);
    }
    final RegExpMatch? match =
        RegExp(r"/sets/([^/]+)/cards$").firstMatch(path);
    final String? body = match == null ? null : byCode[match.group(1)];
    if (body == null) {
      return ResponseBody.fromString('{"error":"Not found"}', 404,
          headers: headers);
    }
    return ResponseBody.fromString(body, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
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
/// card_count is 0 because Lorcast owner's set list publishes no count and the
/// only way to learn one is to download the set. That zero means "the provider
/// does not say"; card_row_count is what the import records after counting.
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

/// Every card row the sample produces, keyed by the id it was stored under.
Future<Map<String, Map<String, Object?>>> sampleRows() async {
  final Map<String, dynamic> sample = _readGzip(_samplePath);
  final List<dynamic> cards = sample["cards"] as List<dynamic>;
  final Map<String, String> byCode = <String, String>{};
  for (final dynamic raw in cards) {
    final Map<String, dynamic> card = raw as Map<String, dynamic>;
    final Map<String, dynamic> set = card["set"] as Map<String, dynamic>;
    final String code = set["code"] as String;
    byCode[code] = jsonEncode(
        <Map<String, dynamic>>[for (final dynamic c in cards)
          if (((c as Map<String, dynamic>)["set"] as Map<String, dynamic>)["code"] ==
              code)
            c]);
  }

  final Dio dio = Dio(BaseOptions(baseUrl: "https://api.lorcast.com/v0"));
  dio.httpClientAdapter =
      _SampleLorcast(sample["sets"] as List<dynamic>, byCode);
  final LorcanaCatalog catalog = LorcanaCatalog(dio: dio);

  final List<TcgSet> sets = await catalog.fetchAllSets();
  final Map<String, Map<String, Object?>> out = <String, Map<String, Object?>>{};
  for (final TcgSet set in sets) {
    for (final TcgCard card in await catalog.fetchCardsInSet(set.code)) {
      out[card.id] = rowOf(card);
    }
  }
  return out;
}

/// Every set row the sample produces, keyed by the stored (lower-case) code.
Future<Map<String, Map<String, Object?>>> sampleSetRows() async {
  final Map<String, dynamic> sample = _readGzip(_samplePath);
  final List<dynamic> sets = sample["sets"] as List<dynamic>;
  final Dio dio = Dio(BaseOptions(baseUrl: "https://api.lorcast.com/v0"));
  dio.httpClientAdapter =
      _SampleLorcast(sets, const <String, String>{});
  final LorcanaCatalog catalog = LorcanaCatalog(dio: dio);
  final Map<String, Map<String, Object?>> out = <String, Map<String, Object?>>{};
  for (final TcgSet set in await catalog.fetchAllSets()) {
    out[set.code] = setRowOf(set);
  }
  return out;
}

void main() {
  late Map<String, Map<String, Object?>> rows;
  late Map<String, Map<String, Object?>> setRows;

  setUpAll(() async {
    rows = await sampleRows();
    setRows = await sampleSetRows();
    if (_update) {
      _writeGzip(_vectorPath, <String, Object?>{
        "generated_by": "test/catalog/catalog_id_parity_test.dart",
        "why": "the derived rows both languages must agree on",
        "game": "lorcana",
        "sample": _samplePath,
        "cards": <Map<String, Object?>>[
          for (final String id in rows.keys.toList()..sort())
            <String, Object?>{"id": id, ...rows[id]!},
        ],
        "sets": <Map<String, Object?>>[
          for (final String code in setRows.keys.toList()..sort())
            <String, Object?>{"code": code, ...setRows[code]!},
        ],
      });
    }
  });

  group("the sample", () {
    test("is the size the design asks for and keeps the awkward shapes", () async {
      expect(rows.length, greaterThan(300),
          reason: "the design asks for a sample of a few hundred cards");
      expect(setRows.length, 24);

      final Map<String, dynamic> sample = _readGzip(_samplePath);
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
      expect(anyPromoArt, isTrue, reason: "no card without a TCGplayer product");
      expect(anyQuoted, isTrue, reason: "no quoted subtitle");
      expect(anyOddNumber, isTrue, reason: "no non-integer collector number");
      expect(multiInk, greaterThan(0), reason: "no two-ink card");
      // The branch where only the singular ink shorthand is published, which is
      // the one place the colours of a card come from somewhere else.
      expect(singleInkOnly, greaterThan(0),
          reason: "no card carrying only the singular ink");
    });
  });

  group("id parity with the importer", () {
    test("the committed vectors are current", () {
      if (_update) return;
      final Map<String, dynamic> committed = _readGzip(_vectorPath);
      final List<dynamic> expected = committed["cards"] as List<dynamic>;
      final Map<String, Object?> byId = <String, Object?>{
        for (final dynamic raw in expected)
          (raw as Map<String, dynamic>)["id"] as String : raw,
      };

      final List<String> problems = <String>[];
      final Set<String> missing = rows.keys.toSet().difference(
          byId.keys.map((String k) => k).toSet());
      final Set<String> extra = byId.keys.toSet().difference(rows.keys.toSet());
      if (missing.isNotEmpty) {
        problems.add("${missing.length} cards the client derives are not in the "
            "file, e.g. ${missing.take(3).join(", ")}");
      }
      if (extra.isNotEmpty) {
        problems.add("${extra.length} cards in the file the client no longer "
            "derives, e.g. ${extra.take(3).join(", ")}");
      }
      for (final MapEntry<String, Map<String, Object?>> entry in rows.entries) {
        if (!byId.containsKey(entry.key)) continue;
        if (!sameJson(byId[entry.key], <String, Object?>{
          "id": entry.key,
          ...entry.value,
        })) {
          problems.add("${entry.key}: the client now derives a different row");
        }
      }
      expect(problems, isEmpty,
          reason: "${problems.take(5).join("; ")}. If the importer was not the "
              "thing that changed, regenerate with "
              "--dart-define=UPDATE_ID_VECTORS=true and read the diff.");
    });

    test("every id is the provider owner's own id, verbatim", () {
      // Lorcana is the cheap pilot partly because its ids are forwarded rather
      // than synthesised - no passcode:set:printing:rarity to reconstruct. The
      // test still pins it, because "forwarded verbatim" is exactly the kind of
      // claim that quietly stops being true.
      final Map<String, dynamic> sample = _readGzip(_samplePath);
      final Set<String> providerIds = <String>{
        for (final dynamic raw in sample["cards"] as List<dynamic>)
          (raw as Map<String, dynamic>)["id"] as String,
      };
      expect(rows.keys.toSet().difference(providerIds), isEmpty);
      expect(rows.length, providerIds.length);
    });

    test("no id is empty and no id repeats", () {
      expect(rows.keys.where((String id) => id.trim().isEmpty), isEmpty);
      expect(rows.length, rows.keys.toSet().length);
    });
  });

  group("set parity with the importer", () {
    test("the committed set vectors are current", () {
      if (_update) return;
      final Map<String, dynamic> committed = _readGzip(_vectorPath);
      final Map<String, Object?> byCode = <String, Object?>{
        for (final dynamic raw in committed["sets"] as List<dynamic>)
          (raw as Map<String, dynamic>)["code"] as String : raw,
      };
      for (final MapEntry<String, Map<String, Object?>> entry in setRows.entries) {
        expect(byCode.containsKey(entry.key), isTrue,
            reason: "set ${entry.key} is not in the committed vectors");
        expect(
            sameJson(byCode[entry.key],
                <String, Object?>{"code": entry.key, ...entry.value}),
            isTrue,
            reason: "set ${entry.key} no longer derives the same row");
      }
    });

    test("stored set codes are lower case and unique", () {
      // The catalogue keys a set by (game, code) with the code folded to lower
      // case, and the provider addresses it case-sensitively - /sets/P1/cards
      // answers and /sets/p1/cards is a 404. Both spellings are real, and only
      // one of them is stored.
      for (final String code in setRows.keys) {
        expect(code, code.toLowerCase());
      }
      expect(setRows.length, 24);
    });
  });
}
