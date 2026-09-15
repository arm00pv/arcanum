import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// What to say about card art that is the publisher's sample.
///
/// Bandai publishes Gundam, One Piece and Digimon cards as a press image with
/// SAMPLE across the artwork, by the shop and by the publisher alike - see
/// [TcgCard.gameUsesSampleArt] for what was checked. The card is not a
/// placeholder and nothing failed to download, which is the question the
/// collector is actually asking when a card arrives with SAMPLE printed over
/// it, so this answers that question rather than describing the watermark
/// again.
class SampleArtNote extends StatelessWidget {
  const SampleArtNote({super.key, required this.game, this.short = false});

  /// The game this art belongs to, which is the thing the note names.
  final CardGame game;

  /// One line, for a screen that is not about one card.
  final bool short;

  /// Whether these cards' art has anything to explain.
  ///
  /// Two facts have to hold: the publisher marks this game's art, and the
  /// provider has published a picture for at least one of the cards. A set
  /// whose cards have no images yet wears no watermark, and a note about one
  /// would answer a question nobody asked - an unreleased set is exactly that
  /// case.
  static bool applies(Iterable<TcgCard> cards) =>
      cards.any((TcgCard c) => c.hasSampleArt && c.imageUrl() != null);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = (short ? context.t.labelSmall : context.t.bodySmall)
        ?.copyWith(color: c.textTertiary);
    final publisher = game.publisher;
    final title = game.shortLabel;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          Icons.info_outline_rounded,
          size: short ? 14 : 16,
          color: c.textTertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            short
                ? '$publisher publishes $title cards as a sample image, with '
                      'SAMPLE across the art.'
                : 'This is the publisher\'s sample image - $publisher serves '
                      'every $title card this way, ordinary sets and '
                      'promotional runs alike. It is the only version anyone '
                      'serves, so the card is right and nothing failed to load.',
            style: style,
          ),
        ),
      ],
    );
  }
}
