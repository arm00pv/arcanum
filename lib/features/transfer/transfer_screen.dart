import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/data/transfer/collection_transfer.dart';
import 'package:arcanum/data/transfer/import_service.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/data/repositories/collection_repository.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/common.dart';
import 'package:arcanum/widgets/glass.dart';

/// Import and export the active game's collection as CSV.
///
/// Every serious collection app has to interoperate, and the practical format
/// is CSV: Moxfield, Archidekt, TCGplayer and every spreadsheet all speak it.
/// Export writes a file shaped for the chosen service; import reads whatever
/// the user has, matches each row to a real printing, shows what it intends to
/// do, and only then writes anything.
///
/// The whole screen is scoped to the active game, so a Pokemon file can never
/// land in the Magic collection.
class TransferScreen extends ConsumerStatefulWidget {
  /// Creates the transfer screen.
  const TransferScreen({super.key});

  @override
  ConsumerState<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends ConsumerState<TransferScreen> {
  TransferDialect _dialect = TransferDialect.arcanum;

  /// True while a file is being read, matched or written.
  bool _busy = false;

  /// The file the user chose, for the summary line.
  String? _fileName;

  /// The parsed file, then the matched plan, then the result. Each step
  /// replaces the last so the screen always shows the furthest known state.
  ParsedCollection? _parsed;
  ImportPlan? _plan;
  ImportOutcome? _outcome;

  /// Set when something went wrong at the file level rather than per row.
  String? _error;

  @override
  Widget build(BuildContext context) {
    final CardGame game = ref.watch(activeGameProvider);

    return Scaffold(
      appBar: GlassAppBar(
        title: Text('Import & export', style: context.t.headlineSmall),
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 120),
        children: <Widget>[
          SectionHeader(
            title: 'Export',
            subtitle: 'Write your ${game.shortLabel} collection to a file',
          ),
          _export(context, game),
          SectionHeader(
            title: 'Import',
            subtitle: 'Read a file into your ${game.shortLabel} collection',
          ),
          _import(context, game),
          const SectionHeader(
            title: 'Formats',
            subtitle: 'What Arcanum can read and write',
          ),
          _formats(context),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ export

  Widget _export(BuildContext context, CardGame game) {
    final c = context.c;
    final overview = ref.watch(collectionOverviewProvider(game));

    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Format', style: context.t.titleSmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final dialect in TransferDialect.values)
                ChoiceChip(
                  label: Text(dialect.label),
                  selected: _dialect == dialect,
                  onSelected: _busy
                      ? null
                      : (bool selected) {
                          if (selected) setState(() => _dialect = dialect);
                        },
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _dialect.description,
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: c.hairline),
          const SizedBox(height: 16),
          overview.when(
            data: (CollectionOverview data) => Text(
              data.isEmpty
                  ? 'There is nothing to export yet.'
                  : 'This writes ${Fmt.count(data.entries.length)} stacks, '
                        '${Fmt.count(data.totalCards)} cards, worth '
                        '${Fmt.moneyAdaptive(data.totalValue)}.',
              style: context.t.bodySmall?.copyWith(color: c.textSecondary),
            ),
            loading: () => const LoadingShimmer(width: 220, height: 14),
            error: (Object error, StackTrace stackTrace) => Text(
              'Could not read your collection.',
              style: context.t.bodySmall?.copyWith(color: c.negative),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : () => _exportCollection(game),
            icon: const Icon(Icons.ios_share_rounded, size: 18),
            label: const Text('Share as CSV'),
          ),
        ],
      ),
    );
  }

  /// Builds the file and hands it to the system share sheet.
  ///
  /// A share sheet rather than a fixed path, because on Android the useful
  /// destination is usually Drive, a chat app or email rather than the
  /// filesystem.
  Future<void> _exportCollection(CardGame game) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final overview = await ref.read(collectionOverviewProvider(game).future);
      if (overview.isEmpty) {
        throw StateError('there is nothing to export yet');
      }
      final cards = await ref.read(ownedCardsProvider(game).future);

      final rows = <ExportRow>[
        for (final valued in overview.entries)
          ExportRow(
            entry: valued.entry,
            card: cards[valued.entry.cardId],
            unitValue: valued.unitValue,
          ),
      ];

      final csvText = CollectionCsvWriter.build(_dialect, rows);
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().substring(0, 10);
      final name = 'arcanum-${game.id}-$stamp.csv';
      final path = dir.path + Platform.pathSeparator + name;
      await File(path).writeAsString(csvText, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(path, mimeType: 'text/csv')],
          subject: 'Arcanum ${game.shortLabel} collection',
        ),
      );

