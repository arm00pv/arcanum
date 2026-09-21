import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/mana.dart';
import '../core/utils/formatters.dart';
import 'common.dart';

/// A card art thumbnail with a shimmering load state, a card-back fallback and
/// an optional rarity glow and quantity badge.
///
/// The widget is a fixed-size box: it always lays out inside exactly
/// `width` x `height` logical pixels and clips everything it draws, so it can
/// never overflow its parent. When [height] is null the box follows
/// [aspectRatio], which defaults to the real 488:680 Magic card shape.
///
/// A caller that knows which game the card belongs to should pass that game's
/// [CardGame.cardAspectRatio]: art is drawn with BoxFit.cover, so a box of the
/// wrong shape crops the card rather than letterboxing it, and Yu-Gi-Oh!'s
/// cards are a different rectangle from everyone else's. A caller that does not
/// know its game - a shared preview, a test - leaves it alone and gets exactly
/// the box it got before, because the default is the constant.
///
/// Note that the ratio only decides the box where the box is the widget's to
/// decide: [height] overrides it, and a parent that hands the thumbnail tight
/// constraints - a grid tile's `Expanded`, say - decides it instead. The two
/// grids that show cards are laid out that way, so their tiles are shaped by
/// their grid delegate and not by this field.
class CardThumbnail extends StatelessWidget {
  /// Creates a card thumbnail.
  const CardThumbnail({
    super.key,
    this.imageUrl,
    this.width = 120,
    this.height,
    this.aspectRatio = cardAspectRatio,
    this.heroTag,
    this.borderRadius,
    this.quantity,
    this.rarity,
    this.semanticLabel,
  });

  /// Card art URL. Null or blank renders [CardBackPlaceholder].
  final String? imageUrl;

  /// Width in logical pixels. Defaults to 120.
  final double width;

  /// Height in logical pixels. Defaults to `width / aspectRatio`.
  final double? height;

  /// The shape of the art this box draws, as width over height.
  ///
  /// Defaults to [cardAspectRatio], which is Magic's card. Pass the game's own
  /// [CardGame.cardAspectRatio] wherever the game is known - see the class doc
  /// for what it changes and where a parent's constraints win over it.
  final double aspectRatio;

  /// Optional [Hero] tag so the thumbnail can fly between routes.
  final String? heroTag;

  /// Corner radius. Defaults to a radius derived from [width].
  final BorderRadius? borderRadius;

  /// Number of copies owned. Values above 1 render a count badge.
  final double? quantity;

  /// When supplied, adds a faint rarity-coloured edge glow.
  final CardRarity? rarity;

  /// Optional semantics override.
  final String? semanticLabel;

  /// The true Magic card aspect ratio (width : height).
  static const double cardAspectRatio = 488 / 680;

  /// The rendition to ask a provider for, given the box the art is drawn in.
  ///
  /// A set screen asks for one picture per card, and which picture it asks for
  /// is the difference between a page that opens and one that crawls: Scryfall
  /// serves 146, 488 and 672 pixels across under these names, and the shop's CDN
  /// 200, 400 and 1000. Asking for the widest of them to fill a box two hundred
  /// pixels wide spends six times the bytes on pixels nobody can see - and the
  /// further the window is stretched, the more cards are on screen at once, so
  /// the waste multiplies exactly where the page can least afford it.
  ///
  /// The widths below are the larger of the two catalogues' for each name, so a
  /// box is never handed a picture smaller than the one it asked for. A
  /// catalogue that publishes fewer renditions falls back in
  /// [TcgCard.imageUrl], so nothing here can produce a missing picture.
  static String renditionFor({
    required double width,
    required double devicePixelRatio,
  }) {
    final double needed = width * devicePixelRatio;
    if (needed <= _smallWidth) return 'small';
    if (needed <= _normalWidth) return 'normal';
    return 'large';
  }

  static const double _smallWidth = 200;
  static const double _normalWidth = 488;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rarity = this.rarity;
    final height = this.height ?? width / aspectRatio;
    final radius =
        borderRadius ?? BorderRadius.circular(math.min(14.0, width * 0.075));
    final url = imageUrl?.trim();
    final hasImage = url != null && url.isNotEmpty;

