// Generates tool/catalog/fold_vectors.json from the Dart folding rules.
//
//     dart run tool/catalog/gen_fold_vectors.dart
//
// Design: docs/catalogue-server-side.md, section 2.3. The catalogue has two
// places that decide what the comparison form of a set code is, and they do not
// agree: Codes.fold strips everything outside a-z0-9, while Codes.foldedSql -
// which is what SQLite and the generated Postgres column use - strips only the
// six separators listed in Codes.separators. The server must mirror the second,
// because a folded column has to fold the way the browser owner's own SQLite folds
// it or the same query answers differently depending on which path served it.
//
// Two hand-written implementations of one rule is the likeliest way this design
// quietly stops working, so neither side is trusted to agree with the other.
// This writes the vectors out of the Dart functions, and both the Dart test and
// the SQL proof assert against the committed file:
//
//   * test/catalog/code_fold_vectors_test.dart  - Dart asserts the file
//   * tool/catalog/prove_lorcana_import.py      - Postgres asserts the file
//
// The inputs are the real set codes and collector numbers of the committed
// Lorcana sample, plus the cases a real catalogue does not happen to contain:
// every separator, characters that fold() drops but foldedSql() keeps, mixed
// case, and the empty string. The interesting column is "stored", which must
// differ from "fold" on some inputs - a vector file on which the two never
// disagree would pass while proving nothing.
//
// Regenerating this file changes what both tests assert, so the diff has to be
// read rather than accepted.

import "dart:convert";
import "dart:io";

import "package:arcanum/core/utils/codes.dart";

/// Set codes and collector numbers that a real catalogue contains, plus the
/// shapes it could contain. Written out rather than generated because each one
/// is here for a stated reason.
const List<String> codeCases = <String>[
  "",
  "1",
  "10",
  "P1",
  "cp",
  "D23",
  "DIS",
  "C2",
  "CC1",
  "Coconut",
  "PD1",
  // A separator each: these are the six foldedSql strips, one at a time.
  "BT-26",
  "BT 26",
  "BT.26",
  "BT/26",
  "BT_26",
  "BT:26",
  // Several at once, and the case fold.
  "MAMA-EN001",
  "st-23",
  "EX-13",
  "  padded  ",
  "Mixed-Case.Code",
  // Characters fold() drops and foldedSql() keeps. These are the vectors that
  // make the two rules distinguishable, and they are why the file is not
  // simply a list of codes that happen to be alphanumeric.
  "BT#26",
  "BT+26",
  "BT(26)",
  "BT's",
  "BT,26",
  "BT!26",
  "BT%26",
  "BT&26",
  "BT*26",
  "BT=26",
  "BT@26",
  "BT[26]",
  "BT{26}",
  "BT|26",
  "BT\\26",
  "BT~26",
  "BT?26",
  "BT;26",
  "BT<26>",
  "BT-26/EN",
  // Non-ASCII: neither rule keeps it, and both must agree that they do not.
  "P\u00e9kor",
  "\u30dd\u30b1\u30e2\u30f3",
  "\u2013dash",
  "\u00a0nbsp",
];

/// Collector numbers, for the separate zero-padding rule that number_bare
/// materialises. Kept apart from the code vectors because it is a different
/// rule: Digimon prints 001 where Magic prints 1.
const List<String> numberCases = <String>[
  "",
  "0",
  "00",
  "000",
  "1",
  "01",
  "001",
  "0012",
  "10",
  "010",
  "125",
  "0125",
  "24B",
  "25ja",
  "4a",
  "65f",
  "TG01",
  "SV001",
  "H1",
  "\u26051",
  "001a",
  "1f",
  "2f",
  "0x1f",
  "-5",
  "+5",
];

/// The stored form of a code: lower case, with exactly the separators
/// Codes.separators names removed, one at a time, in order.
///
/// This is a transcription of what Codes.foldedSql builds, written as an
/// evaluation so the generated column has something to be compared against.
String storedForm(String input) {
  var out = input.toLowerCase();
  for (final String separator in Codes.separators) {
    out = out.replaceAll(separator, "");
  }
  return out;
}

/// The stored form of a collector number: SQL ltrim(x, '0') takes every leading
/// zero and nothing else, so a number that is all zeros becomes empty.
String bareForm(String input) {
  final match = RegExp(r"^0+").firstMatch(input);
  return match == null ? input : input.substring(match.end);
}

Future<void> main(List<String> argv) async {
  final Directory here = File.fromUri(Platform.script).parent;
  final File sample = File("${here.path}/lorcana_sample.json.gz");

  // Real inputs, so the vectors describe a catalogue that exists rather than
  // one that is convenient. Absent is survivable: the crafted cases below are
  // the ones that decide whether the rules agree.
  final Set<String> realCodes = <String>{};
  final Set<String> realNumbers = <String>{};
  if (sample.existsSync()) {
    final Map<String, dynamic> payload =
        jsonDecode(utf8.decode(gzip.decode(sample.readAsBytesSync())))
            as Map<String, dynamic>;
    for (final dynamic set in payload["sets"] as List<dynamic>) {
      final Object? code = (set as Map<String, dynamic>)["code"];
      if (code is String) realCodes.add(code);
    }
    for (final dynamic card in payload["cards"] as List<dynamic>) {
      final Object? number = (card as Map<String, dynamic>)["collector_number"];
      if (number != null) realNumbers.add(number.toString());
    }
  } else {
    stderr.writeln("no sample beside this script: writing the crafted cases only");
  }

  final List<String> codes = <String>{...codeCases, ...realCodes}.toList()..sort();
  final List<String> numbers =
      <String>{...numberCases, ...realNumbers}.toList()..sort();

  final Map<String, Object?> out = <String, Object?>{
    "generated_by": "tool/catalog/gen_fold_vectors.dart",
    "why": "section 2.3: one rule, two languages, asserted from both sides",
    "separators": Codes.separators,
    // The expression itself, built by the Dart function the SQLite path uses.
    // Postgres is made to agree with this string, not with a copy of it.
    "code_expr_sql": Codes.foldedSql("code"),
    "number_expr_sql": "ltrim(collector_number, '0')",
    "codes": <Map<String, String>>[
      for (final String input in codes)
        <String, String>{
          "input": input,
          "fold": Codes.fold(input),
          "stored": storedForm(input),
        },
    ],
    "numbers": <Map<String, String>>[
      for (final String input in numbers)
        <String, String>{"input": input, "bare": bareForm(input)},
    ],
  };

  final File target = File("${here.path}/fold_vectors.json");
  // Trailing newline and no locale-dependent formatting, so two runs on two
  // machines produce the same bytes.
  target.writeAsStringSync(
      "${const JsonEncoder.withIndent("  ").convert(out)}\n");

  final int disagree = (out["codes"] as List<Map<String, String>>)
      .where((Map<String, String> v) => v["fold"] != v["stored"])
      .length;
  stdout.writeln("${codes.length} code vectors, ${numbers.length} number vectors");
  stdout.writeln("$disagree of them fold differently depending on which rule is used");
  stdout.writeln("  ${target.path}");
}