      if (!mounted) return;
      _snack('Exported ${Fmt.count(rows.length)} stacks.');
    } catch (error) {
      if (!mounted) return;
      _snack('Could not export: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ import

  Widget _import(BuildContext context, CardGame game) {
    final c = context.c;
    final plan = _plan;

    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Choose a CSV exported from Moxfield, Archidekt, TCGplayer or a '
            'spreadsheet. Arcanum matches every row to a real printing and '
            'shows you what it found before anything is saved.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: _busy ? null : _chooseFile,
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: Text(_fileName ?? 'Choose a CSV file'),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: context.t.bodySmall?.copyWith(color: c.negative),
            ),
          ],
          if (plan != null) ...<Widget>[
            const SizedBox(height: 16),
            Divider(height: 1, color: c.hairline),
            const SizedBox(height: 16),
            _planSummary(context, plan),
            if (plan.problems.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              _problems(context, plan.problems),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy || plan.ready.isEmpty
                  ? null
                  : () => _apply(game),
              icon: const Icon(Icons.download_done_rounded, size: 18),
              label: Text(
                plan.ready.isEmpty
                    ? 'Nothing to import'
                    : 'Import ${Fmt.count(plan.totalCards)} cards',
              ),
            ),
          ],
          if (_outcome != null) ...<Widget>[
            const SizedBox(height: 16),
            _outcomeBox(context, _outcome!),
          ],
        ],
      ),
    );
  }

  Widget _planSummary(BuildContext context, ImportPlan plan) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Ready to import', style: context.t.titleSmall),
        const SizedBox(height: 10),
        _Fact(
          icon: Icons.style_rounded,
          label: 'Cards',
          value: Fmt.count(plan.totalCards),
        ),
        const SizedBox(height: 8),
        _Fact(
          icon: Icons.add_rounded,
          label: 'New stacks',
          value: Fmt.count(plan.creating),
        ),
        if (plan.merging > 0) ...<Widget>[
          const SizedBox(height: 8),
          _Fact(
            icon: Icons.merge_rounded,
            label: 'Added to stacks you already have',
            value: Fmt.count(plan.merging),
          ),
        ],
        if (plan.needingReview > 0) ...<Widget>[
          const SizedBox(height: 8),
          _Fact(
            icon: Icons.help_outline_rounded,
            label: 'Printing guessed from the name',
            value: Fmt.count(plan.needingReview),
            warn: true,
          ),
        ],
        if (plan.knownCost != null) ...<Widget>[
          const SizedBox(height: 8),
          _Fact(
            icon: Icons.payments_rounded,
            label: 'Cost basis in the file',
            value: Fmt.moneyAdaptive(plan.knownCost),
          ),
        ],
        if (_parsed != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'Read as ${_parsed!.dialect.label}.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ],
    );
  }

  Widget _problems(BuildContext context, List<ImportProblem> problems) {
    final c = context.c;
    // Only the first few are shown: a badly mismatched file can produce
    // hundreds, and a wall of text is worse than a count.
    final shown = problems.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          problems.length == 1
              ? '1 row needs attention'
              : '${Fmt.count(problems.length)} rows need attention',
          style: context.t.titleSmall?.copyWith(color: c.warning),
        ),
        const SizedBox(height: 8),
        for (final problem in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '- ${problem.describe}',
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
          ),
        if (problems.length > shown.length)
          Text(
            'and ${Fmt.count(problems.length - shown.length)} more.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
      ],
    );
  }

  Widget _outcomeBox(BuildContext context, ImportOutcome outcome) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (outcome.ok ? c.positive : c.warning).withValues(alpha: 0.10),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            outcome.ok ? 'Import complete' : 'Import finished with problems',
            style: context.t.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            '${Fmt.count(outcome.cardsAdded)} cards added across '
            '${Fmt.count(outcome.stacksCreated)} new stacks and '
            '${Fmt.count(outcome.stacksMerged)} existing ones.',
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
          for (final failure in outcome.failures.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '- ${failure.describe}',
                style: context.t.bodySmall?.copyWith(color: c.textTertiary),
              ),
            ),
        ],
      ),
    );
  }

  /// Opens the system file picker, parses what comes back and plans the import.
  Future<void> _chooseFile() async {
    setState(() {
      _busy = true;
      _error = null;
      _plan = null;
      _outcome = null;
    });

    try {
      final file = await FilePicker.pickFile(
        dialogTitle: 'Choose a collection CSV',
        type: FileType.custom,
        allowedExtensions: <String>['csv', 'txt', 'tsv'],
      );
      // A null result means the user backed out, which is not an error.
      if (file == null) return;
      final bytes = await file.readAsBytes();

      // Files written by spreadsheets are not always valid UTF-8, so malformed
      // bytes are tolerated rather than losing a whole import to one character.
      final parsed = CollectionCsvReader.parse(
        utf8.decode(bytes, allowMalformed: true),
      );

      final importer = CollectionImporter(
        collection: ref.read(activeCollectionProvider),
        catalogs: ref.read(catalogRepositoryProvider),
      );
      final plan = await importer.plan(parsed);

      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _parsed = parsed;
        _plan = plan;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not read that file: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Writes the plan into the collection.
  Future<void> _apply(CardGame game) async {
    final plan = _plan;
    if (plan == null) return;
    setState(() => _busy = true);

    try {
      final importer = CollectionImporter(
        collection: ref.read(activeCollectionProvider),
        catalogs: ref.read(catalogRepositoryProvider),
      );
      final outcome = await importer.apply(plan);

      // Everything downstream of the collection is now stale.
      ref.invalidate(collectionOverviewProvider(game));
      ref.invalidate(ownedQuantityProvider(game));
      ref.invalidate(ownedBySetProvider(game));
      ref.invalidate(ownedCardsProvider(game));
      ref.invalidate(gameSummariesProvider);
      ref.invalidate(portfolioSeriesProvider(game));

      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _plan = null;
        _parsed = null;
      });
    } catch (error) {
      if (!mounted) return;
      _snack('Import failed: $error', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ----------------------------------------------------------------- formats

  Widget _formats(BuildContext context) {
    final c = context.c;
    return _group(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final dialect in TransferDialect.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(dialect.label, style: context.t.titleSmall),
                  Text(
                    dialect.description,
                    style: context.t.bodySmall?.copyWith(color: c.textTertiary),
                  ),
                ],
              ),
            ),
          Divider(height: 1, color: c.hairline),
          const SizedBox(height: 12),
          Text(
            'Matching is exact. A row that names a set and a collector number '
            'is matched to that printing. A row that gives only a name is '
            'matched to the newest printing of that name and flagged, because '
            'the file did not say which printing you own. A row that matches '
            'nothing is reported and never guessed at.',
            style: context.t.bodySmall?.copyWith(color: c.textTertiary),
          ),
        ],
      ),
    );
  }

  /// A grouped glass block: 20px radius, 16px padding, 20px page gutters.
  Widget _group({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: GlassCard(
        radius: 20,
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  void _snack(String message, {bool error = false}) {
    final ArcanumColors c = context.c;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? c.negative : null,
      ),
    );
  }
}

/// A labelled figure with an icon, used for the plan summary.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: warn ? c.warning : c.textTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.bodySmall?.copyWith(color: c.textSecondary),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: context.t.titleSmall?.copyWith(color: warn ? c.warning : null),
        ),
      ],
    );
  }
}
