import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/mana.dart';

/// Renders a card's colour identity as a row of circular mana pips.
///
/// Accepts either an explicit list of Scryfall colour codes through [symbols]
/// or a raw identity string such as `'WU'` / `'W,U'` through [colorIdentity].
/// Duplicates are removed and the pips are ordered WUBRG, colourless last.
class ManaPips extends StatelessWidget {
  /// Creates a row of colour identity pips.
  const ManaPips({
    super.key,
    this.symbols = const <String>[],
    this.colorIdentity,
    this.buckets = const <ColourBucket>[],
    this.size = 16,
    this.showColorless = false,
    this.spacing = 4,
  });

  /// Explicit Scryfall colour codes, e.g. `const ['U', 'B']`.
  final List<String> symbols;

  /// Raw identity string, used when [symbols] is empty.
  final String? colorIdentity;

  /// Whole categories, for the games that do not bucket by mana.
  ///
  /// [symbols] is Magic's vocabulary: five letters out of WUBRG and a colourless
  /// C, in WUBRG order. Every other game buckets by something else - a Pokémon
  /// energy type, a Yu-Gi-Oh! attribute, a Lorcana ink, a One Piece colour -
  /// and its symbol is not a member of that set, so a caller handing one over
  /// by letter gets nothing drawn. Those callers hand over the resolved
  /// [ColourBucket]s instead, in the order the card names them.
  final List<ColourBucket> buckets;

  /// Diameter of each pip in logical pixels.
  final double size;

  /// Whether colourless identities render a `C` pip instead of nothing.
  final bool showColorless;

  /// Horizontal gap between pips.
  final double spacing;

  /// WUBRG ordering, colourless last.
  static const List<String> order = <String>['W', 'U', 'B', 'R', 'G', 'C'];

  /// Resolves [symbols] / [colorIdentity] into an ordered, de-duplicated list.
  List<ManaColor> resolve() {
    final raw = <String>[];
    if (symbols.isNotEmpty) {
      raw.addAll(symbols);
    } else {
      final identity = colorIdentity;
      if (identity != null) {
        for (final chunk in identity.split(RegExp(r'[,\s/]+'))) {
          raw.addAll(chunk.split(''));
        }
      }
    }

    final out = <ManaColor>[];
    for (final entry in raw) {
      final t = entry.trim().toUpperCase();
      if (t == 'C') {
        if (showColorless && !out.contains(ManaColor.colorless)) {
          out.add(ManaColor.colorless);
        }
        continue;
      }
      if (t.length != 1 || !'WUBRG'.contains(t)) continue;
      final mana = ManaColor.fromSymbol(t);
      if (!out.contains(mana)) out.add(mana);
    }

    out.sort(
      (ManaColor a, ManaColor b) =>
          order.indexOf(a.symbol).compareTo(order.indexOf(b.symbol)),
    );
    if (out.isEmpty && showColorless) out.add(ManaColor.colorless);
    return out;
  }

