import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/decks/deck.dart';
import 'package:arcanum/domain/decks/deck_format.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/providers.dart';

/// Asks for a deck's name and format, and creates it.
///
/// Returns the id of the new deck, or null when the collector backed out.
Future<int?> createDeck(
  BuildContext context,
  WidgetRef ref,
  CardGame game,
) async {
  final answer = await showDialog<_DeckDraft>(
    context: context,
    builder: (BuildContext context) => _DeckDialog(game: game),
  );
  if (answer == null) return null;
  final id = await ref
      .read(deckRepositoryProvider)
      .create(game: game, name: answer.name, formatId: answer.formatId);
  ref.read(deckRevisionProvider.notifier).bump();
  return id;
}

/// Renames a deck and changes its format.
Future<void> editDeck(BuildContext context, WidgetRef ref, Deck deck) async {
  final answer = await showDialog<_DeckDraft>(
    context: context,
    builder: (BuildContext context) => _DeckDialog(game: deck.game, deck: deck),
  );
  if (answer == null) return;
  final repository = ref.read(deckRepositoryProvider);
  if (answer.name != deck.name) await repository.rename(deck.id, answer.name);
  if (answer.formatId != deck.formatId) {
    await repository.setFormat(deck.id, answer.formatId);
  }
  ref.read(deckRevisionProvider.notifier).bump();
}

/// Confirms, then deletes a deck. The collection is never touched.
///
/// The wording changed, and the design says why (docs/deck-sync.md section 4.2).
/// "The deck and its list are removed" was true while deleting a deck deleted a
/// row; since v16 it is true of this device, and only until another device edits
/// the deck. A dialog that promises a deck is gone and hands it back a moment
/// later is worse than one that says what actually happens, so this one says
/// both halves: the deck leaves this device's list, the cards stay in the
/// collection, and the deletion is not final.
///
/// It is not final in two directions and the sentence covers both. The rule the
/// merge follows is that a deletion is an edit made at a moment, so a device
/// that never heard about it and then changes the deck brings the deck back
/// everywhere, with that edit in it; and a collector who deleted the wrong deck
/// can put it back themselves, here or from the deleted decks list. Neither is a
/// promise this app can keep on its own - the first is another device's doing -
/// so what is promised is what happens rather than what will not.
///
/// The undo is offered in the snack bar rather than in a second dialog, because
/// the collector has just answered one question and asking twice is how a
/// confirmation stops being read. The list behind it is what makes the offer
/// last longer than the snack bar.
Future<bool> confirmDeleteDeck(
  BuildContext context,
  WidgetRef ref,
  Deck deck,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text('Delete ${deck.name}?'),
      content: const Text(
        'The deck and its list leave your decks, and the cards in it stay in '
        'your collection. Nothing you own is deleted.\n\n'
        'Deleting is not final. A deck another device edits before it hears '
        'about the deletion comes back with that edit, and you can put this one '
        'back from Deleted decks.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ref.read(deckRepositoryProvider).delete(deck.id);
  ref.read(deckRevisionProvider.notifier).bump();
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('${deck.name} deleted.'),
        // Long enough to be read and acted on by somebody who has just clicked
        // through a dialog, and nothing like long enough to be the only way
        // back: Deleted decks holds the deck until it is wanted.
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => unawaited(_undoDelete(ref, deck.id)),
        ),
      ),
    );
  return true;
}

/// Puts a deck back, which is an edit made now and travels like one.
///
/// The bump is the same one [confirmDeleteDeck] makes and for the same reason: a
/// screen that has answered keeps its answer until it is told the answer has
/// moved, and nothing else here would tell the deck list that a deck it stopped
/// showing is on it again.
Future<void> _undoDelete(WidgetRef ref, int id) async {
  await ref.read(deckRepositoryProvider).restore(id);
  ref.read(deckRevisionProvider.notifier).bump();
}

/// What the dialog hands back.
class _DeckDraft {
  const _DeckDraft(this.name, this.formatId);

  final String name;
  final String formatId;
}

/// The name and format dialog, used for both creating and editing.
class _DeckDialog extends StatefulWidget {
  const _DeckDialog({required this.game, this.deck});

  final CardGame game;

  /// The deck being edited, or null when a new one is being made.
  final Deck? deck;

  @override
  State<_DeckDialog> createState() => _DeckDialogState();
}

class _DeckDialogState extends State<_DeckDialog> {
  late final TextEditingController _name;
  late String _formatId;

  @override
  void initState() {
    super.initState();
    final deck = widget.deck;
    _name = TextEditingController(text: deck?.name ?? '');
    _formatId = deck?.formatId ?? DeckFormats.defaultFor(widget.game).id;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final formats = DeckFormats.forGame(widget.game);
    final chosen = DeckFormats.byId(_formatId) ?? formats.first;

    return AlertDialog(
      title: Text(widget.deck == null ? 'New deck' : 'Edit deck'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.deck == null,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Krenko Goblins',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 18),
            Text('Format', style: context.t.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final format in formats)
                  ChoiceChip(
                    label: Text(format.label),
                    selected: format.id == _formatId,
                    onSelected: (_) => setState(() => _formatId = format.id),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _describe(chosen),
              style: context.t.bodySmall?.copyWith(color: c.textTertiary),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.deck == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(_DeckDraft(name, _formatId));
  }

  /// One line saying what the chosen format will actually check.
  static String _describe(DeckFormat format) {
    final parts = <String>[];
    if (format.minCards > 0) {
      parts.add(
        format.maxCards == format.minCards
            ? 'exactly ${format.minCards} cards'
            : 'at least ${format.minCards} cards',
      );
    }
    if (format.singleton) {
      parts.add('one of each card');
    } else if (format.minCards > 0) {
      parts.add('up to ${format.maxCopies} of a card');
    }
    if (format.hasCommander) parts.add('a commander');
    if (format.hasSideboard) {
      parts.add('a ${format.sideboardSize}-card sideboard');
    }
    final rules = parts.isEmpty
        ? 'No size or copy rules are checked.'
        : 'Checked: ${parts.join(', ')}.';
    final bans = format.checksBanList
        ? ' The banned list is fetched from Scryfall.'
        : '';
    return '$rules$bans';
  }
}
