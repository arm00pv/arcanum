import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/data/transfer/list_parser.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/data/repositories/catalog_repository.dart';
import 'package:arcanum/domain/models/tcg_card.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';

/// Imports a card list that was copied from somewhere else.
///
/// The CSV importer next door is for files. This is for the thing people
/// actually have: a list in a message, a deck page, a screenshot they typed
/// out by hand. Paste it, see exactly what Arcanum understood, and only then
/// decide to keep it - because a wrong printing imported silently is a wrong
/// collection that nobody notices for a year.
class PasteImportScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const PasteImportScreen({super.key});

  @override
  ConsumerState<PasteImportScreen> createState() => _PasteImportScreenState();
}

/// One line after the catalogue has been asked about it.
class _Resolved {
  const _Resolved({required this.entry, this.card});

  final ListEntry entry;

  /// The printing the line resolved to, or null when nothing matched.
  final TcgCard? card;

  bool get found => card != null;
}

class _PasteImportScreenState extends ConsumerState<PasteImportScreen> {
  final _controller = TextEditingController();
  List<_Resolved>? _resolved;
  bool _reading = false;
  bool _importing = false;
  int _progress = 0;
  int _total = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final game = ref.watch(activeGameProvider);
    final resolved = _resolved;
    final found = <_Resolved>[
      for (final r in resolved ?? const <_Resolved>[])
        if (r.found) r,
    ];
    final cards = found.fold<int>(
      0,
      (int a, _Resolved r) => a + r.entry.quantity,
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: game.accent),
              ),
            ),
          ),
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
            children: [
              SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Paste a list', style: context.t.titleLarge),
                            Text(
                              '${game.shortLabel} · one card per line',
                              style: context.t.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: TextField(
                  controller: _controller,
                  maxLines: 10,
                  minLines: 6,
                  keyboardType: TextInputType.multiline,
                  style: context.t.bodyMedium,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText:
                        '4 Lightning Bolt\n'
                        '4x Counterspell\n'
                        '1 Sol Ring (LTC) 284 *F*',
                  ),
                  onChanged: (_) {
                    if (_resolved != null) setState(() => _resolved = null);
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _reading ? null : () => _read(game),
                      icon: _reading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.search_rounded, size: 18),
                      label: Text(
                        _reading && _total > 0
                            ? 'Reading $_progress of $_total'
                            : 'Read the list',
                      ),
                    ),
                  ),
                ],
              ),
              if (resolved != null) ...[
                const SizedBox(height: 18),
                Text(
                  found.isEmpty
                      ? 'Nothing in that list was recognised.'
                      : '$cards card${cards == 1 ? '' : 's'} ready to add, '
                            'from ${found.length} '
                            '${found.length == 1 ? 'line' : 'lines'}.',
                  style: context.t.titleSmall,
                ),
                if (found.length < resolved.length) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${resolved.length - found.length} line'
                    '${resolved.length - found.length == 1 ? '' : 's'} '
                    'could not be matched to a printing.',
                    style: context.t.bodySmall?.copyWith(color: c.warning),
                  ),
                ],
                const SizedBox(height: 10),
                for (final r in resolved) _ResolvedRow(resolved: r),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: found.isEmpty || _importing
                      ? null
                      : () => _import(game, found),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: Text(
                    _importing ? 'Adding...' : 'Add $cards to my collection',
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Parses the text and asks the catalogue about every line.
  Future<void> _read(CardGame game) async {
    final parsed = parseList(_controller.text);
    if (parsed.isEmpty) {
      setState(() => _resolved = <_Resolved>[]);
      return;
    }
    setState(() {
      _reading = true;
      _progress = 0;
      _total = parsed.entries.length;
    });

    final catalog = ref.read(catalogRepositoryProvider);
    final out = <_Resolved>[];
    for (final entry in parsed.entries) {
      final card = await _resolve(catalog, game, entry);
      out.add(_Resolved(entry: entry, card: card));
      if (mounted) setState(() => _progress = out.length);
    }
    if (!mounted) return;
    setState(() {
      _resolved = out;
      _reading = false;
    });
  }

  /// Finds the printing a line meant.
  ///
  /// A set and number is the only address that cannot be wrong, so it is tried
  /// first. A name alone is guessed at as little as possible: an exact name
  /// match beats a fuzzy one, and a set code narrows the name before the whole
  /// catalogue is searched.
  Future<TcgCard?> _resolve(
    CatalogRepository catalog,
    CardGame game,
    ListEntry entry,
  ) async {
    final set = entry.setCode;
    final number = entry.collectorNumber;
    if (set != null && number != null) {
      final exact = await catalog.cardByNumber(game, set, number);
      if (exact != null) return exact;
    }
    if (set != null) {
      final inSet = await catalog.cardsByNameInSet(game, entry.name, set);
      if (inSet.isNotEmpty) return inSet.first;
    }
    final results = await catalog.search(game, entry.name);
    if (results.isEmpty) return null;
    final wanted = entry.name.toLowerCase();
    for (final card in results) {
      if (card.name.toLowerCase() == wanted) return card;
    }
    // A single fuzzy hit is taken; several are not, because picking one of
    // five printings at random is how a collection quietly goes wrong.
    final starts = results
        .where((TcgCard c) => c.name.toLowerCase().startsWith(wanted))
        .toList();
    if (starts.length == 1) return starts.first;
    return results.length == 1 ? results.first : null;
  }

  /// Adds every matched line to the collection.
  Future<void> _import(CardGame game, List<_Resolved> found) async {
    setState(() => _importing = true);
    final collection = ref.read(activeCollectionProvider);
    var added = 0;
    for (final r in found) {
      final card = r.card!;
      await collection.addCard(
        cardId: card.id,
        finish: r.entry.foil ? CardFinish.foil : CardFinish.nonfoil,
        condition: CardCondition.nearMint,
        language: 'en',
        quantity: r.entry.quantity,
        binder: '',
      );
      added += r.entry.quantity;
    }
    ref.invalidate(collectionOverviewProvider(game));
    ref.invalidate(ownedQuantityProvider(game));
    ref.invalidate(gameSummariesProvider);
    if (!mounted) return;
    setState(() {
      _importing = false;
      _resolved = null;
    });
    _controller.clear();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'Added $added card${added == 1 ? '' : 's'} to your '
            '${game.shortLabel} collection.',
          ),
        ),
      );
  }
}

/// One line of the preview.
class _ResolvedRow extends StatelessWidget {
  const _ResolvedRow({required this.resolved});

  final _Resolved resolved;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final card = resolved.card;
    final entry = resolved.entry;
    final where = card == null
        ? 'no printing matched'
        : '${card.setCode.toUpperCase()} #${card.collectorNumber}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 34,
                rarity: CardRarity.fromCode(card?.rarity),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  Text(
                    '$where${entry.foil ? '  ·  foil' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: card == null ? c.warning : c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              '${entry.quantity}${card == null ? '' : '×'}',
              style: context.t.titleSmall?.copyWith(
                color: card == null ? c.textTertiary : c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