  /// The buckets to draw, whichever vocabulary the caller used.
  ///
  /// A game's own categories are drawn as given; Magic's mana is resolved and
  /// ordered WUBRG. Duplicates are dropped, so a two-colour card that names the
  /// same colour twice draws one pip.
  List<ColourBucket> resolvedBuckets() {
    final out = <ColourBucket>[];
    for (final bucket in buckets.isEmpty ? resolve() : buckets) {
      if (!out.contains(bucket)) out.add(bucket);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final resolved = resolvedBuckets();
    if (resolved.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label:
          'Color identity: '
          '${resolved.map((ColourBucket m) => m.label).join(', ')}',
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < resolved.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: spacing),
                _Pip(bucket: resolved[i], text: resolved[i].symbol, size: size),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Parses a mana cost string such as `'{2}{U}{U}'` into a row of pips.
///
/// Handles `{W} {U} {B} {R} {G} {C} {X} {S} {T}`, numeric generics and
/// hybrids such as `{W/U}` (rendered as the first colour with a slash hint).
/// Anything unrecognised falls back to a neutral grey pip carrying the raw
/// symbol text.
class ManaCostRow extends StatelessWidget {
  /// Creates a mana cost row.
  const ManaCostRow({super.key, this.cost, this.size = 16, this.spacing = 3});

  /// The raw cost, e.g. `'{2}{U}{U}'`. Null or blank renders nothing.
  final String? cost;

  /// Diameter of each pip in logical pixels.
  final double size;

  /// Horizontal gap between pips.
  final double spacing;

  static final RegExp _braced = RegExp(r'\{([^{}]*)\}');
  static final RegExp _numeric = RegExp(r'^[0-9]+$');
  static const String _colored = 'WUBRG';

  /// Splits [cost] into individual symbol tokens.
  static List<String> parse(String? cost) {
    final raw = cost?.trim() ?? '';
    if (raw.isEmpty) return const <String>[];
    final matches = _braced
        .allMatches(raw)
        .map((RegExpMatch m) => m.group(1)!.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (matches.isNotEmpty) return matches;
    return raw.split(RegExp(r'\s+'));
  }

  static bool _isColorLetter(String s) => s.length == 1 && _colored.contains(s);

  Widget _pipFor(String raw, double size) {
    final t = raw.trim().toUpperCase();
    if (t.isEmpty) return const SizedBox.shrink();

    if (_numeric.hasMatch(t)) return _Pip(text: t, size: size);

    if (t.contains('/')) {
      final parts = t.split('/');
      final first = parts.firstWhere(_isColorLetter, orElse: () => '');
      if (first.isNotEmpty) {
        return _Pip(
          text: first,
          bucket: ManaColor.fromSymbol(first),
          size: size,
          hybrid: true,
        );
      }
      return _Pip(text: t, size: size, hybrid: true);
    }

    if (t.length == 1 && _colored.contains(t)) {
      return _Pip(text: t, bucket: ManaColor.fromSymbol(t), size: size);
    }
    if (t == 'C') {
      return _Pip(text: 'C', bucket: ManaColor.colorless, size: size);
    }
    return _Pip(text: raw.trim(), size: size);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = parse(cost);
    if (tokens.isEmpty) return const SizedBox.shrink();

    return Semantics(
      container: true,
      label: 'Mana cost $cost',
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (var i = 0; i < tokens.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: spacing),
                _pipFor(tokens[i], size),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small badge coloured by [CardRarity.color].
///
/// [compact] collapses the badge to a single letter (C/U/R/M/S/B/?), which is
/// what dense collection rows want.
class RarityBadge extends StatelessWidget {
  /// Creates a rarity badge.
  const RarityBadge({
    super.key,
    required this.rarity,
    this.compact = false,
    this.code,
  });

  /// The rarity tier, which supplies the colour.
  final CardRarity rarity;

  /// Whether to render the short form.
  final bool compact;

  /// The printing's own rarity shorthand, when the provider publishes one.
  ///
  /// Only the compact form uses it, because the wide form has room to spell the
  /// rarity out and a code would be a step backwards there. Without it the
  /// compact form shows the tier letter, which is all a provider that publishes
  /// tiers rather than rarities can support.
  final String? code;

  /// The single letter used by the compact form.
  static String letterFor(CardRarity rarity) => switch (rarity) {
    CardRarity.common => 'C',
    CardRarity.uncommon => 'U',
    CardRarity.rare => 'R',
    CardRarity.mythic => 'M',
    CardRarity.special => 'S',
    CardRarity.bonus => 'B',
    CardRarity.unknown => '?',
  };

  @override
  Widget build(BuildContext context) {
    final color = rarity.color;

    return Semantics(
      label: 'Rarity ${rarity.label}',
      excludeSemantics: true,
      child: compact
          ? (code != null && code!.isNotEmpty
                // A code is two or three characters and a circle cannot hold
                // them, so the shorthand gets a pill sized to its own text.
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: color.withValues(alpha: 0.45)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: Text(
                        code!,
                        maxLines: 1,
                        style: context.t.labelSmall?.copyWith(
                          color: color,
                          letterSpacing: 0,
                          height: 1.1,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                : SizedBox(
                    width: 18,
                    height: 18,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color.withValues(alpha: 0.18),
                        border: Border.all(
                          color: color.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(3),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              letterFor(rarity),
                              maxLines: 1,
                              style: context.t.labelSmall?.copyWith(
                                color: color,
                                letterSpacing: 0,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ))
          : DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: color.withValues(alpha: 0.38)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      rarity.label,
                      maxLines: 1,
                      style: context.t.labelMedium?.copyWith(
                        color: color,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// A single circular mana pip.
class _Pip extends StatelessWidget {
  const _Pip({
    required this.text,
    this.bucket,
    this.size = 16,
    this.hybrid = false,
  });

  final String text;

  /// The category this pip stands for, or null for a neutral face pip.
  ///
  /// A [ColourBucket] rather than a [ManaColor] because only Magic's pips are
  /// mana: the same circle draws a Pokémon energy type, a Yu-Gi-Oh! attribute,
  /// a Lorcana ink, a One Piece colour, a Digimon colour and a Star Wars:
  /// Unlimited aspect.
  final ColourBucket? bucket;
  final double size;
  final bool hybrid;

  /// Maximum-contrast glyph colour for a pip.
  ///
  /// Saturated mana takes pure white. Pale mana (white, colourless) takes a
  /// darkened version of its own [ManaColor.deep] companion so the glyph keeps
  /// the mana hue rather than pulling a colour from outside the palette.
  static Color _glyphOn(ColourBucket bucket) =>
      bucket.accent.computeLuminance() > 0.5
      ? Color.lerp(bucket.deep, Colors.black, 0.45)!
      : Colors.white;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bucket = this.bucket;

    final Color fillStart;
    final Color fillEnd;
    final Color on;
    if (bucket != null) {
      fillStart = bucket.accent;
      fillEnd = bucket.deep;
      on = _glyphOn(bucket);
    } else {
      fillStart = c.surfaceRaised;
      fillEnd = Color.alphaBlend(c.glass, c.surfaceRaised);
      on = c.textSecondary;
    }

    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[fillStart, fillEnd],
          ),
          border: Border.all(
            color: on.withValues(alpha: 0.20),
            width: math.max(0.5, size * 0.06),
          ),
        ),
        child: CustomPaint(
          painter: hybrid
              ? _HybridSlashPainter(color: on.withValues(alpha: 0.32))
              : null,
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(size * 0.20),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  text,
                  maxLines: 1,
                  style: context.t.labelSmall?.copyWith(
                    color: on,
                    fontSize: size * 0.56,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the diagonal hint that marks a hybrid pip.
class _HybridSlashPainter extends CustomPainter {
  const _HybridSlashPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawLine(
      Offset(size.width * 0.24, size.height * 0.76),
      Offset(size.width * 0.76, size.height * 0.24),
      Paint()
        ..color = color
        ..strokeWidth = math.max(1, size.width * 0.08)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_HybridSlashPainter oldDelegate) =>
      oldDelegate.color != color;
}
