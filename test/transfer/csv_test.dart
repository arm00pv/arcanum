import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/transfer/collection_transfer.dart';
import 'package:arcanum/data/transfer/csv.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:flutter_test/flutter_test.dart';

TcgCard _card({
  String id = 'abc',
  String name = 'Lightning Bolt',
  String setCode = 'lea',
  String collectorNumber = '161',
}) =>
    TcgCard(
      game: CardGame.mtg,
      id: id,
      setCode: setCode,
      setName: 'Limited Edition Alpha',
      name: name,
      collectorNumber: collectorNumber,
      rarity: 'common',
    );

CollectionEntry _entry({
  String cardId = 'abc',
  CardFinish finish = CardFinish.nonfoil,
  CardCondition condition = CardCondition.nearMint,
  int quantity = 1,
  String binder = '',
  double? price,
}) =>
    CollectionEntry(
      cardId: cardId,
      finish: finish,
      condition: condition,
      quantity: quantity,
      binder: binder,
      purchasePrice: price,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  group('Csv.parse', () {
    test('reads plain rows', () {
      final rows = Csv.parse('a,b,c\n1,2,3');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', '2', '3'],
      ]);
    });

    test('does not invent a row after a trailing newline', () {
      expect(Csv.parse('a,b\n1,2\n').length, 2);
      expect(Csv.parse('a,b\r\n1,2\r\n').length, 2);
    });

    test('handles CRLF and bare CR line endings', () {
      expect(Csv.parse('a,b\r\n1,2\r\n3,4').length, 3);
      expect(Csv.parse('a,b\r1,2\r3,4').length, 3);
    });

    test('keeps commas inside quoted fields', () {
      final rows = Csv.parse('name,set\n"Nicol Bolas, the Ravager",m19');
      expect(rows[1][0], 'Nicol Bolas, the Ravager');
      expect(rows[1][1], 'm19');
    });

    test('keeps newlines inside quoted fields', () {
      final rows = Csv.parse('name,notes\n"Line one\nLine two",ok');
      expect(rows.length, 2);
      expect(rows[1][0], 'Line one\nLine two');
      expect(rows[1][1], 'ok');
    });

    test('unescapes doubled quotes', () {
      final rows = Csv.parse('name\n"He said ""hi"""');
      expect(rows[1][0], 'He said "hi"');
    });

    test('strips a leading byte order mark', () {
      final rows = Csv.parse('\uFEFFname,qty\nBolt,4');
      expect(rows[0][0], 'name');
    });

    test('returns nothing for empty input', () {
      expect(Csv.parse(''), isEmpty);
    });

    test('preserves an intentionally empty trailing field', () {
      final rows = Csv.parse('a,b,c\n1,2,');
      expect(rows[1], ['1', '2', '']);
    });
  });

  group('Csv.encode', () {
    test('quotes only what needs quoting', () {
      expect(Csv.escapeField('plain'), 'plain');
      expect(Csv.escapeField('a,b'), '"a,b"');
      expect(Csv.escapeField('say "hi"'), '"say ""hi"""');
      expect(Csv.escapeField('two\nlines'), '"two\nlines"');
    });

    test('round-trips a row through parse', () {
      final original = [
        ['name', 'notes'],
        ['Nicol Bolas, the Ravager', 'has "quotes" and, commas'],
      ];
      expect(Csv.parse(Csv.encode(original)), original);
    });
  });

  group('CollectionCsvReader.detect', () {
    test('recognises Moxfield', () {
      final dialect = CollectionCsvReader.detect(
        ['Count', 'Tradelist Count', 'Name', 'Edition', 'Condition', 'Foil'],
      );
      expect(dialect, TransferDialect.moxfield);
    });

    test('recognises Archidekt', () {
      final dialect = CollectionCsvReader.detect(
        ['Quantity', 'Name', 'Edition', 'Condition', 'Categories'],
      );
      expect(dialect, TransferDialect.archidekt);
    });

    test('recognises the Arcanum format', () {
      final dialect = CollectionCsvReader.detect(
        ['card_id', 'name', 'set_code', 'quantity'],
      );
      expect(dialect, TransferDialect.arcanum);
    });

    test('falls back to generic', () {
      expect(
        CollectionCsvReader.detect(['Quantity', 'Name']),
        TransferDialect.generic,
      );
    });
  });

  group('CollectionCsvReader.parse', () {
    test('reads a Moxfield row end to end', () {
      const text = 'Count,Tradelist Count,Name,Edition,Condition,Language,Foil,'
          'Tags,Collector Number\n'
          '4,0,Lightning Bolt,LEA,NM,en,foil,Burn,161\n';
      final parsed = CollectionCsvReader.parse(text);
      expect(parsed.dialect, TransferDialect.moxfield);
      expect(parsed.problems, isEmpty);
      expect(parsed.rows.length, 1);

      final row = parsed.rows.first;
      expect(row.name, 'Lightning Bolt');
      expect(row.quantity, 4);
      expect(row.setCode, 'lea');
      expect(row.collectorNumber, '161');
      expect(row.finish, CardFinish.foil);
      expect(row.condition, CardCondition.nearMint);
      expect(row.language, 'en');
      expect(row.binder, 'Burn');
    });

    test('reads a quoted name containing a comma', () {
      const text = 'Quantity,Name,Set Code,Collector Number\n'
          '1,"Nicol Bolas, the Ravager",m19,217\n';
      final parsed = CollectionCsvReader.parse(text);
      expect(parsed.rows.single.name, 'Nicol Bolas, the Ravager');
      expect(parsed.rows.single.collectorNumber, '217');
    });

    test('skips blank lines without reporting them', () {
      const text = 'Quantity,Name\n1,Bolt\n\n\n2,Counterspell\n';
      final parsed = CollectionCsvReader.parse(text);
      expect(parsed.rows.length, 2);
      expect(parsed.problems, isEmpty);
    });

    test('skips zero quantity rows and says why', () {
      const text = 'Quantity,Name\n0,Bolt\n2,Counterspell\n';
      final parsed = CollectionCsvReader.parse(text);
      expect(parsed.rows.length, 1);
      expect(parsed.rows.single.name, 'Counterspell');
      expect(parsed.problems.single, contains('quantity is zero'));
    });

    test('reports a file with no name column rather than guessing', () {
      const text = 'Foo,Bar\n1,2\n';
      final parsed = CollectionCsvReader.parse(text);
      expect(parsed.rows, isEmpty);
      expect(parsed.problems.single, contains('No card name column'));
    });

    test('handles an empty file', () {
      final parsed = CollectionCsvReader.parse('');
      expect(parsed.rows, isEmpty);
      expect(parsed.problems.single, contains('empty'));
    });

    test('defaults quantity to one when the column is missing', () {
      const text = 'Name,Set Code\nBolt,lea\n';
      expect(CollectionCsvReader.parse(text).rows.single.quantity, 1);
    });
  });

  group('finish parsing', () {
    test('covers the vocabulary services actually emit', () {
      expect(CollectionCsvReader.parseFinish(''), CardFinish.nonfoil);
      expect(CollectionCsvReader.parseFinish('nonfoil'), CardFinish.nonfoil);
      expect(CollectionCsvReader.parseFinish('normal'), CardFinish.nonfoil);
      expect(CollectionCsvReader.parseFinish('foil'), CardFinish.foil);
      expect(CollectionCsvReader.parseFinish('FOIL'), CardFinish.foil);
      expect(CollectionCsvReader.parseFinish('etched'), CardFinish.etched);
      expect(CollectionCsvReader.parseFinish('holo'), CardFinish.holofoil);
      expect(
        CollectionCsvReader.parseFinish('reverseholo'),
        CardFinish.reverseHolofoil,
      );
      expect(
        CollectionCsvReader.parseFinish('Reverse Holo'),
        CardFinish.reverseHolofoil,
      );
      expect(
        CollectionCsvReader.parseFinish('1st edition'),
        CardFinish.firstEdition,
      );
      expect(
        CollectionCsvReader.parseFinish('1st Edition Holo'),
        CardFinish.firstEditionHolofoil,
      );
    });

    test('does not mistake nonfoil for foil', () {
      expect(CollectionCsvReader.parseFinish('Non-Foil'), CardFinish.nonfoil);
    });
  });

  group('condition parsing', () {
    test('covers both grade vocabularies', () {
      expect(CollectionCsvReader.parseCondition('NM'), CardCondition.nearMint);
      expect(CollectionCsvReader.parseCondition('Near Mint'), CardCondition.nearMint);
      expect(CollectionCsvReader.parseCondition('M'), CardCondition.mint);
      expect(CollectionCsvReader.parseCondition('EX'), CardCondition.excellent);
      expect(CollectionCsvReader.parseCondition('GD'), CardCondition.good);
      expect(CollectionCsvReader.parseCondition('LP'), CardCondition.lightPlayed);
      expect(CollectionCsvReader.parseCondition('MP'), CardCondition.moderatelyPlayed);
      expect(CollectionCsvReader.parseCondition('HP'), CardCondition.heavilyPlayed);
      expect(CollectionCsvReader.parseCondition('PL'), CardCondition.played);
      expect(CollectionCsvReader.parseCondition('PO'), CardCondition.poor);
      expect(CollectionCsvReader.parseCondition('DMG'), CardCondition.damaged);
      expect(CollectionCsvReader.parseCondition(''), CardCondition.nearMint);
    });
  });

  group('money columns', () {
    test('reads plain, symboled and thousands-separated amounts', () {
      const text = 'Quantity,Name,Purchase Price\n'
          '1,Bolt,12.50\n'
          '1,Bolt,"\$1,234.56"\n'
          '1,Bolt,\n';
      final rows = CollectionCsvReader.parse(text).rows;
      expect(rows[0].purchasePrice, 12.50);
      expect(rows[1].purchasePrice, 1234.56);
      expect(rows[2].purchasePrice, isNull);
    });
  });

  group('date columns', () {
    test('reads ISO dates and American short dates', () {
      const text = 'Quantity,Name,Purchase Date\n'
          '1,Bolt,2024-01-31\n'
          '1,Bolt,1/31/2024\n'
          '1,Bolt,not a date\n';
      final rows = CollectionCsvReader.parse(text).rows;
      expect(rows[0].purchaseDate, DateTime(2024, 1, 31));
      expect(rows[1].purchaseDate, DateTime(2024, 1, 31));
      expect(rows[2].purchaseDate, isNull);
    });
  });

  group('CollectionCsvWriter', () {
    test('writes the Arcanum header with cost and value columns', () {
      final header = CollectionCsvWriter.header(TransferDialect.arcanum);
      expect(header, contains('card_id'));
      expect(header, contains('purchase_price'));
      expect(header, contains('market_value'));
      expect(header, contains('binder'));
    });

    test('writes a Moxfield-compatible row', () {
      final text = CollectionCsvWriter.build(TransferDialect.moxfield, [
        ExportRow(
          entry: _entry(quantity: 4, finish: CardFinish.foil, binder: 'Burn'),
          card: _card(),
          unitValue: 2.5,
        ),
      ]);
      final rows = Csv.parse(text);
      expect(rows.first.first, 'Count');
      expect(rows[1][0], '4');
      expect(rows[1][2], 'Lightning Bolt');
      expect(rows[1][3], 'LEA');
      expect(rows[1][4], 'NM');
      expect(rows[1][6], 'foil');
      expect(rows[1][8], '161');
    });

    test('round-trips through the reader without losing fidelity', () {
      final original = ExportRow(
        entry: _entry(
          quantity: 3,
          finish: CardFinish.foil,
          condition: CardCondition.lightPlayed,
          binder: 'Trade',
          price: 1.25,
        ),
        card: _card(),
      );
      final text = CollectionCsvWriter.build(TransferDialect.generic, [original]);
      final parsed = CollectionCsvReader.parse(text);

      expect(parsed.problems, isEmpty);
      final row = parsed.rows.single;
      expect(row.quantity, 3);
      expect(row.finish, CardFinish.foil);
      expect(row.condition, CardCondition.lightPlayed);
      expect(row.setCode, 'lea');
      expect(row.collectorNumber, '161');
      expect(row.purchasePrice, 1.25);
      expect(row.binder, 'Trade');
      expect(row.name, 'Lightning Bolt');
    });

    test('round-trips a name containing a comma', () {
      final text = CollectionCsvWriter.build(TransferDialect.moxfield, [
        ExportRow(
          entry: _entry(),
          card: _card(name: 'Nicol Bolas, the Ravager'),
        ),
      ]);
      expect(
        CollectionCsvReader.parse(text).rows.single.name,
        'Nicol Bolas, the Ravager',
      );
    });

    test('emits an empty cell rather than a zero for unknown values', () {
      final text = CollectionCsvWriter.build(TransferDialect.arcanum, [
        ExportRow(entry: _entry(), card: _card()),
      ]);
      final row = Csv.parse(text)[1];
      expect(row[10], ''); // purchase_price
      expect(row[14], ''); // market_value
      expect(row[15], ''); // total_value
    });
  });

  group('code round trip', () {
    // The Arcanum format stores the stable codes, and the reader has to turn
    // every one of them back into the enum it came from. If a code is ever
    // added without a matching reader rule, this catches it.
    for (final finish in CardFinish.values) {
      test('finish ${finish.code} survives export and import', () {
        final text = CollectionCsvWriter.build(TransferDialect.arcanum, [
          ExportRow(entry: _entry(finish: finish), card: _card()),
        ]);
        expect(CollectionCsvReader.parse(text).rows.single.finish, finish);
      });
    }

    for (final condition in CardCondition.values) {
      test('condition ${condition.code} survives export and import', () {
        final text = CollectionCsvWriter.build(TransferDialect.arcanum, [
          ExportRow(entry: _entry(condition: condition), card: _card()),
        ]);
        expect(
          CollectionCsvReader.parse(text).rows.single.condition,
          condition,
        );
      });
    }

    test('the Arcanum format is detected on the way back in', () {
      final text = CollectionCsvWriter.build(TransferDialect.arcanum, [
        ExportRow(entry: _entry(), card: _card()),
      ]);
      expect(
        CollectionCsvReader.parse(text).dialect,
        TransferDialect.arcanum,
      );
    });
  });
}
