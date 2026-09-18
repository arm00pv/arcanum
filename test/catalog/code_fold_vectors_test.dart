// The two folding rules, asserted against the committed vector file.
//
//   flutter test test/catalog/code_fold_vectors_test.dart
//
// Design: docs/catalogue-server-side.md, section 2.3. The app has two answers
// to "what is the comparison form of a set code" and they do not agree:
// Codes.fold drops everything outside a-z0-9, while Codes.foldedSql - which is
// what SQLite uses and what the generated code_folded column mirrors - drops
// exactly the six separators in Codes.separators. The server has to fold the
// second way, or a code containing an exotic character folds differently on the
// server than in the browser owner's own SQLite and the same query answers
// differently depending on which path served it.
//
// Two hand-written implementations of one rule is the likeliest way this design
// quietly stops working, so neither side is trusted to agree with the other.
// tool/catalog/gen_fold_vectors.dart writes the vectors out of these same Dart
// functions, this file asserts the Dart side against them, and
// tool/catalog/prove_lorcana_import.py asserts the live Postgres column and its
// expression against the same file. A change to Codes.separators therefore fails
// here and in the SQL proof at once rather than in one of them and not the other.
//
// Nothing here touches the network or the database.

import "dart:convert";
import "dart:io";

import "package:arcanum/core/utils/codes.dart";
import "package:flutter_test/flutter_test.dart";

/// The committed vectors, read from the repository root.
///
/// Regenerate with: dart run tool/catalog/gen_fold_vectors.dart
Map<String, dynamic> loadVectors() {
  final File file = File("tool/catalog/fold_vectors.json");
  if (!file.existsSync()) {
    fail("tool/catalog/fold_vectors.json is missing; regenerate it with "
        "dart run tool/catalog/gen_fold_vectors.dart");
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// What Codes.foldedSql describes, evaluated: lower case, then each separator
/// in Codes.separators removed in the order the list gives them.
///
/// Written out here rather than imported from the generator so that a mistake
/// in the generator is caught rather than agreed with.
String storedForm(String input) {
  var out = input.toLowerCase();
  for (final String separator in Codes.separators) {
    out = out.replaceAll(separator, "");
  }
  return out;
}

/// What SQL ltrim(x, '0') does: every leading zero, and nothing else.
String bareForm(String input) {
  final RegExpMatch? match = RegExp(r"^0+").firstMatch(input);
  return match == null ? input : input.substring(match.end);
}

void main() {
  final Map<String, dynamic> vectors = loadVectors();
  final List<dynamic> codes = vectors["codes"] as List<dynamic>;
  final List<dynamic> numbers = vectors["numbers"] as List<dynamic>;

  group("the committed vector file", () {
    test("carries the separators Codes declares, in order", () {
      // The order matters: the generated column nests six replace() calls, and
      // reordering them would produce a different expression string even where
      // the result was the same for every input.
      expect(vectors["separators"], Codes.separators);
    });

    test("carries the SQL expression Codes.foldedSql builds", () {
      // This is the string the live generated column is compared against, so
      // it must come from the function SQLite already uses rather than from a
      // hand-typed copy that could drift away from it.
      expect(vectors["code_expr_sql"], Codes.foldedSql("code"));
      expect(vectors["number_expr_sql"], "ltrim(collector_number, '0')");
    });

    test("is large enough to be worth asserting", () {
      expect(codes.length, greaterThan(50));
      expect(numbers.length, greaterThan(50));
    });

    test("still contains inputs on which the two rules disagree", () {
      // The whole reason to commit a vector file rather than assert the two
      // rules against each other. If every input folded the same way under both
      // rules, this file would pass while distinguishing nothing, and the server
      // could drift to Codes.fold without anything failing.
      final Iterable<dynamic> differing = codes.where((dynamic raw) {
        final Map<String, dynamic> v = raw as Map<String, dynamic>;
        return v["fold"] != v["stored"];
      });
      expect(differing.length, greaterThan(5));
    });
  });

  group("Codes.fold", () {
    test("matches every committed vector", () {
      final List<String> wrong = <String>[];
      for (final dynamic raw in codes) {
        final Map<String, dynamic> vector = raw as Map<String, dynamic>;
        final String input = vector["input"] as String;
        final String expected = vector["fold"] as String;
        final String actual = Codes.fold(input);
        if (actual != expected) {
          wrong.add("${jsonEncode(input)}: $actual, expected $expected");
        }
      }
      expect(wrong, isEmpty, reason: wrong.take(10).join("; "));
    });

    test("folds the stored code before comparing", () {
      // matches() folds the code side and treats the needle as already folded -
      // that is, as Codes.fold of whatever was typed - which is why a collector
      // typing BT-26 and a catalogue holding BT26 still meet. Both directions
      // are pinned here because only the code side is folded here; the needle
      // was folded by its caller.
      expect(Codes.matches("BT-26", Codes.fold("BT26")), isTrue);
      expect(Codes.matches("BT26", Codes.fold("BT-26")), isTrue);
      expect(Codes.matches("MAMA-EN001", Codes.fold("mama en 001")), isTrue);
      // Folded, a typed "BT#26" is "bt26", so it does match BT-26 - the
      // separator is meant to be forgiving, not significant.
      expect(Codes.matches("BT-26", Codes.fold("BT#26")), isTrue);
      // An empty needle matches nothing rather than everything.
      expect(Codes.matches("BT-26", ""), isFalse);
      expect(Codes.matches("anything", ""), isFalse);
      expect(Codes.matches("BT-26", Codes.fold("st23")), isFalse);
    });
  });

  group("the stored form, which is what the server must mirror", () {
    test("matches every committed vector", () {
      final List<String> wrong = <String>[];
      for (final dynamic raw in codes) {
        final Map<String, dynamic> vector = raw as Map<String, dynamic>;
        final String input = vector["input"] as String;
        final String expected = vector["stored"] as String;
        final String actual = storedForm(input);
        if (actual != expected) {
          wrong.add("${jsonEncode(input)}: $actual, expected $expected");
        }
      }
      expect(wrong, isEmpty, reason: wrong.take(10).join("; "));
    });

    test("keeps the characters fold() would drop", () {
      // The single clearest statement of why the generated column mirrors
      // foldedSql and not fold.
      expect(storedForm("BT#26"), "bt#26");
      expect(Codes.fold("BT#26"), "bt26");
    });

    test("drops each of the six separators", () {
      for (final String separator in Codes.separators) {
        expect(storedForm("A${separator}B"), "ab",
            reason: "separator ${jsonEncode(separator)} survived");
      }
    });
  });

  group("number_bare", () {
    test("trims leading zeros for every committed vector", () {
      final List<String> wrong = <String>[];
      for (final dynamic raw in numbers) {
        final Map<String, dynamic> vector = raw as Map<String, dynamic>;
        final String input = vector["input"] as String;
        final String expected = vector["bare"] as String;
        final String actual = bareForm(input);
        if (actual != expected) {
          wrong.add("${jsonEncode(input)}: $actual, expected $expected");
        }
      }
      expect(wrong, isEmpty, reason: wrong.take(10).join("; "));
    });

    test("leaves a zero that is not leading alone", () {
      // Leading zeros only: 010 and 10 are different numbers to a collector,
      // and 1001 must not become 11.
      expect(bareForm("1001"), "1001");
      expect(bareForm("0012"), "12");
      expect(bareForm("000"), "");
    });
  });
}
