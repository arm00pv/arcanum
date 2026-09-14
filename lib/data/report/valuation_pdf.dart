import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/report/valuation_report.dart';

/// The app's own typeface, so a card name in any script has a chance of being
/// printed rather than dropped.
///
/// The PDF package's built-in faces are the old Type 1 ones, which know a few
/// hundred characters and throw on the rest; the asset the interface already
/// ships is a modern TrueType face and knows thousands.
Future<pw.Font> loadReportFont() async {
  final ByteData data = await rootBundle.load('assets/fonts/Inter.ttf');
  return pw.Font.ttf(data);
}

/// The colours the report is printed in. Dark ink on white, with a single
/// accent, because this is a document somebody may have to read on paper.
const PdfColor _ink = PdfColor.fromInt(0xFF17161C);
const PdfColor _quiet = PdfColor.fromInt(0xFF6B6A76);
const PdfColor _accent = PdfColor.fromInt(0xFF5B4BD6);
const PdfColor _rule = PdfColor.fromInt(0xFFE2E1E8);
const PdfColor _band = PdfColor.fromInt(0xFFF4F3F8);

/// Renders a valuation report as a PDF.
///
/// The typeface is handed in rather than loaded here, so the whole document can
/// be rendered in a test with no asset bundle in sight.
Future<Uint8List> renderValuationPdf(
  ValuationReport report, {
  required pw.Font font,
}) async {
  final pw.Document document = pw.Document(
    title: 'Arcanum valuation report',
    author: 'Arcanum',
    subject: '${report.game.label} collection valuation',
    creator: 'Arcanum',
  );
  final pw.ThemeData theme = pw.ThemeData.withFont(base: font);

  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 40, 36, 44),
      theme: theme,
      header: (pw.Context context) =>
          context.pageNumber == 1 ? pw.SizedBox() : _runningHead(report),
      footer: (pw.Context context) => _foot(report, context),
      build: (pw.Context context) => <pw.Widget>[
        _title(report),
        pw.SizedBox(height: 18),
        _summary(report),
        pw.SizedBox(height: 22),
        ..._tables(report),
        pw.SizedBox(height: 16),
        _totals(report),
        pw.SizedBox(height: 22),
        _caveats(report),
      ],
    ),
  );

  return document.save();
}

/// The masthead: what this is, whose it is, and when it was made.
pw.Widget _title(ValuationReport report) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: <pw.Widget>[
    pw.Text(
      'ARCANUM',
      style: const pw.TextStyle(
        color: _accent,
        fontSize: 10,
        letterSpacing: 2.4,
      ),
    ),
    pw.SizedBox(height: 6),
    pw.Text(
      'Valuation report',
      style: const pw.TextStyle(color: _ink, fontSize: 26),
    ),
    pw.SizedBox(height: 4),
    pw.Text(
      '${report.game.label} collection · prepared ${Fmt.date(report.generatedAt)}',
      style: const pw.TextStyle(color: _quiet, fontSize: 11),
    ),
  ],
);

/// The headline figures, as a two-column list.
pw.Widget _summary(ValuationReport report) => pw.Container(
  padding: const pw.EdgeInsets.all(14),
  decoration: pw.BoxDecoration(
    color: _band,
    borderRadius: pw.BorderRadius.circular(6),
  ),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: <pw.Widget>[
      pw.Text(
        'Summary',
        style: const pw.TextStyle(
          color: _accent,
          fontSize: 10,
          letterSpacing: 1.2,
        ),
      ),
      pw.SizedBox(height: 8),
      for (final (String label, String value) in report.summary)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text(
                label,
                style: const pw.TextStyle(color: _quiet, fontSize: 11),
              ),
              pw.Text(
                value,
                style: const pw.TextStyle(color: _ink, fontSize: 11),
              ),
            ],
          ),
        ),
    ],
  ),
);

/// One table per set, richest set first.
List<pw.Widget> _tables(ValuationReport report) {
  final List<pw.Widget> widgets = <pw.Widget>[];
  if (report.lines.isEmpty) {
    widgets.add(
      pw.Text(
        'There is nothing in this collection to value yet.',
        style: const pw.TextStyle(color: _quiet, fontSize: 11),
      ),
    );
    return widgets;
  }
  widgets.add(
    pw.Text(
      'What is held',
      style: const pw.TextStyle(
        color: _accent,
        fontSize: 10,
        letterSpacing: 1.2,
      ),
    ),
  );
  widgets.add(pw.SizedBox(height: 8));
  for (final ValuationSection section in report.sections) {
    widgets.add(_sectionHead(section));
    widgets.add(pw.SizedBox(height: 4));
    widgets.add(_sectionTable(section));
    widgets.add(pw.SizedBox(height: 16));
  }
  return widgets;
}

pw.Widget _sectionHead(ValuationSection section) => pw.Row(
  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
  crossAxisAlignment: pw.CrossAxisAlignment.end,
  children: <pw.Widget>[
    pw.Expanded(
      child: pw.Text(
        section.title,
        style: const pw.TextStyle(color: _ink, fontSize: 13),
      ),
    ),
    pw.Text(
      '${Fmt.count(section.cards)} '
      '${section.cards == 1 ? 'card' : 'cards'} · ${Fmt.money(section.subtotal)}',
      style: const pw.TextStyle(color: _quiet, fontSize: 10),
    ),
  ],
);

