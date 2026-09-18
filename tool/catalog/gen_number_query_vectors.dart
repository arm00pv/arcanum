// Generates tool/catalog/number_query_vectors.json from CollectorQuery.parse.
//
//     dart run tool/catalog/gen_number_query_vectors.dart
//
// Design: docs/catalogue-server-side.md, section 4. The collector-number
// grammar lives in Dart and only in Dart - CollectorQuery.parse decides what
// part of "LOB-EN001" is a set code, what the number is, and whether the query
// stands on its own - and Postgres is handed the result rather than a second
// implementation of the rule. That leaves one thing to get wrong: a
// catalog_cards_by_number that reads the parse differently from the way it was
// written. The vectors are how the two sides are held to each other.
//
// This writes the parse out of the Dart function, and both sides assert against
// the committed file:
//
//   * test/catalog/number_query_vectors_test.dart - Dart asserts the file
//   * tool/catalog/prove_catalogue_reads.py       - Postgres runs every vector
//     through the deployed catalog_cards_by_number and against a reference
//     predicate transcribed from CatalogDao.searchByNumber's own SQL
//
// The inputs are real: the Lorcana sample's collector numbers, its set codes,
// and queries built out of both. On top of those come the shapes a real
// catalogue does not contain but a collector types - the separators, the
// two-candidate region form, a bare number, a padded number, and the empty
// string - and, because it is the one the function's own comparison got wrong,
// the lower-case spelling of a number the catalogue stores in upper case.
//
// Regenerating this file changes what both tests assert, so the diff has to be
// read rather than accepted.

import "dart:convert";
import "dart:io";

import "package:arcanum/core/utils/collector_query.dart";

/// Queries a collector types, each one here for a stated reason.
const List<String> crafted = <String>[
  // A set code, a separator and a number: the form the app's own tests use.
  "BT-26-001",
  "BT26-001",
  "ST23-01",
  // Two candidates, because the letters between set and number are a printing
  // region and only the catalogue knows which of the two is the set.
  "LOB-EN001",
  "MAMA-EN001",
  // The number alone, padded and not: Digimon prints 001 where Magic prints 1.
  "001",
  "1",
  "01",
  "000",
  "0",
  // Trailing letters, which are part of the number and not a suffix to drop.
  "123a",
  "BLB 123a",
  "1f",
  // A word in front of a number, which is a number query whose "set code" is a
  // word no catalogue has - the parse cannot know that, and the catalogue says
  // so by matching no set.
  "Mewtwo 2",
  // The same query in lower case, for a number the catalogue stores in upper
  // case. This is the vector that decides whether the server folds case.
  "24b",
  // Nothing but a number query's shape, with no set and no number to speak of.
  "P1",
  "BT-26",
  // Not number queries at all, which is what keeps the name search working.
  "Charizard",
  "Elsa",
  "let it go",
  "50%",
  "a_b",
  "#001",
  "",
  "   ",
];

/// The catalogue's own collector numbers, so the vectors describe queries
/// someone would really type rather than only ones that are convenient.
Future<List<String>> realNumbers() async {
  final Directory here = File.fromUri(Platform.script).parent;
  final File sample = File("${here.path}/lorcana_sample.json.gz");
  if (!sample.existsSync()) {
    stderr.writeln(
      "no sample beside this script: writing the crafted cases only",
    );
    return const <String>[];
  }
  final Map<String, dynamic> payload = jsonDecode(
    utf8.decode(gzip.decode(sample.readAsBytesSync())),
  ) as Map<String, dynamic>;
  final Set<String> numbers = <String>{
    for (final dynamic card in payload["cards"] as List<dynamic>)
      if ((card as Map<String, dynamic>)["collector_number"] != null)
        card["collector_number"].toString(),
  };
  return numbers.toList()..sort();
}

Future<void> main() async {
  final Set<String> queries = <String>{...crafted, ...await realNumbers()};
  // Every number that carries a letter, in both spellings: the pair is what
  // catches a comparison that folds case on one side only.
  final List<String> carryingLetters = <String>[
    for (final String number in queries)
      if (RegExp(r"[A-Za-z]").hasMatch(number)) number,
  ];
  queries.addAll(<String>[
    for (final String number in carryingLetters) number.toLowerCase(),
  ]);
  queries.addAll(<String>[
    for (final String number in carryingLetters) number.toUpperCase(),
  ]);

  final Map<String, Object?> out = <String, Object?>{
    "generated_by": "tool/catalog/gen_number_query_vectors.dart",
    "why": "section 4: one grammar, in Dart, and Postgres agreeing with what it produced",
    "queries": <Map<String, Object?>>[
      for (final String raw in queries.toList()..sort()) _vector(raw),
    ],
  };

  final Directory here = File.fromUri(Platform.script).parent;
  final File target = File("${here.path}/number_query_vectors.json");
  target.writeAsStringSync(
    "${const JsonEncoder.withIndent("  ").convert(out)}\n",
  );

  final List<Map<String, Object?>> vectors =
      out["queries"] as List<Map<String, Object?>>;
  final int parsed = vectors
      .where((Map<String, Object?> v) => v["parsed"] == true)
      .length;
  final int standalone = vectors
      .where((Map<String, Object?> v) => v["standalone"] == true)
      .length;
  stdout.writeln(
    "${vectors.length} query vectors, $parsed of them number queries",
  );
  stdout.writeln("$standalone of those stand on their own, naming no set");
  stdout.writeln("  ${target.path}");
}

Map<String, Object?> _vector(String raw) {
  final CollectorQuery? query = CollectorQuery.parse(raw);
  return <String, Object?>{
    "raw": raw,
    "parsed": query != null,
    if (query != null) "code_candidates": query.codeCandidates,
    if (query != null) "number": query.number,
    if (query != null) "standalone": query.standalone,
  };
}
