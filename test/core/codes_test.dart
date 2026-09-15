// The code a collector reads off the box and the code the app keeps.
//
//   flutter test test/core/codes_test.dart
//
// Bandai prints "BT-26" where the catalogue keeps "BT26", and typing what is in
// your hand should find the set. The one thing folding must not do is swallow
// the number itself: a leading zero is part of what is printed on the card, so
// "sv1" is not made to answer for "SV01".

import 'package:arcanum/core/utils/codes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('folding', () {
    test('drops the separators a publisher prints', () {
      expect(Codes.fold('BT-26'), 'bt26');
      expect(Codes.fold('ST-23'), 'st23');
      expect(Codes.fold('EX-13'), 'ex13');
      expect(Codes.fold('MAMA-EN001'), 'mamaen001');
    });

    test('leaves a code with nothing to drop alone', () {
      expect(Codes.fold('BLB'), 'blb');
      expect(Codes.fold('base1'), 'base1');
      expect(Codes.fold('1'), '1');
    });

    test('a query of nothing but punctuation folds away', () {
      expect(Codes.fold(' - '), '');
      expect(Codes.fold('?!'), '');
    });
  });

  group('matching', () {
    test('the printed code finds the stored code', () {
      expect(Codes.matches('BT26', Codes.fold('BT-26')), isTrue);
      expect(Codes.matches('ST23', Codes.fold('st-23')), isTrue);
      expect(Codes.matches('MAMA-EN001', Codes.fold('mamaen001')), isTrue);
    });

    test('the stored code still finds it', () {
      expect(Codes.matches('BT26', Codes.fold('bt26')), isTrue);
      expect(Codes.matches('BT26', Codes.fold('BT26')), isTrue);
    });

    test('a partial code matches, as it always did', () {
      expect(Codes.matches('BT26', Codes.fold('26')), isTrue);
      expect(Codes.matches('BT26', Codes.fold('27')), isFalse);
    });

    test('a leading zero is kept: it is part of the number', () {
      expect(Codes.matches('SV01', Codes.fold('sv1')), isFalse);
      expect(Codes.matches('SV1', Codes.fold('sv1')), isTrue);
    });

    test('an empty needle matches nothing at all', () {
      // Otherwise searching for "-" would answer with every set there is.
      expect(Codes.matches('BT26', ''), isFalse);
    });
  });

  group('the SQL fold', () {
    test('strips every separator the Dart fold strips', () {
      final String sql = Codes.foldedSql('code');
      for (final String separator in Codes.separators) {
        expect(
          sql,
          contains("'$separator'"),
          reason:
              'SQLite has to be told about $separator one replace() at a time',
        );
      }
      expect(sql, startsWith('replace('));
      // The innermost call is the first separator in the list; each one after
      // it wraps the expression built so far.
      expect(
        sql,
        contains("replace(lower(code), '${Codes.separators.first}', '')"),
      );
    });
  });
}
