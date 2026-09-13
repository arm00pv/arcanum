import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/core/theme/mana.dart';
import 'package:arcanum/core/utils/formatters.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_check.dart';
import 'package:arcanum/domain/decks/deck_format.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/features/card/card_detail_screen.dart';
import 'package:arcanum/features/decks/deck_card_picker.dart';
import 'package:arcanum/features/decks/deck_form.dart';
import 'package:arcanum/providers.dart';
import 'package:arcanum/widgets/card_thumbnail.dart';
import 'package:arcanum/widgets/glass.dart';
import 'package:arcanum/widgets/sliver_async.dart';

/// One deck: what is in it, what it is worth, and whether it is legal.
class DeckDetailScreen extends ConsumerStatefulWidget {
  /// Creates the screen for one deck.
  const DeckDetailScreen({super.key, required this.deckId});

  /// The deck's row id.
  final int deckId;

  @override
  ConsumerState<DeckDetailScreen> createState() => _DeckDetailScreenState();
}

class _DeckDetailScreenState extends ConsumerState<DeckDetailScreen> {
  final _scrollController = ScrollController();
  double _scrollOffset = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final o = _scrollController.offset;
      if ((o - _scrollOffset).abs() > 4) setState(() => _scrollOffset = o);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final async = ref.watch(deckProvider(widget.deckId));
    final DeckContents? contents = async.value;
    final CardGame game = contents?.deck.game ?? ref.watch(activeGameProvider);
    final owned =
        ref.watch(ownedQuantityProvider(game)).value ?? const <String, int>{};

    // A null banned list means the format's was never fetched, which the check
    // reports as 'not checked' rather than as 'nothing is banned'.
    final bans = contents == null
        ? null
        : ref.watch(banListProvider(contents.deck.formatId)).value;
    final check = contents == null
        ? null
        : checkDeck(
            contents,
            bannedNames: bans?.names ?? const <String>{},
            banListChecked: bans != null,
          );