    final surface = ClipRRect(
      borderRadius: radius,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (hasImage)
            _NetworkArt(url: url, width: width)
          else
            const CardBackPlaceholder(),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: c.hairline),
            ),
          ),
          if (quantity != null && quantity! > 1)
            Positioned(
              top: math.max(4.0, width * 0.05),
              right: math.max(4.0, width * 0.05),
              left: width * 0.22,
              child: Align(
                alignment: Alignment.centerRight,
                child: _QuantityBadge(count: quantity!),
              ),
            ),
        ],
      ),
    );

    Widget thumb = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: rarity == null
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: rarity.color.withValues(alpha: 0.34),
                  blurRadius: math.max(6.0, width * 0.16),
                  spreadRadius: -math.max(1.0, width * 0.02),
                ),
              ],
      ),
      child: surface,
    );

    Widget result = SizedBox(width: width, height: height, child: thumb);

    final tag = heroTag;
    if (tag != null) {
      result = Hero(tag: tag, child: result);
    }

    final label = semanticLabel ?? (hasImage ? 'Card image' : null);
    if (label != null) {
      result = Semantics(
        label: label,
        image: true,
        container: true,
        child: result,
      );
    }
    return result;
  }
}

/// The card-back fallback shown while art is missing or fails to load.
///
/// Fills whatever box it is given and scales its card-back glyph to fit, so it
/// stays legible from a 40px list row up to a full-screen hero image.
class CardBackPlaceholder extends StatelessWidget {
  /// Creates a card-back placeholder.
  const CardBackPlaceholder({super.key, this.label});

  /// Optional semantics label override.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      label: label ?? 'Card image unavailable',
      image: true,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final w = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 120.0;
          final h = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : w / CardThumbnail.cardAspectRatio;
          final shortest = math.min(w, h);
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[c.surfaceRaised, c.canvasDeep],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                CustomPaint(
                  painter: _CardBackPainter(
                    line: c.hairlineStrong,
                    accent: c.accent.withValues(alpha: 0.30),
                  ),
                ),
                Center(
                  child: Icon(
                    Icons.style_rounded,
                    size: math.max(10.0, shortest * 0.30),
                    color: c.textTertiary.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Loads card art through [CachedNetworkImage] with shimmer + fallback states.
class _NetworkArt extends StatelessWidget {
  const _NetworkArt({required this.url, required this.width});

  final String url;
  final double width;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.min(1600, math.max(1, (width * dpr).round()));

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 220),
      memCacheWidth: cacheWidth,
      placeholder: (BuildContext context, String url) => const LoadingShimmer(
        height: double.infinity,
        borderRadius: BorderRadius.zero,
      ),
      errorWidget: (BuildContext context, String url, Object error) =>
          const CardBackPlaceholder(),
    );
  }
}

/// The "x3" style badge shown on stacks of duplicate cards.
class _QuantityBadge extends StatelessWidget {
  const _QuantityBadge({required this.count});

  final double count;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final rounded = count.round();
    return Semantics(
      label: '$rounded copies',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.canvasDeep.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.hairlineStrong),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '×${Fmt.count(rounded)}',
              maxLines: 1,
              style: context.t.labelSmall?.copyWith(color: c.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a stylised Magic card back: a rounded frame, an inner oval and a
/// centred diamond.
class _CardBackPainter extends CustomPainter {
  const _CardBackPainter({required this.line, required this.accent});

  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 8 || size.height < 8) return;
    final shortest = size.shortestSide;
    final inset = shortest * 0.10;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(shortest * 0.07),
    );

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, shortest * 0.02)
        ..isAntiAlias = true
        ..color = line,
    );

    canvas.drawOval(
      Rect.fromCenter(
        center: rect.center,
        width: rect.width * 0.66,
        height: rect.height * 0.74,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, shortest * 0.014)
        ..isAntiAlias = true
        ..color = line,
    );

    final d = shortest * 0.09;
    canvas.drawPath(
      Path()
        ..moveTo(rect.center.dx, rect.center.dy - d)
        ..lineTo(rect.center.dx + d, rect.center.dy)
        ..lineTo(rect.center.dx, rect.center.dy + d)
        ..lineTo(rect.center.dx - d, rect.center.dy)
        ..close(),
      Paint()
        ..isAntiAlias = true
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_CardBackPainter oldDelegate) =>
      oldDelegate.line != line || oldDelegate.accent != accent;
}