pw.Widget _sectionTable(ValuationSection section) => pw.Table(
  columnWidths: const <int, pw.TableColumnWidth>{
    0: pw.FlexColumnWidth(1),
    1: pw.FixedColumnWidth(38),
    2: pw.FixedColumnWidth(64),
    3: pw.FixedColumnWidth(72),
  },
  children: <pw.TableRow>[
    pw.TableRow(
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _rule)),
      ),
      children: <pw.Widget>[
        _head('Card'),
        _head('Qty', align: pw.TextAlign.right),
        _head('Each', align: pw.TextAlign.right),
        _head('Value', align: pw.TextAlign.right),
      ],
    ),
    for (int i = 0; i < section.lines.length; i++)
      _row(section.lines[i], banded: i.isOdd),
  ],
);

pw.Widget _head(String text, {pw.TextAlign align = pw.TextAlign.left}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4, top: 2),
      child: pw.Text(
        text.toUpperCase(),
        textAlign: align,
        style: const pw.TextStyle(
          color: _quiet,
          fontSize: 8,
          letterSpacing: 1.1,
        ),
      ),
    );

pw.TableRow _row(ValuationLine line, {required bool banded}) => pw.TableRow(
  decoration: pw.BoxDecoration(
    color: banded ? _band : null,
    border: const pw.Border(bottom: pw.BorderSide(color: _rule, width: 0.5)),
  ),
  children: <pw.Widget>[
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.Text(
            line.name,
            style: const pw.TextStyle(color: _ink, fontSize: 10),
          ),
          pw.SizedBox(height: 1),
          pw.Text(
            '${line.identity} · ${line.description}',
            style: const pw.TextStyle(color: _quiet, fontSize: 8),
          ),
        ],
      ),
    ),
    _cell(Fmt.count(line.quantity), pw.TextAlign.right),
    _cell(Fmt.money(line.unitValue), pw.TextAlign.right),
    _cell(Fmt.money(line.totalValue), pw.TextAlign.right, strong: true),
  ],
);

pw.Widget _cell(String text, pw.TextAlign align, {bool strong = false}) =>
    pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 2),
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(color: strong ? _ink : _quiet, fontSize: 10),
      ),
    );

/// What the listed rows come to, and what the whole collection comes to.
pw.Widget _totals(ValuationReport report) {
  final double listed = report.lines.fold(
    0.0,
    (double sum, ValuationLine line) => sum + (line.totalValue ?? 0),
  );
  final List<(String, String)> rows = <(String, String)>[
    ('Listed above', Fmt.money(listed)),
    ('Whole collection', Fmt.money(report.totalValue)),
    if (report.totalCost != null) ('Paid', Fmt.money(report.totalCost)),
    if (report.totalCost != null)
      ('Unrealised', Fmt.moneySigned(report.unrealised)),
  ];
  return pw.Container(
    padding: const pw.EdgeInsets.only(top: 10),
    decoration: const pw.BoxDecoration(
      border: pw.Border(top: pw.BorderSide(color: _ink, width: 1.2)),
    ),
    child: pw.Column(
      children: <pw.Widget>[
        for (final (String label, String value) in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: <pw.Widget>[
                pw.Text(
                  label,
                  style: const pw.TextStyle(color: _quiet, fontSize: 11),
                ),
                pw.Text(
                  value,
                  style: const pw.TextStyle(color: _ink, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// The part of the report that keeps it honest.
pw.Widget _caveats(ValuationReport report) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: <pw.Widget>[
    pw.Text(
      'What this report does not know',
      style: const pw.TextStyle(
        color: _accent,
        fontSize: 10,
        letterSpacing: 1.2,
      ),
    ),
    pw.SizedBox(height: 6),
    for (final String note in report.caveats)
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Container(
              margin: const pw.EdgeInsets.only(top: 4, right: 6),
              width: 3,
              height: 3,
              decoration: const pw.BoxDecoration(
                color: _quiet,
                shape: pw.BoxShape.circle,
              ),
            ),
            pw.Expanded(
              child: pw.Text(
                note,
                style: const pw.TextStyle(color: _quiet, fontSize: 9),
              ),
            ),
          ],
        ),
      ),
  ],
);

pw.Widget _runningHead(ValuationReport report) => pw.Container(
  margin: const pw.EdgeInsets.only(bottom: 14),
  padding: const pw.EdgeInsets.only(bottom: 6),
  decoration: const pw.BoxDecoration(
    border: pw.Border(bottom: pw.BorderSide(color: _rule)),
  ),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: <pw.Widget>[
      pw.Text(
        'Arcanum valuation report',
        style: const pw.TextStyle(color: _quiet, fontSize: 8),
      ),
      pw.Text(
        '${report.game.label} · ${Fmt.date(report.generatedAt)}',
        style: const pw.TextStyle(color: _quiet, fontSize: 8),
      ),
    ],
  ),
);

pw.Widget _foot(ValuationReport report, pw.Context context) => pw.Container(
  margin: const pw.EdgeInsets.only(top: 12),
  padding: const pw.EdgeInsets.only(top: 6),
  decoration: const pw.BoxDecoration(
    border: pw.Border(top: pw.BorderSide(color: _rule)),
  ),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: <pw.Widget>[
      pw.Text(
        report.priceAsOf == null
            ? 'Made on this device'
            : 'Prices last refreshed ${Fmt.date(report.priceAsOf)}',
        style: const pw.TextStyle(color: _quiet, fontSize: 8),
      ),
      pw.Text(
        'Page ${context.pageNumber} of ${context.pagesCount}',
        style: const pw.TextStyle(color: _quiet, fontSize: 8),
      ),
    ],
  ),
);
