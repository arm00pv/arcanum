// The collector-number grammar, as the two languages are held to it.
//
//   flutter test test/catalog/number_query_vectors_test.dart
//
// The parse lives in Dart: CollectorQuery.parse decides what "LOB-EN001" names
// and catalog_cards_by_number is handed the answer. The committed vector file is
// that answer written down, and both sides assert against it - this test for the
// Dart half and tool/catalog/prove_catalogue_reads.py for the Postgres half,
// which runs every vector through the deployed function.
//
// A file that agreed with nothing would pass both, so what is asserted here is
// also the shape of the file: a query with two candidate set codes, a query that
// stands on its own, a number spelled in two cases, and queries that are not
// number queries at all. Those are the cases the function's comparison gets
// wrong when it gets anything wrong.

import 'dart:convert';
import 'dart:io';

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:flutter_test/flutter_test.dart';

const String _path = 'tool/catalog/number_query_vectors.json';

List<Map<String, dynamic>> _vectors() {
  final File file = File(_path);
  if (!file.existsSync()) {
    fail(
      '$_path is missing; regenerate it with '
      'dart run tool/catalog/gen_number_query_vectors.dart',
    );
  }
  final Map<String, dynamic> payload =
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return <Map<String, dynamic>>[
    for (final dynamic raw in payload['queries'] as List<dynamic>)
      Map<String, dynamic>.from(raw as Map<dynamic, dynamic>),
  ];
}

void main() {
  late List<Map<String, dynamic>> vectors;

  setUpAll(() => vectors = _vectors());

  test('every vector is what the Dart parse says today', () {
    final problems = <String>[];
    for (final Map<String, dynamic> vector in vectors) {
      final String raw = vector['raw'] as String;
      final CollectorQuery? parsed = CollectorQuery.parse(raw);
      if ((vector['parsed'] as bool) != (parsed != null)) {
        problems.add('$raw: parsed is ${vector['parsed']}, Dart says $parsed');
        continue;
      }
      if (parsed == null) continue;
      if (!_sameList(vector['code_candidates'], parsed.codeCandidates)) {
        problems.add(
          '$raw: candidates are ${vector['code_candidates']}, '
          'Dart says ${parsed.codeCandidates}',
        );
      }
      if (vector['number'] != parsed.number) {
        problems.add(
          '$raw: number is ${vector['number']}, Dart says ${parsed.number}',
        );
      }
      if (vector['standalone'] != parsed.standalone) {
        problems.add(
          '$raw: standalone is ${vector['standalone']}, '
          'Dart says ${parsed.standalone}',
        );
      }
    }
    expect(
      problems,
      isEmpty,
      reason:
          '${problems.take(5).join('; ')} - the grammar changed, so regenerate '
          'the file and read the diff',
    );
  });

  test('the vectors describe the cases the function can get wrong', () {
    final parsed = <Map<String, dynamic>>[
      for (final Map<String, dynamic> v in vectors)
        if (v['parsed'] == true) v,
    ];
    expect(
      parsed,
      isNotEmpty,
      reason: 'a file in which nothing parses proves nothing',
    );
    expect(
      parsed
          .where(
            (Map<String, dynamic> v) =>
                (v['code_candidates'] as List<dynamic>).length > 1,
          )
          .toList(),
      isNotEmpty,
      reason:
          'a region form like LOB-EN001 offers two candidates, and the order '
          'they are offered in is the ranking the catalogue answers in',
    );
    expect(
      parsed
          .where((Map<String, dynamic> v) => v['standalone'] == true)
          .toList(),
      isNotEmpty,
      reason: 'a bare number names no set and has to be searched for alone',
    );

    final Map<String, List<String>> spellings = <String, List<String>>{};
    for (final Map<String, dynamic> v in parsed) {
      spellings
          .putIfAbsent((v['number'] as String).toLowerCase(), () => <String>[])
          .add(v['raw'] as String);
    }
    expect(
      spellings.entries
          .where(
            (MapEntry<String, List<String>> e) =>
                e.value.toSet().length > 1 &&
                e.value.any((String raw) => raw == raw.toUpperCase()),
          )
          .toList(),
      isNotEmpty,
      reason:
          'a number the catalogue stores in upper case has to have its '
          'lower-case spelling in the file, or a comparison that folds one '
          'side only would never be exercised',
    );
    expect(
      vectors.where((Map<String, dynamic> v) => v['parsed'] == false).toList(),
      isNotEmpty,
      reason: 'the vectors that are not numbers are what keeps search working',
    );
  });
}

bool _sameList(Object? a, List<String> b) {
  if (a is! List) return false;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
