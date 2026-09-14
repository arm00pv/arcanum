import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/report/valuation_pdf.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/report/valuation_report.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// Builds the valuation report and hands it over as a PDF.
///
/// The screen does not print anything itself: it shows what the report will say,
/// including the parts of it that are about what the figures cannot see, and
/// then makes the file. A report is a document somebody else reads, so the last
/// thing it should do is surprise the person who made it.
class ValuationReportScreen extends ConsumerStatefulWidget {
  /// Creates the report screen.
  const ValuationReportScreen({super.key});

  @override
  ConsumerState<ValuationReportScreen> createState() =>
      _ValuationReportScreenState();
}

/// How much of the collection the report lists.
enum _Breadth {
  /// Every stack.
  everything('Everything'),

  /// The hundred most valuable, for a certificate that has to fit a page.
  topHundred('The 100 dearest');

  const _Breadth(this.label);

  final String label;

  int? get limit => this == _Breadth.everything ? null : 100;
}

class _ValuationReportScreenState extends ConsumerState<ValuationReportScreen> {
  late CardGame _game;
  _Breadth _breadth = _Breadth.everything;
  bool _building = false;

  @override
  void initState() {
    super.initState();
    _game = ref.read(activeGameProvider);
  }

  /// The report as it would be printed right now, or null while the collection
  /// is still being read.
  ValuationReport? _report(AsyncValue<CollectionOverview> overview) {
    final CollectionOverview? data = overview.value;
    if (data == null) return null;
    return buildValuationReport(
      game: _game,
      entries: data.entries,
      priceAsOf: ref.watch(pricesAsOfProvider(_game)).value,
      maxLines: _breadth.limit,
      setNames: <String, String>{
        for (final MapEntry<String, double> entry in data.valueBySet.entries)
          entry.key.toUpperCase(): entry.key,
      },
    );
  }

  Future<void> _share(ValuationReport report) async {
    setState(() => _building = true);
    try {
      final font = await loadReportFont();
      final bytes = await renderValuationPdf(report, font: font);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final path =
          '${dir.path}${Platform.pathSeparator}'
          'arcanum-valuation-${_game.tag}-$stamp.pdf';
      await File(path).writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(path, mimeType: 'application/pdf')],
          subject: 'Arcanum valuation - ${_game.label}',
        ),
      );
      if (!mounted) return;
      _snack('Report made: ${Fmt.count(report.totalCards)} cards.');
    } catch (error) {
      if (!mounted) return;
      _snack('Could not make the report: $error', error: true);
    } finally {
      if (mounted) setState(() => _building = false);
    }
  }

  void _snack(String message, {bool error = false}) {
    final c = context.c;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? c.negative : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final AsyncValue<CollectionOverview> overview = ref.watch(
      collectionOverviewProvider(_game),
    );
    final ValuationReport? report = _report(overview);

    return Scaffold(
      appBar: AppBar(
        title: Text('Valuation report', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: <Widget>[
          const SectionHeader(
            title: 'What to report',
            subtitle: 'One vault at a time, valued against its own prices',
          ),
          _group(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Collection', style: context.t.titleSmall),
                const SizedBox(height: 10),
                PillToggle(
                  options: <String>[
                    for (final CardGame game in CardGame.values)
                      game.shortLabel,
                  ],
                  selected: CardGame.values.indexOf(_game),
                  semanticLabel: 'Which collection to report',
                  onChanged: (int index) => setState(() {
                    _game = CardGame.values[index];
                    _breadth = _Breadth.everything;
                  }),
                ),
                const SizedBox(height: 18),
                Text('How much of it', style: context.t.titleSmall),
                const SizedBox(height: 10),
                PillToggle(
                  options: <String>[
                    for (final _Breadth breadth in _Breadth.values)
                      breadth.label,
                  ],
                  selected: _Breadth.values.indexOf(_breadth),
                  semanticLabel: 'How much of the collection to list',
                  onChanged: (int index) =>
                      setState(() => _breadth = _Breadth.values[index]),
                ),
                const SizedBox(height: 10),
                Text(
                  'Either way the totals describe the whole collection, and the '
                  'report says which rows were left out.',
                  style: context.t.labelSmall?.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (report == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...<Widget>[
            const SectionHeader(
              title: 'What it will say',
              subtitle: 'Read this before it goes anywhere',
            ),
            _summary(report),
            if (report.lines.isNotEmpty) ...<Widget>[
              const SectionHeader(title: 'The dearest stacks'),
              _preview(report),
            ],
            const SectionHeader(
              title: 'What it does not know',
              subtitle: 'Printed on the report, in these words',
            ),
            _caveats(report),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
              child: FilledButton.icon(
                onPressed: _building ? null : () => _share(report),
                icon: _building
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.picture_as_pdf_rounded, size: 18),
                label: Text(_building ? 'Making the PDF...' : 'Make the PDF'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                'The file opens in whatever you use for PDFs, and the share '
                'sheet will send it to a printer, to Drive, or to whoever '
                'asked for it.',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary(ValuationReport report) => _group(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String label, String value) in report.summary)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  label,
                  style: context.t.bodySmall?.copyWith(
                    color: context.c.textSecondary,
                  ),
                ),
                Text(value, style: context.t.titleSmall),
              ],
            ),
          ),
      ],
    ),
  );

  /// The first few rows, so the shape of the document is visible before the file
  /// exists.
  Widget _preview(ValuationReport report) {
    final c = context.c;
    final List<ValuationLine> head = report.lines.take(6).toList();
    return _group(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: <Widget>[
          for (final ValuationLine line in head)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          line.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodyMedium,
                        ),
                        Text(
                          '${line.identity} · ${Fmt.count(line.quantity)} × '
                          '${Fmt.money(line.unitValue)}',
                          style: context.t.labelSmall?.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(Fmt.money(line.totalValue), style: context.t.titleSmall),
                ],
              ),
            ),
          if (report.lines.length > head.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'and ${Fmt.count(report.lines.length - head.length)} more rows '
                'in the file.',
                style: context.t.labelSmall?.copyWith(color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _caveats(ValuationReport report) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final String note in report.caveats)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 7, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.textTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      note,
                      style: context.t.bodySmall?.copyWith(
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A grouped glass block: 20px radius, 16px padding, 20px page gutters.
  Widget _group({required Widget child, EdgeInsetsGeometry? padding}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: GlassCard(
          radius: 20,
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      );
}