    return Scaffold(
      floatingActionButton: contents == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      DeckCardPicker(deckId: widget.deckId, game: game),
                ),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add cards'),
            ),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: AppTheme.backdrop(c, tint: game.accent),
              ),
            ),
          ),
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverToBoxAdapter(
                child: GlassAppBar(
                  scrollOffset: _scrollOffset,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        contents?.deck.name ?? 'Deck',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.t.titleLarge,
                      ),
                      if (contents != null)
                        Text(
                          _subtitle(contents, owned),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.t.bodySmall,
                        ),
                    ],
                  ),
                  actions: [
                    if (contents != null)
                      PopupMenuButton<String>(
                        onSelected: (String choice) =>
                            _menu(context, ref, contents, choice),
                        itemBuilder: (BuildContext context) =>
                            const <PopupMenuEntry<String>>[
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: Text('Name and format'),
                              ),
                              PopupMenuItem<String>(
                                value: 'want',
                                child: Text('Want what is missing'),
                              ),
                              PopupMenuItem<String>(
                                value: 'clear',
                                child: Text('Empty the deck'),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Text('Delete the deck'),
                              ),
                            ],
                      ),
                  ],
                ),
              ),
              SliverAsyncView<DeckContents?>(
                value: async,
                loadingHeight: 420,
                onRetry: () => ref.invalidate(deckProvider(widget.deckId)),
                isEmpty: (DeckContents? value) => value == null,
                emptyIcon: Icons.style_outlined,
                emptyTitle: 'Deck not found',
                emptyMessage: 'It may have been deleted.',
                builder: (DeckContents? value) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 140),
                  sliver: SliverList.list(
                    children: [
                      _Summary(contents: value!, owned: owned),
                      if (check != null) ...[
                        const SizedBox(height: 12),
                        _Legality(result: check),
                      ],
                      for (final board in DeckBoard.values)
                        if (_shows(value, board)) ...[
                          const SizedBox(height: 18),
                          _BoardSection(
                            board: board,
                            contents: value,
                            owned: owned,
                            format: value.deck.format,
                          ),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Whether a board is worth a heading: one that holds cards, or one the
  /// format expects to be filled.
  static bool _shows(DeckContents contents, DeckBoard board) {
    if (contents.board(board).isNotEmpty) return true;
    final format = contents.deck.format;
    if (format == null) return false;
    return switch (board) {
      DeckBoard.commander => format.hasCommander,
      DeckBoard.side => format.hasSideboard,
      DeckBoard.main => false,
    };
  }

  static String _subtitle(DeckContents contents, Map<String, int> owned) {
    final format = contents.deck.format;
    final target = format?.minCards ?? 0;
    final size = contents.size;
    final parts = <String>[
      contents.deck.formatLabel,
      target > 0 ? '$size/$target cards' : '$size cards',
      Fmt.moneyCompact(contents.value),
    ];
    final missing = contents.missingWith(owned);
    if (missing > 0) parts.add('$missing to buy');
    return parts.join('  ·  ');
  }

  /// Handles the overflow menu.
  Future<void> _menu(
    BuildContext context,
    WidgetRef ref,
    DeckContents contents,
    String choice,
  ) async {
    final repository = ref.read(deckRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    switch (choice) {
      case 'edit':
        await editDeck(context, ref, contents.deck);
      case 'want':
        final owned = ref.read(ownedQuantityProvider(contents.deck.game)).value;
        final missing = <String>[
          for (final entry in contents.entries)
            if (entry.missingWith(owned ?? const <String, int>{}) > 0)
              entry.cardId,
        ];
        if (missing.isEmpty) {
          messenger.showSnackBar(
            const SnackBar(content: Text('You already own every card here.')),
          );
          return;
        }
        final added = await ref
            .read(wantedDaoProvider)
            .addAll(contents.deck.game, missing);
        ref.read(wantedRevisionProvider.notifier).bump();
        messenger.showSnackBar(
          SnackBar(content: Text('Added $added cards to your wants.')),
        );
      case 'clear':
        final ok = await _confirm(
          context,
          'Empty ${contents.deck.name}?',
          'Every card comes out of the deck. Your collection is not touched.',
          'Empty it',
        );
        if (ok) await repository.clear(contents.deck.id);
        ref.read(deckRevisionProvider.notifier).bump();
      case 'delete':
        final gone = await confirmDeleteDeck(context, ref, contents.deck);
        if (gone && context.mounted) Navigator.of(context).maybePop();
    }
  }

  static Future<bool> _confirm(
    BuildContext context,
    String title,
    String message,
    String action,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

/// The headline: how full the deck is, what it is worth, what is left to buy.
class _Summary extends StatelessWidget {
  const _Summary({required this.contents, required this.owned});

  final DeckContents contents;
  final Map<String, int> owned;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final format = contents.deck.format;
    final target = format?.minCards ?? 0;
    final size = contents.size;
    final missing = contents.missingWith(owned);
    final complete = target > 0 && size >= target;
    final missingLabel = missing == 0
        ? 'None'
        : '$missing card${missing == 1 ? '' : 's'}';

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  target > 0 ? '$size of $target cards' : '$size cards',
                  style: context.t.titleMedium,
                ),
              ),
              Text(
                Fmt.moneyCompact(contents.value),
                style: context.t.titleMedium?.copyWith(color: c.gold),
              ),
            ],
          ),
          if (target > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (size / target).clamp(0.0, 1.0),
                minHeight: 6,
                backgroundColor: c.hairline,
                valueColor: AlwaysStoppedAnimation<Color>(
                  complete ? c.positive : c.accent,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _Stat(
                label: 'To buy',
                value: missingLabel,
                colour: missing == 0 ? c.positive : c.warning,
              ),
              _Stat(
                label: 'Cost to finish',
                value: Fmt.moneyCompact(contents.missingValue),
                colour: c.textPrimary,
              ),
              _Stat(
                label: 'Distinct',
                value: '${contents.uniqueCards}',
                colour: c.textPrimary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One figure in the summary row.
class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.colour});

  final String label;
  final String value;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.t.labelSmall?.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.t.titleSmall?.copyWith(color: colour),
          ),
        ],
      ),
    );
  }
}

/// What the format check found, including what it could not check.
class _Legality extends StatelessWidget {
  const _Legality({required this.result});

  final DeckCheckResult result;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final issues = result.issues;
    final headline = issues.isEmpty
        ? 'Nothing to report'
        : '${issues.length} thing${issues.length == 1 ? '' : 's'} '
              'to look at';

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.isLegal
                    ? Icons.verified_outlined
                    : Icons.error_outline_rounded,
                size: 18,
                color: result.isLegal ? c.positive : c.warning,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(headline, style: context.t.titleSmall)),
            ],
          ),
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _Issue(issue: issue),
            ),
        ],
      ),
    );
  }
}

/// One finding.
class _Issue extends StatelessWidget {
  const _Issue({required this.issue});

