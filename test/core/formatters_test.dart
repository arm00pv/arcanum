// Tests for the display formatters.
//
//   flutter test test/core/formatters_test.dart
//
// The summary line above a collection is read by someone with one card in it as
// often as by someone with ten thousand, so the counted noun is asserted rather
// than assumed.

import 'package:arcanum/core/utils/formatters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('counted nouns', () {
    test('a count of one is singular', () {
      expect(Fmt.countOf(1, 'card'), '1 card');
      expect(Fmt.countOf(1, 'set'), '1 set');
      expect(Fmt.countOf(1, 'printing'), '1 printing');
    });

    test('every other count is plural, including none', () {
      expect(Fmt.countOf(0, 'card'), '0 cards');
      expect(Fmt.countOf(2, 'card'), '2 cards');
      expect(Fmt.countOf(87, 'set'), '87 sets');
    });

    test('an unknown count keeps the count placeholder', () {
      // The overview is null until it loads, and "null cards" is not a thing.
      expect(Fmt.countOf(null, 'card'), '-- cards');
    });

    test('a thousands separator survives', () {
      expect(Fmt.countOf(12480, 'card'), '12,480 cards');
    });
  });
}
