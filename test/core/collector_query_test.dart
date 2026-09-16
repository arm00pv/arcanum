// A printing named by its number, the way a collector says it out loud.
//
//   flutter test test/core/collector_query_test.dart
//
// The parse is the narrow part of number search: it has to say "this is a
// number" for "BT26-001" and "no, that is a name" for "energy removal", and it
// has to hand over the set code rather than assume it - whether "BT26" is a set
// is a question only the catalogue can answer.

import 'package:arcanum/core/utils/collector_query.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a number on its own', () {
    test('parses as a number with no set', () {
      final CollectorQuery q = CollectorQuery.parse('001')!;

      expect(q.number, '001');
      expect(q.standalone, isTrue);
      expect(q.codeCandidates, isEmpty);
    });

    test('a suffix belongs to the number', () {
      // Card "123a" is not card "123".
      expect(CollectorQuery.parse('123a')!.number, '123a');
      expect(CollectorQuery.parse('123a')!.standalone, isTrue);
    });
  });

  group('a code in front of the number', () {
    test('is offered folded, so the printed hyphens do not matter', () {
      const Map<String, ({String code, String number})> cases =
          <String, ({String code, String number})>{
            'BT26-001': (code: 'bt26', number: '001'),
            'BT-26-001': (code: 'bt26', number: '001'),
            'bt-26-001': (code: 'bt26', number: '001'),
            'BT26 001': (code: 'bt26', number: '001'),
            'ST23-01': (code: 'st23', number: '01'),
          };

      for (final MapEntry<String, ({String code, String number})> c
          in cases.entries) {
        final CollectorQuery q = CollectorQuery.parse(c.key)!;
        expect(q.standalone, isFalse, reason: c.key);
        expect(q.number, c.value.number, reason: c.key);
        expect(q.codeCandidates, <String>[c.value.code], reason: c.key);
      }
    });

    test('a printing region is offered as a second guess', () {
      // Yu-Gi-Oh! prints "LOB-EN001": LOB is the set, EN the region, 001 the
      // number. Only the catalogue knows whether "loben" or "lob" is the set.
      final CollectorQuery q = CollectorQuery.parse('LOB-EN001')!;

      expect(q.number, '001');
      expect(q.codeCandidates, <String>['loben', 'lob']);
    });

    test('a set code that is also a number word still parses', () {
      final CollectorQuery q = CollectorQuery.parse('base1-4')!;

      expect(q.number, '4');
      expect(q.codeCandidates, <String>['base1']);
    });
  });

  group('what is not a number query', () {
    test('a name is not', () {
      for (final String raw in <String>[
        'Charizard',
        'energy removal',
        'Bloomburrow',
        'a',
        '',
        '   ',
        '-',
      ]) {
        expect(CollectorQuery.parse(raw), isNull, reason: raw);
      }
    });

    test('a name with a number after it is still a name, until a set says so', () {
      // "mewtwo" is not a set, and a two-word query is not a bare number, so
      // the catalogue will refuse this one rather than answer with #2 of every
      // set in the game.
      final CollectorQuery q = CollectorQuery.parse('Mewtwo 2')!;

      expect(q.standalone, isFalse);
      expect(q.codeCandidates, <String>['mewtwo']);
    });
  });
}