  final DeckIssue issue;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (IconData icon, Color colour) = switch (issue.level) {
      DeckIssueLevel.error => (Icons.close_rounded, c.negative),
      DeckIssueLevel.warning => (Icons.priority_high_rounded, c.warning),
      DeckIssueLevel.note => (Icons.info_outline_rounded, c.textTertiary),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 15, color: colour),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                issue.title,
                style: context.t.bodyMedium?.copyWith(color: colour),
              ),
              Text(
                issue.detail,
                style: context.t.bodySmall?.copyWith(color: c.textSecondary),
              ),
              if (issue.cards.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    issue.cards.join(', '),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: c.textTertiary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One board of the deck, with its cards.
class _BoardSection extends StatelessWidget {
  const _BoardSection({
    required this.board,
    required this.contents,
    required this.owned,
    required this.format,
  });

  final DeckBoard board;
  final DeckContents contents;
  final Map<String, int> owned;
  final DeckFormat? format;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final entries = contents.board(board);
    final count = entries.fold(0, (int a, DeckEntry e) => a + e.quantity);
    final target = _target();
    final empty = switch (board) {
      DeckBoard.commander => 'No commander named yet.',
      DeckBoard.side => 'The sideboard is empty.',
      DeckBoard.main => 'The deck is empty. Add cards to start it.',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Text(board.label, style: context.t.titleSmall),
              const SizedBox(width: 8),
              Text(
                target > 0 ? '$count/$target' : '$count',
                style: context.t.bodySmall,
              ),
            ],
          ),
        ),
        if (entries.isEmpty)
          GlassCard(
            padding: const EdgeInsets.all(14),
            child: Text(
              empty,
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
          )
        else
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _DeckRow(
                entry: entry,
                deckId: contents.deck.id,
                owned: entry.ownedWith(owned),
              ),
            ),
      ],
    );
  }

  /// How many cards this board is meant to hold, or 0 when uncapped.
  int _target() {
    final f = format;
    if (f == null) return 0;
    return switch (board) {
      DeckBoard.side => f.sideboardSize,
      DeckBoard.commander => f.hasCommander ? 1 : 0,
      DeckBoard.main =>
        f.minCards == 0
            ? 0
            : f.minCards - contents.board(DeckBoard.commander).length,
    };
  }
}

/// One card in a deck, with what is owned against what is called for.
class _DeckRow extends ConsumerWidget {
  const _DeckRow({
    required this.entry,
    required this.deckId,
    required this.owned,
  });

  final DeckEntry entry;
  final int deckId;

  /// Copies of this printing the collector holds.
  final int owned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.c;
    final card = entry.card;
    final short = entry.quantity - owned;
    final missing = short > 0 ? short : 0;
    final line = missing == 0
        ? 'you have $owned'
        : 'you have $owned of ${entry.quantity}  ·  '
              '$missing to buy';

    return GlassCard(
      padding: EdgeInsets.zero,
      onTap: card == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    CardDetailScreen(game: entry.game, cardId: card.id),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: CardThumbnail(
                imageUrl: card?.imageUrl(size: 'small'),
                width: 42,
                rarity: CardRarity.fromCode(card?.rarity),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    card?.name ?? entry.cardId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.t.labelSmall?.copyWith(
                      color: missing > 0 ? c.warning : c.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            _StepperButton(
              icon: Icons.remove_rounded,
              onPressed: () => _setQuantity(ref, entry.quantity - 1),
            ),
            SizedBox(
              width: 26,
              child: Text(
                '${entry.quantity}',
                textAlign: TextAlign.center,
                style: context.t.titleSmall,
              ),
            ),
            _StepperButton(
              icon: Icons.add_rounded,
              onPressed: () => _setQuantity(ref, entry.quantity + 1),
            ),
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert_rounded,
                size: 18,
                color: c.textTertiary,
              ),
              onSelected: (String choice) => _menu(ref, choice),
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(
                      value: 'main',
                      child: Text('Move to deck'),
                    ),
                    PopupMenuItem<String>(
                      value: 'side',
                      child: Text('Move to sideboard'),
                    ),
                    PopupMenuItem<String>(
                      value: 'commander',
                      child: Text('Make the commander'),
                    ),
                    PopupMenuItem<String>(
                      value: 'remove',
                      child: Text('Remove'),
                    ),
                  ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setQuantity(WidgetRef ref, int quantity) async {
    await ref
        .read(deckRepositoryProvider)
        .setQuantity(deckId, entry.cardId, entry.board, quantity);
    ref.read(deckRevisionProvider.notifier).bump();
  }

  Future<void> _menu(WidgetRef ref, String choice) async {
    final repository = ref.read(deckRepositoryProvider);
    if (choice == 'remove') {
      await repository.removeCard(deckId, entry.cardId, entry.board);
    } else {
      await repository.moveCard(
        deckId,
        entry.cardId,
        entry.board,
        DeckBoard.fromCode(choice),
      );
    }
    ref.read(deckRevisionProvider.notifier).bump();
  }
}

/// The small round button either side of a card's count.
class _StepperButton extends StatelessWidget {
  const _StepperButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return IconButton(
      onPressed: onPressed,
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
      icon: Icon(icon, color: c.textSecondary),
    );
  }
}
