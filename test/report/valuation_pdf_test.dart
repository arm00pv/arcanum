// The printed report itself.
//
//   flutter test test/report/valuation_pdf_test.dart
//
// There is not much a PDF can be asked in a test - its streams are compressed -
// so these check the things that actually break: that a document is produced at
// all, that a collection of hundreds of stacks does not fall over, and that a
// card name outside Latin-1 does not bring the renderer down.

import 'dart:io';
import 'dart:typed_data';

import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/collection_entry.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/domain/report/valuation_report.dart';
import 'package:arcanum/data/report/valuation_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

/// The typeface the app ships, read from disk rather than from an asset bundle,
/// because a plain test has no bundle.
pw.Font testFont() {
  final Uint8List bytes = File('assets/fonts/Inter.ttf').readAsBytesSync();
  return pw.Font.ttf(ByteData.view(bytes.buffer));
}

ValuedEntry stack(int i, {String? name}) => ValuedEntry(
  entry: CollectionEntry(
    cardId: 'card-$i',
    quantity: 1 + (i % 3),
    purchasePrice: i.isEven ? 4.0 : null,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  ),
  unitValue: 1.0 + i,
  card: TcgCard(
    game: CardGame.mtg,
    id: 'card-$i',
    setCode: 'SET${i % 5}',
    setName: 'Set ${i % 5}',
    name: name ?? 'Card number $i',
    collectorNumber: '${100 + i}',
    rarity: 'rare',
  ),
);

ValuationReport reportOf(List<ValuedEntry> entries) => buildValuationReport(
  game: CardGame.mtg,
  entries: entries,
  generatedAt: DateTime(2026, 9, 14, 9, 30),
  priceAsOf: DateTime(2026, 9, 11),
);

void main() {
  test('a report becomes a PDF', () async {
    final Uint8List bytes = await renderValuationPdf(
      reportOf(<ValuedEntry>[stack(1), stack(2), stack(3)]),
      font: testFont(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(4000));
  });

  test('a whole collection prints, across as many pages as it takes', () async {
    final Uint8List bytes = await renderValuationPdf(
      reportOf(<ValuedEntry>[for (int i = 0; i < 400; i++) stack(i)]),
      font: testFont(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(20000));
  });

  test('an empty collection still makes a document', () async {
    final Uint8List bytes = await renderValuationPdf(
      reportOf(const <ValuedEntry>[]),
      font: testFont(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('a name outside Latin-1 does not stop the press', () async {
    final Uint8List bytes = await renderValuationPdf(
      reportOf(<ValuedEntry>[
        stack(1, name: 'Æther Vial'),
        stack(2, name: 'Blue-Eyes White Dragon · 青眼の白龍'),
        stack(3, name: 'Éowyn, Shieldmaiden'),
      ]),
      font: testFont(),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
