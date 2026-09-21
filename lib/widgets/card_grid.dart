import 'package:flutter/material.dart';

import 'package:arcanum/domain/models/card_game.dart';

/// The geometry of a grid of cards: one card at its own shape, and a caption
/// under it.
///
/// This exists because the obvious grid is wrong in a way that is easy to miss
/// and was measured before it was fixed. A delegate given a fixed
/// `childAspectRatio` decides a tile's height from its width, and the art inside
/// a tile is whatever is left after the caption - so the art's shape is an
/// accident of the tile's ratio and the caption's height rather than the shape of
/// a card. At the 190-wide tile this app uses, that produced an art box of
/// 190x322.4: a ratio of 0.589 against a card's 0.718, with `BoxFit.cover`
/// cropping roughly 9% off each side of **every** game's art. It was found through
/// Yu-Gi-Oh!, which was cropped *less* there than Magic was - the giveaway that
/// the box, and not the card, was the thing that was wrong.
///
/// So the tile's height is derived instead: the art gets exactly the card's own
/// ratio and the caption gets a height reserved in advance.
///
/// **The reservation is the one thing here that cannot be measured.** A delegate
/// sizes every tile before any tile is built, so the space a caption will take
/// has to be known up front. The answer is that the tile wraps its caption in
/// exactly the same number this class hands the delegate, so the two cannot drift
/// apart - and that number is scaled by the reader's text size, because a caption
/// that grows while its reservation does not is a caption that overflows.
@immutable
class CardTileMetrics {
  const CardTileMetrics({
    required this.availableWidth,
    required this.cardAspectRatio,
    required this.captionHeight,
    this.maxTileWidth = 190,
    this.mainAxisSpacing = 12,
    this.crossAxisSpacing = 10,
  });

  /// The width the grid has to lay tiles out in, after its own padding.
  final double availableWidth;

  /// The game's card shape, which is [CardGame.cardAspectRatio].
  final double cardAspectRatio;

  /// The height reserved for the caption, already scaled for the reader's text
  /// size. The tile wraps its caption in exactly this.
  final double captionHeight;

  /// No tile is wider than this, which is what keeps a desktop window showing
  /// the collection rather than three cards the size of a plate.
  final double maxTileWidth;

  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// How many tiles fit across.
  ///
  /// Worked out here rather than left to [SliverGridDelegateWithMaxCrossAxisExtent]
  /// because that delegate's count has to be known *before* the tile height can
  /// be derived, and asking it afterwards is not possible. This count is handed
  /// to the delegate, so there is exactly one rounding rule rather than two that
  /// could disagree by a pixel - which is the same class of mistake this whole
  /// class exists to remove.
  int get columns {
    if (!availableWidth.isFinite || availableWidth <= 0) return 1;
    final double usable = availableWidth + crossAxisSpacing;
    final int count = (usable / (maxTileWidth + crossAxisSpacing)).ceil();
    return count < 1 ? 1 : count;
  }

  /// How wide one tile is, by the delegate's own arithmetic.
  double get tileWidth {
    if (!availableWidth.isFinite || availableWidth <= 0) return 0;
    final double usable = availableWidth - crossAxisSpacing * (columns - 1);
    if (usable <= 0) return 0;
    return usable / columns;
  }

  /// The tile: a card at its own shape, plus the caption.
  double get tileHeight => tileWidth / cardAspectRatio + captionHeight;

  SliverGridDelegate get delegate => SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    mainAxisSpacing: mainAxisSpacing,
    crossAxisSpacing: crossAxisSpacing,
    mainAxisExtent: tileHeight,
  );
}

/// The height to reserve for a grid tile's caption at this reader's text size.
///
/// [base] is the height the caption takes at text size 1, which each screen
/// states for its own caption - one line under a set grid, two under the
/// collection's - and everything above it scales, because text does.
double cardTileCaptionHeight(BuildContext context, double base) =>
    base * MediaQuery.textScalerOf(context).scale(1);
