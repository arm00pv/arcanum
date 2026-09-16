import 'package:flutter/material.dart';

import 'package:arcanum/core/theme/app_theme.dart';
import 'package:arcanum/domain/models/card_game.dart';
import 'package:arcanum/domain/models/tcg_card.dart';

/// What to say about card art that may be the publisher's marked press image.
///
/// Bandai serves a good part of its Gundam, One Piece and Digimon art with
/// SAMPLE across the artwork or NOT FOR SALE down one edge, by the shop and by
/// the publisher alike - and serves some of it as an ordinary scan, so see
/// [TcgCard.gameMarksSomeArt] for what was looked at and for what is not
/// marked. The card is not a placeholder and nothing failed to download, which
/// is the question the collector is actually asking when a card arrives with a
/// mark printed over it, so this answers that question rather than describing
/// the watermark again.
class SampleArtNote extends StatelessWidget {
  const SampleArtNote({super.key, required this.game, this.short = false});

  /// The game this art belongs to, which is the thing the note names.
  final CardGame game;

  /// One line, for a screen that is not about one card.
  final bool short;

  /// Whether this catalogue's art has anything to explain.
  ///
  /// Two facts have to hold: the publisher marks enough of this game's art for
  /// a mark to be worth explaining, and the provider has published a picture for
  /// at least one of the cards. A set whose cards have no images yet wears no
  /// mark, and a note about one would answer a question nobody asked - an
  /// unreleased set is exactly that case.
  static bool applies(Iterable<TcgCard> cards) =>
      cards.any((TcgCard c) => c.artMayBeMarked && c.imageUrl() != null);

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
                ? '$publisher serves some $title art as a marked press image '
                      '- SAMPLE across the art, or NOT FOR SALE - rather than '
                      'a photograph of the card.'
                : 'A mark across $title art is the publisher\'s own: $publisher '
                      'serves some cards as a press image rather than a '
                      'photograph, with SAMPLE across the art or NOT FOR SALE '
                      'down one edge. It is not a failed download.',
            style: style,
          ),
        ),
      ],
    );
  }
}
